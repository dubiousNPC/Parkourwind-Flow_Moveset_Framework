# Optional states

Three features live here. None is required, registered or costs anything at
runtime. Each one records what has to be put back, because the knowledge is
otherwise lost the moment a file stops being guarded by `tools/regressions.txt`.

| file | status |
|---|---|
| `wall_jump.lua` | parked in v0.82 for revisiting |
| `dive_pose.lua` | parked in v0.82; a stub, not working code |
| `wall_run.lua` | never shipped; needs its own side-scan |

---

## WallJump — parked in v0.82

Jump into a wall, press jump again, brace, press jump a third time for a boost
up or sideways. The implementation itself works; it is parked for a rethink of
how it fits the moveset, not because it was broken.

**To bring it back:**

1. **main.lua** — `require('scripts/Flow/states/optional/wall_jump')`, add it to
   `REGISTERED_STATES`, and add `WallJump = true` to `OVERRIDE_STATES`. It holds
   a movement override for its whole duration; a state holding one without being
   listed there has it released by the per-tick safety net on the next frame,
   silently.

2. **states/airborne.lua** — the rung below LedgeHang, driven by a jump **edge**
   rather than held jump, so the three rungs above get first refusal on the same
   frame. It needs back: the `jumpEdge` flag set in the Jump trigger handler
   when forward is held; `WALL_JUMP_WINDOW = 0.70`; `WALL_JUMP_COOLDOWN = 1.2`;
   `WALL_CONTACT_MARGIN = 18.0`; `WALL_CONTACT_HEIGHT = 70.0`; the
   `WALL_RAY_OPTS` ray (World + Door, **no HeightMap** — terrain slopes read as
   walls); `wallContact()`, which also captures `lastWallNormal`; and
   `wallJumpSpent()` against `syncData.landings`.

   Two hard-won details: it must be gated on `Sensor.data.tooHigh`, or a
   featureless wall becomes the *most* permissive case and repeated presses climb
   it; and `wallJumpLanding` must be set on launch and cleared only by the next
   confirmed landing — re-arming in `AirborneState:enter` gives an unlimited
   vertical climb, because WallJump exits back into Airborne.

3. **playerAnim.lua** — the group entry, which is still accurate against the
   shipped `.kf`:

       WallJump = {
           variants = { brace = "pwwalljump1", up = "pwboostup",
                        left = "pwboostbkl", right = "pwboostbkr" },
           speed = 1,
           priority = PRIORITY_FLOW_MAJOR,
           blendMask = animation.BLEND_MASK.All,
           startKey = "start", stopKey = "stop",
       },

   plus `WallJump = true` in `ONE_SHOT_STATES`. The group is `pwwalljump1`
   **with the digit**; a bare `pwwalljump` exists in no shipped set, and a
   full-body blend mask over a missing group is the T-pose. Clips are played at
   speed 1 because they were authored to the move — the clip has been re-cut
   twice and each time a leftover speed multiplier stretched it past the state
   window. Re-derive any speed from `tools/check_anims.py`, never carry one over.

4. **settings.lua** — the `stateWallJump` toggle, and
   `core/skill_check.lua`'s `WallJump = { difficulty = 45, fatigue = 10 }`.

---

## Dive — parked in v0.82

See the header of `dive_pose.lua`. It is a stub: `dbsdive` was re-cut and no
longer carries the `loop start` / `loop stop` keys the three-pass presentation
named, so that code cannot work as written. `tools/check_anims.py` now catches
exactly this.

---

## WallRun — never shipped

Kept out of the default build: it needs its own continuous side-scan raycast
(`core/optional/sensor_ext.lua`'s `updateWallRun`) that does not fit through the
shared detection rays the other states use. Pulling it out was a performance
call, not a functionality one.

**To bring it back:**

1. **main.lua** — `require('scripts/Flow/states/optional/wall_run')`, add it to
   `REGISTERED_STATES`, and alongside `SensorExt.updateLedgeHang(...)` add
   `SensorExt.updateWallRun(dt, InputManager.intents, EngineSync.data)`. Worth
   checking whether it should also run outside the Idle throttle, as the rest of
   the pipeline does.

2. **states/airborne.lua** — a check against `SensorExt.data.wallRun.side`.

3. **core/engine_sync.lua** — `wall_run.lua` reads `syncData.verticalVelocity`,
   which EngineSync does not provide. Add it before re-enabling.

4. **It will raise as written.** `wall_run.lua` calls `mwSelf:teleport(...)`
   from a player script, and `teleport` is global-only — it has to go through
   `global/flow_amf_backend.lua` like every other move. It also bypasses
   `core/owned.lua` for its Levitate, so a save mid-run strands the effect, and
   its `DEBUG_MODE = true` prints regardless of the debug setting.
