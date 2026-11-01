// [machinery] A factory's machinery that works while it builds, in the picture alone: the moving parts of a remastered
// unit stand on bones of its levels past the simulation's skeleton (appended after it, by name: models.cpp), and a side
// file beside its levels, <file>_machinery.json, says how each moves (docs/render-answers.md, "factory machinery as a
// production line"):
//   keys    a work cycle: keyframes [t, [rx, ry, rz], [tx, ty, tz]] over its period (t 0..1; degrees turned X, then Y, then
//           Z about the bone's head in its parent's axes at rest; a move in units), eased "sine" or "linear" between keys,
//           wrapping from the last key to the first
//   loop    a conveyor's part: slid along an axis from range[0] to range[1] over the period less its gap, then hidden for
//           the gap (the jump back)
//   scroll  a belt: its strip of the texture slides along its axis, wrapped within it (one belt a model)
// A key may also scale its part in its own axes at rest: [t, [rx, ry, rz], [tx, ty, tz], <scale>] with <scale> one number
// or [sx, sy, sz] (1: its size), eased with the rest of the key (a storage cell filling, a cap breathing).
// and emitters on a bone that play while a named bone's cycle is within windows of it ("on_keys"), in the state they name
// ("state": "building", the default, "idle" or "always"; without "on_keys" all through it), and lamps of the unit's
// lights.bp that pulse ("lamps": index, period, phase, low, state). A part's "building"
// motion plays while the factory builds; its "idle" motion (keys or loop, optional) while it does not - a slow standby, so
// that a base's factories are not dead still between builds; without one it rests.
// Building is the unit's work going on (0 < workProgress < 1, its progress moving within the last half second); the
// parts blend between their rest and their work over the file's blend (0.5 s), on the game's clock: a paused game stops
// them. The simulation never sees any of it.
#pragma once
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "frame.h"
#include "linalg.h"
#include "mesh_renderer.h"
#include "models.h"

namespace render {

class Particles;

struct MachinerySpec {
  struct Key {
    float t = 0;
    Quat turn;
    Vec3 move;
    Vec3 scale{1, 1, 1};
    bool sine = true;
  };
  enum class State { Building, Idle, Always };
  struct Emitter {
    std::string blueprint;
    int of = -1;  // the part whose cycle its windows are of (an index into `parts`; its own part when the file names none)
    std::vector<std::pair<float, float>> windows;  // none: all through its state
    State state = State::Building;
  };
  // a lamp of the unit's lights.bp (its place in that list) pulsing between `low` and full over its period, in its state
  // (outside it the lamp is as the list has it); ease "sine" (a breath) or "beat" (a sharp flash and a slower fade)
  struct Lamp {
    int index = 0;
    float period = 2, phase = 0, low = 0.2f;
    bool beat = false;
    State state = State::Always;
  };
  struct Motion {
    enum Mode { Still, Keys, Loop, Scroll } mode = Still;
    float period = 1, phase = 0;
    std::vector<Key> keys;  // (Keys: by t)
    Vec3 axis{0, 0, 1};     // (Loop)
    float from = 0, to = 0, gap = 0;
  };
  struct Part {
    int bone = -1, parent = -1;  // in Model::bones
    Motion work, idle;           // while it builds, and while it does not (Still: at rest)
    std::vector<Emitter> emitters;
  };
  std::vector<Part> parts;  // parents before their children
  std::vector<Lamp> lamps;
  bool scales = false;      // a key of a part scales it
  size_t simBones = 0;      // Model::bones up to here are the simulation's
  float blend = 0.5f;       // seconds between rest and work
  // its belt (the first "scroll" part): the bone whose vertices are it, its axis (0: u, 1: v), where its strip begins along
  // it and how long it is (texture units), how fast it moves (texture units a second); beltBone -1: none
  int beltBone = -1, beltAxis = 1;
  float beltFrom = 0, beltLength = 1, beltSpeed = 0;
};

// Reads a side file against the model's bones (the extras appended). Null, with why, when nothing in it can be used.
std::shared_ptr<const MachinerySpec> ReadMachinery(const std::string& text, const std::vector<ModelBone>& bones, std::string* why);

class Machinery {
 public:
  explicit Machinery(Particles* particles) : particles_(particles) {}
  // Once a frame, before the first view lists its units (`first`: the first view; the others keep its lists). The units
  // not drawn in the frame before are let go (their emitters stopped). `eye`: where the camera is; a factory farther from it
  // than kFar is not worked out (its parts stand at rest and its emitters stop: from there its parts are a few pixels).
  void Begin(double clock, bool first, Vec3 eye);
  static constexpr float kFar = 250;
  // A unit drawn with a model that has machinery, standing at `at`, turned `turn`, of that faction (its emitters'): its
  // parts posed into `pose` (the simulation's bones and then the parts', in lists kept until the frame's last draw); its
  // emitters started, moved and stopped (the first view only). Returns how far its belt has moved along its strip
  // (MeshRenderer::Belt; -1: it has none).
  float PoseUnit(const FrameUnit& unit, const Model& model, Vec3 at, const Quat& turn, const std::string& faction, Pose* pose);
  // How strong a unit's lamp is this frame by its pulse (its place in the model's lights; 1: as the list has it).
  float LampScale(uint32_t unit, size_t lamp) const;

  int posed = 0;  // units posed this frame

 private:
  struct UnitState {
    float work = 0;           // 0 rest .. 1 working
    float progress = -1;      // its workProgress when last seen
    double moved = -1e9;      // when that last changed
    double seen = -1;         // the clock it was last drawn at
    double belt = 0;          // how far its belt has moved (texture units)
    std::vector<uint32_t> emitters;  // per part's emitter, flattened (0: none playing)
    std::vector<float> lamps;        // per lamp of the model's lights: its strength this frame (1: as listed)
  };
  Particles* particles_;
  std::unordered_map<uint32_t, UnitState> units_;
  std::deque<std::vector<FrameBone>> lists_;
  std::deque<std::vector<float>> scaleLists_;
  double clock_ = 0;
  bool first_ = true;
  Vec3 eye_;
};

}  // namespace render
