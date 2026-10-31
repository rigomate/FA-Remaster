// Speculation with a verifier: see speculate.h.
#include "core/speculate.h"

#include <cstdio>
#include <cstdlib>

#include "core/log.h"

namespace moho {

bool SpecModeGiven(const char* name) {
  const std::string var = std::string("MOHO64_PAR_") + name;
  const char* v = std::getenv(var.c_str());
  return v && *v;
}

size_t SpecMinFromEnvironment(const char* name, size_t dflt) {
  const std::string var = std::string("MOHO64_PAR_") + name;
  const char* v = std::getenv(var.c_str());
  if (v && (!std::strcmp(v, "verify") || !std::strcmp(v, "redo"))) return 0;
  if (v && !std::strncmp(v, "on:", 3)) return static_cast<size_t>(std::strtoull(v + 3, nullptr, 10));
  return dflt;
}

SpecMode SpecModeFromEnvironment(const char* name, SpecMode unset) {
  const std::string var = std::string("MOHO64_PAR_") + name;
  const char* v = std::getenv(var.c_str());
  if (!v || !*v) return unset;
  if (!std::strcmp(v, "0") || !std::strcmp(v, "off")) return SpecMode::kOff;
  if (!std::strcmp(v, "verify")) return SpecMode::kVerify;
  if (!std::strcmp(v, "redo")) return SpecMode::kRedo;
  return SpecMode::kOn;
}

const char* SpecModeName(SpecMode m) {
  switch (m) {
    case SpecMode::kOff: return "off";
    case SpecMode::kOn: return "on";
    case SpecMode::kVerify: return "verify";
    case SpecMode::kRedo: return "redo";
  }
  return "?";
}

void ReadLog::Derived(Reader r, const void* obj, uint32_t n) {
  unsigned char tmp[kMaxDerived];
  if (n > kMaxDerived) {
    std::fprintf(stderr, "moho64: ReadLog::Derived: a value of %u bytes (at most %u)\n", n, kMaxDerived);
    std::abort();
  }
  std::memset(tmp, 0, n);
  r(obj, tmp);
  Arena& A = a_ ? *a_ : own_;
  A.e.push_back({r, obj, static_cast<uint32_t>(A.bytes.size()), n});
  A.bytes.insert(A.bytes.end(), tmp, tmp + n);
  ++n_;
}

bool ReadLog::Holds(size_t* first) const {
  unsigned char tmp[kMaxDerived];
  const Arena& A = a_ ? *a_ : own_;
  for (size_t i = 0; i < n_; ++i) {
    const Entry& e = A.e[e0_ + i];
    const unsigned char* was = A.bytes.data() + e.off;
    bool same;
    if (!e.r) {
      same = std::memcmp(e.p, was, e.n) == 0;
    } else {
      std::memset(tmp, 0, e.n);
      e.r(e.p, tmp);
      same = std::memcmp(tmp, was, e.n) == 0;
    }
    if (!same) {
      if (first) *first = i;
      return false;
    }
  }
  return true;
}

std::string SpecCounts::Line(const char* name) const {
  char b[256];
  std::snprintf(b, sizeof b,
                "moho64 speculation %s: made %llu, taken %llu, changed %llu, none %llu, thrown %llu, checked %llu", name,
                static_cast<unsigned long long>(made), static_cast<unsigned long long>(taken),
                static_cast<unsigned long long>(changed), static_cast<unsigned long long>(none),
                static_cast<unsigned long long>(thrown), static_cast<unsigned long long>(checked));
  std::string line = b;
  if (rounds || below)
    line += "; beats ahead " + std::to_string(rounds) + " (items " + std::to_string(items) + "), under the minimum " +
            std::to_string(below);
  if (changed) {
    line += "; changed by first read:";
    for (size_t i = 0; i < kFirst; ++i)
      if (firstChanged[i]) line += " " + std::to_string(i) + (i + 1 == kFirst ? "+" : "") + "=" + std::to_string(firstChanged[i]);
  }
  return line;
}

void SpecMismatch(const char* name, size_t item, const std::string& what) {
  std::fprintf(stderr, "moho64: speculation %s: item %zu: the verified result differs from the serial one: %s\n", name,
               item, what.c_str());
  Logf(LogLevel::Error, "moho64: speculation %s: item %zu: the verified result differs from the serial one: %s", name, item,
       what.c_str());
  std::abort();
}

}  // namespace moho
