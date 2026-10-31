// Speculation with a verifier (docs/multicore.md 3, step 3): a stage's per-item work computed ahead, in parallel,
// from the state as it stands before the stage, then taken in the stage's own serial order only if everything it read
// is still the same; otherwise the item is computed again, serially, by the same code (the "redo").
//
// The pieces, each reusable by any stage:
// - ReadLog: what one speculative item read. A task notes every read that its result depends on: plain memory
//   (Raw: the bytes at an address) or a value derived from an object (Derived: a reader function, called again to
//   verify). Holds() reads them all again and compares bytes: true only when every one is unchanged. A changed byte
//   that would not change the result (a -0 for a +0) counts as a change: the verifier is conservative, never lenient.
// - Speculation<Out>: the slots of one stage (a ReadLog and an Out per item, reused from beat to beat), Run (the
//   items on the sim's worker pool), Take (an item's verified result at its serial turn), and the counts.
// - SpecMode, from MOHO64_PAR_<NAME>: off (nothing runs ahead, the serial code alone), on, verify (every taken
//   result is also computed serially and compared: a difference is a read the task did not note, and stops the
//   program), redo (every result is thrown away: the serial redo through the stage's new code). Unset: the sim's
//   default (Sim::ParDefault: on in a game with the engine's fixes and more than one thread, else off).
//
// The rules of a speculative task are a parallel task's (core/workers.h): it reads only state that nothing writes
// while the pool runs, writes only its own slot (and its worker's scratch), never touches a Lua state, allocates
// nothing once the slots have grown. What it reads may change AFTER the pool returns, during the serial stage: that
// is what the ReadLog is for. The objects a log points at must live until the stage's end (entities do: they go at
// the beat's end).
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "core/workers.h"

namespace moho {

enum class SpecMode { kOff, kOn, kVerify, kRedo };

// The worker a speculative task runs on (set by Speculation::Run for its tasks): a stage's own per-worker storage.
inline thread_local int tl_specWorker = 0;
// MOHO64_PAR_<name>: unset -> unset (kOff unless given); 0 / off -> kOff; 1 / on -> kOn; verify; redo
SpecMode SpecModeFromEnvironment(const char* name, SpecMode unset = SpecMode::kOff);
// MOHO64_PAR_<name> is set (not empty): an explicit choice, which wins over a default (Sim::ParDefault)
bool SpecModeGiven(const char* name);
// The stage's minimum of items a beat (MOHO64_PAR_<name>=on:N; else dflt): below it nothing is made ahead in that beat
// and the stage runs serially as with the switch off (a pool call and the checks at each item's turn cost more than
// a small beat's work saves: measured, e1 2026-10-31). verify and redo always run ahead (0).
size_t SpecMinFromEnvironment(const char* name, size_t dflt);
const char* SpecModeName(SpecMode m);

class ReadLog {
 public:
  // A derived read: writes the value (n bytes) it reads from obj into out (zeroed beforehand, so padding compares).
  using Reader = void (*)(const void* obj, void* out);
  static constexpr uint32_t kMaxDerived = 128;  // (bytes of one derived value)
  struct Entry {
    Reader r;  // null: plain memory at p
    const void* p;
    uint32_t off, n;  // (off: in the arena's bytes)
  };
  // Where a log's entries and bytes go: its own (the default), or an arena that many logs fill one after another
  // (Speculation: one per worker, cleared at each round, its capacity kept: the memory is a round's real total, not
  // every slot's largest log ever).
  struct Arena {
    std::vector<Entry> e;
    std::vector<unsigned char> bytes;
  };
  void Clear() {
    own_.e.clear();
    own_.bytes.clear();
    a_ = nullptr;
    e0_ = n_ = 0;
  }
  // an empty log written at the end of arena a (it must live, unchanged before that end, until the log's last use)
  void Begin(Arena* a) {
    Clear();
    a_ = a;
    e0_ = a->e.size();
  }
  // the bytes at p, n of them
  void Raw(const void* p, uint32_t n) {
    Arena& A = a_ ? *a_ : own_;
    A.e.push_back({nullptr, p, static_cast<uint32_t>(A.bytes.size()), n});
    const auto* b = static_cast<const unsigned char*>(p);
    A.bytes.insert(A.bytes.end(), b, b + n);
    ++n_;
  }
  template <class T>
  void Raw(const T& v) {
    Raw(&v, sizeof v);
  }
  // r(obj, .) as it reads now (n <= kMaxDerived)
  void Derived(Reader r, const void* obj, uint32_t n);
  // every read gives the same bytes now (else, with first given, the index of the first read that changed)
  bool Holds(size_t* first = nullptr) const;
  size_t Reads() const { return n_; }

 private:
  Arena own_;
  Arena* a_ = nullptr;  // (null: own_)
  size_t e0_ = 0, n_ = 0;  // (the log's entries: [e0_, e0_ + n_) of its arena)
};

// The counts of one stage (whole run): taken = verified and used; changed = a read had changed (redone serially);
// none = no result was made ahead (redone serially); thrown = thrown away by MOHO64_PAR_<NAME>=redo; checked = taken
// and compared with the serial result (verify).
struct SpecCounts {
  uint64_t made = 0, taken = 0, changed = 0, none = 0, thrown = 0, checked = 0;
  uint64_t rounds = 0, below = 0;  // beats made ahead / beats under the stage's minimum (made serially)
  uint64_t items = 0;               // the items of the beats made ahead (made: those that gave a result)
  // the changed results by the index of their first changed read (the last bucket: that index or later): which read
  // throws results away, for the stage's tuning (its order of reads is the stage's own)
  static constexpr size_t kFirst = 16;
  uint64_t firstChanged[kFirst] = {};
  std::string Line(const char* name) const;
};

template <class Out>
class Speculation {
 public:
  explicit Speculation(const char* name) : name_(name), mode_(SpecModeFromEnvironment(name)) {}
  SpecMode mode() const { return mode_; }
  bool active() const { return mode_ != SpecMode::kOff; }
  void SetMode(SpecMode m) { mode_ = m; }  // (Sim::Start: the default once the session is known)
  size_t minItems() const { return minItems_; }
  void SetMinItems(size_t n) { minItems_ = n; }
  // A beat of n items under the minimum (not in verify / redo): nothing is made ahead in round `round`, and every
  // Take of it answers "none" (the serial path). Returns whether it is under.
  bool Below(size_t n, uint32_t round) {
    if (mode_ == SpecMode::kVerify || mode_ == SpecMode::kRedo || n >= minItems_) return false;
    round_ = round;
    n_ = 0;
    ++counts_.below;
    return true;
  }
  const SpecCounts& counts() const { return counts_; }
  const char* name() const { return name_; }

  // fn(i, ReadLog&, Out&) -> bool (true: a result was made for item i) over [0, n) on the pool, in chunks of grain.
  // The stage `round` (a beat's tick, or any number that differs from the last call's) tells this round's slots from
  // older ones.
  template <class F>
  void Run(WorkerPool& pool, const char* stage, uint32_t round, size_t n, size_t grain, F&& fn) {
    round_ = round;
    if (slots_.size() < n) slots_.resize(n);
    // (one arena a worker; ParallelFor's worker index is below Threads(), the order check's tasks run as worker 0)
    if (arenas_.size() < static_cast<size_t>(pool.Threads()) + 1) arenas_.resize(static_cast<size_t>(pool.Threads()) + 1);
    for (ReadLog::Arena& a : arenas_) {
      a.e.clear();
      a.bytes.clear();
    }
    pool.ParallelFor(stage, n, grain, [&](size_t b, size_t e, int w) {
      tl_specWorker = w;
      for (size_t i = b; i < e; ++i) {
        Slot& s = slots_[i];
        s.reads.Begin(&arenas_[static_cast<size_t>(w)]);
        s.made = fn(i, s.reads, s.out);
        s.round = round;
      }
    });
    for (size_t i = 0; i < n; ++i)
      if (slots_[i].made) ++counts_.made;
    n_ = n;
    ++counts_.rounds;
    counts_.items += n;
  }
  // Item i's result at its serial turn, if one was made this round and every read it noted is unchanged; else
  // nullptr, and the caller computes the item itself (the redo). An item is taken at most once.
  const Out* Take(size_t i) {
    if (i >= n_ || slots_[i].round != round_ || !slots_[i].made) {
      ++counts_.none;
      return nullptr;
    }
    Slot& s = slots_[i];
    s.made = false;
    if (mode_ == SpecMode::kRedo) {
      ++counts_.thrown;
      return nullptr;
    }
    size_t first = 0;
    if (!s.reads.Holds(&first)) {
      ++counts_.changed;
      ++counts_.firstChanged[first < SpecCounts::kFirst ? first : SpecCounts::kFirst - 1];
      return nullptr;
    }
    ++counts_.taken;
    return &s.out;
  }
  // (verify) the caller computed a taken item again serially: same says whether the two agree; a difference stops
  // the program with what, the stage's name and the item
  void Checked(bool same, size_t i, const std::string& what) {
    ++counts_.checked;
    if (!same) Mismatch(name_, i, what);
  }

 private:
  struct Slot {
    ReadLog reads;
    Out out{};
    uint32_t round = 0xffffffffu;
    bool made = false;
  };
  static void Mismatch(const char* name, size_t i, const std::string& what);
  const char* name_;
  SpecMode mode_;
  std::vector<Slot> slots_;
  std::vector<ReadLog::Arena> arenas_;  // (one a worker: the round's read logs)
  size_t n_ = 0;
  size_t minItems_ = 0;
  uint32_t round_ = 0xffffffffu;
  SpecCounts counts_;
};

void SpecMismatch(const char* name, size_t item, const std::string& what);  // logs, then aborts
template <class Out>
void Speculation<Out>::Mismatch(const char* name, size_t i, const std::string& what) {
  SpecMismatch(name, i, what);
}

}  // namespace moho
