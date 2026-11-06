# Flow - Community Moveset Framework v0.86

## v0.86

Tested against WhyWalk (Core, Boats, Caravans) and Hookshot on the same player.

### Interop
- **`I.Flow` interface and `Flow_Yield` event, new** (README, Sharing the
  player). Mods that hold the player left it not grounded, and FLOW ran the
  airborne ladder on it:
  - a mount's jump, on the same key, grabbed a ledge off the saddle;
  - a caravan passenger pressing Jump at the howdah went to LedgeHang, which
    levitates and snaps the player while Caravans pins them;
  - a mount falling off a cliff played Skydive on the rider and landed as a
    knockdown;
  - the Jump that drops a Hookshot hang chained into a FLOW ledge grab.

  FLOW now stands down to Idle while any owner yields.
- A jump held across a hand-over reads as released until it is let go
  (`InputManager.latchJump`).

### Fixes
- **Skydive needs a real fall** (`SKYDIVE_MIN_FALL_SPEED`, 300 u/s). It armed
  on not-grounded alone, so a Levitate spell hovering 1.2s over a drop
  skydived, and the knockdown followed on landing. This is FLOW's own bug,
  separate from interop. `EngineSync` now publishes `verticalVelocity`.

### Tests
- **`tools/sim/test_interop.lua`, new, 33 checks.** Each holder is emulated by
  what its source does to the player (override, Levitate, per-frame placement,
  Jump). Against v0.85, 11 of them failed.
- It also covers the whole Skydive lifecycle, which `test_fsm` never did: arm,
  windup, release buffs, the knockdown landing, and the buffs removed.
- `mock.lua`: `M.notGrounded` (a placed actor), `M.I`, and the interface
  published as `I.Flow`.


## v0.85

Follow-up to v0.84's rework; nothing in it was reverted.

### Balance
- **Mantle's fatigue is 8 (8-16 with load), a deliberate cut.** v0.83 charged
  SkillCheck's 6 plus a private 20 x (1 + load) - 26 unloaded, 46 at full load;
  the single-model equivalent is ~23, and v0.84's 20 sat close to that. 8 is
  roughly a third of what players had, chosen so chaining mantles no longer
  walks the fatigue term down into WallBoost's botch band. (An earlier draft of
  this note read the old cost as "6 charged twice" = 12; the 20 x load charge
  was the second one.)

### Framework
- `StateManager.init` validates `traits`, which `setState` indexes unguarded for
  the anim mode. `BaseState.new` defaults it, so only a hand-rolled module could
  be missing it - and that crashed the transition instead of warning at
  registration, as the `name` check already does.
- The sensor gate in `main.lua` now records what its `debugOn` term costs: debug
  mode changes **detection**, not just display.

### Tests
- **`tools/check_sensors.py`**, new. A state that reads `Sensor.data` or
  `SensorExt.data` must declare the matching `traits.sensors` entry, unless the
  read is inside `canEnter` - which runs during the offering state's frame, and
  is why Vault, Mantle and LedgeHang legitimately read sensors they never
  declare. Without this, a read drifting outside the gate works with the HUD on
  and sees a reset table in play.
- **`tools/check_handlers.py` was broken and is fixed.** It counted `then` as a
  block opener, so an `if a then ... elseif b then ... end` inside the first
  handler was two `then` against one `end`, the depth never returned to 1, and
  every key after it was invisible. A planted `UiModeChanged` under
  `engineHandlers` behind an `elseif` went unreported - the exact mistake the
  checker was written for. `function`, `if`, `for`, `while` and `repeat` each
  take one `end`; `then`, `else` and `elseif` take none. Found by planting the
  bug, not by reading the code.
- `tools/regressions.txt`: 7 new records, including two that guard the checkers
  themselves.

### Docs
- The WallBoost gravity ratio in v0.84's notes was 5.7x; it is **6.3x**
  (3922.7 / 627.2). 5.7 comes from dividing by 9.81 x UnitsPerMeter rather than
  by the 627.2 actually adopted. The constant was right; the backend comment
  and its regression record carried the same 5.7 and are corrected too.

### Close-off sweep
- README skill table still listed Mantle at 20; now 8.
- `check_sensors.py` keeps block-comment newlines so reported lines do not
  drift, and documents its two blind spots (aliased module names; an offerer
  without the sensor trait).
- Verified by planting: `check_handlers.py` now reports a `UiModeChanged`
  under `engineHandlers` behind an `elseif` (v0.84's version passed it);
  `check_sensors.py` reports a `Sensor.data` read in Mantle's `update` below an
  `elseif`-bearing `canEnter`.

---

## v0.84

### Framework
- **The FSM owns transitions.** States refuse in `canEnter`, which runs before the
  current state exits, and hand data on as a payload (`return "Shimmy", {...}`).
  A refused move used to stay active for a frame and run its exit: cancel
  events, override toggles and camera resets for a move that never started.
- **Per-state traits** (`overrides`, `suspend`, `teleports`, `anim`, `sensors`)
  replace five parallel lists: `OVERRIDE_STATES`, `LOOPING_STATES` /
  `ONE_SHOT_STATES`, three private Levitate copies and per-state
  `I.Controls` calls. The FSM applies only the difference between two states,
  so LedgeHang <-> Shimmy no longer toggles Levitate and overrides on each step.
- **States no longer require each other.** `setStep`, `setLaunch`, `setLadder`,
  `setLandingData`, `StumbleState.request`, `vouchDestination` and
  `consumeResultLip` are gone; LedgeHang no longer writes into `Sensor.data`.
- New `core/geom.lua` (facing vectors, the shared landing-spot probe) and
  `core/refusal.lua` (the refused-target cooldown Vault and Mantle duplicated).

### Performance
- **Sensors are demand-gated.** They run only for a state whose traits list
  them, and only while jump is held (always in debug mode). v0.83 ran them
  every frame in every state: 3 rays a frame in the open, up to 7 plus a
  navmesh query facing a wall. Standing still now costs FLOW no rays.
- The idle throttle is gone with it; Idle's only per-frame probe is the ladder
  check, which runs at most ten times a second while walking forward.
- The navmesh query runs only for a vault-height obstacle.
- Ladder climbing sends one backend event per direction change, not a SnapTo
  per frame.
- No per-frame `vector2` allocation in input; debug-only maths skipped when
  debug is off.

### Fixes
- **Dry cells crashed every airborne frame.** `AirPose.inWater` compared a
  number with `false` when a cell had no water.
- **Botched-fall pose never played.** `pose()`'s already-playing guard compared
  equal on the first call.
- **Held jump chained hang actions.** The grab is made with jump held, so
  LedgeHang -> Shimmy -> WallBoost fired on the next strafe and every hang
  auto-mantled after 0.3s. Hang and shimmy actions now take a jump press.
  LedgeHang + strafe + jump press goes straight to WallBoost.
- **Landing roll uses Acrobatics**, the stat the engine's fall damage reads,
  held across the impact. It was +70 Agility (ignored by fall damage) plus a
  heal afterwards.
- **Buffs are written once**, as the stat modifier. The matching Fortify active
  effect was also written and either did nothing or doubled the bonus.
- **Mantle charged fatigue twice** and ignored the Fatigue Cost setting. One
  cost model now, scaled by encumbrance for every move.
- **Idle had a hidden fatigue gate** on Vault/Mantle; removed.
- **WallBoost went through ceilings.** The arc is ray-checked before launch and
  cut short of any hit, runs on an absolute curve, and uses engine gravity
  (627.2 u/s2 = GravityConst 8.96 x UnitsPerMeter 69.99; it was 9.81 x 400,
  **6.3x** stronger, so the hand-off jolted).
  Horizontal reach is shorter as a result: about 230 units over the state.
- **Ladder climbed past the ladder** and through ceilings; it now stops where
  the ladder ends and under any overhead, and lets go if the ladder ends above
  the floor on the way down.
- Ladder's first clip was random; LedgeHang with no lip floated in place;
  a vouched Mantle destination could leak to the next ground mantle.
- Settings text matched to the code (height bands, Roll, WallBoost reach).
  `skydiveWindup` fallback matched to its 3.0 default.

### Tests
- `tools/regressions.txt`: 13 new records; 9 re-pointed where code moved.

---

## History moved out of README
### (pre-v0.83) WallJump, rebuilt

Jump into a wall, then press jump again within 0.45s while still touching it,
for a boosted second jump straight up. `pwwalljump1` or `pwwalljump2`, one-shot. Acrobatics
scales the apex and is fortified for the launch, alongside a `Jump` active
effect so the boost reads correctly in the magic menu. Toggle: **Wall Jump**.

The original was removed for three separate reasons, and none of them survive
here:

| old cause | now |
|---|---|
| fixed teleport-lerp toward a spawned platform mesh | `FLOW_Hop_Start`, a Z-only curve, nothing spawned |
| per-tick collision cage clamped the move to zero against the wall | the hop path does no cage work at all |
| animation group named `pwwalljump`, which does not exist | `pwwalljump1`, verified in all three shipped `.kf` sets |

That third one was the T-pose: a full-body blend mask over a missing group
leaves nothing driving the skeleton.

**Cost when idle: nothing.** Wall contact is answered in the Jump trigger
handler, so no ray is cast until the player actually asks for a wall jump, and
the common case (facing the wall) costs one ray. The only per-frame addition
anywhere is a single `timeAirborne` accumulator.

One wall jump per confirmed landing; see the notes above.

### (pre-v0.83) AnimRefresh v3 → v4

`scripts/AnimRefresh/AnimRefresh_v4.lua` replaces the v3 copy. The filename
carries the version on purpose: two mods shipping the same filename occupy one
VFS path, so the version guard inside the file only helps once the names
differ.

What FLOW gets out of it:

| | v3 | v4 |
|---|---|---|
| callbacks per POV press | 4 | 1, plus FLOW's opt-in verify pass |
| idle → auto-vanity → back | 5 spurious callbacks | 0 |
| refresh after Rest / Travel / Training / Jail | never | yes |
| refresh after loading a save | never | yes |

The auto-vanity row is the one that mattered in play. v3 fired on every hop
between ThirdPerson, Preview and Vanity, none of which rebuild the model, so
hanging from a ledge long enough to trigger vanity restarted the hang pose.

Two things changed on FLOW's side of the interface.

**`reissue()` is now idempotent.** v4 delivers once shortly after `subscribe()`
and twice after `onLoad`, so the callback is called when nothing was lost.
`reissue()` returns early if `animation.isPlaying` says the group it last asked
for is still running. It deliberately tests the group actually in flight rather
than re-resolving from `GROUPS`, because Vault and Mantle pick their clip at
random and re-resolving could cancel a good pose to play a sibling of it.

**FLOW passes `{ verify = true }`.** Take a Seat declines that option because a
second delivery restarts its looping pose visibly. With the guard above, FLOW's
second delivery is a no-op whenever the pose survived and a rescue when a late
rebuild dropped it. The opt-in is only valid while that guard exists.

The path matters as much as the version. At the old root-level path FLOW's
copy was a separate script from everyone else's. At the shared path OpenMW
merges every registration into one script, so its place in the load order is
no longer FLOW's to decide.

The subscription used to run at file scope in `playerAnim.lua`, which only
worked while AnimRefresh happened to load before `main.lua`. When it didn't,
the `if I.AnimRefresh` guard skipped it without a word and poses stopped
surviving a POV switch.

It now runs from `main.lua`'s `onActive` as `Anim.registerAnimRefresh()`. That
is the binding point `Sensor.registerSharedRay()` already uses, and every
player script has loaded by then. A missing interface is printed, not skipped.
A simulation with AnimRefresh loading after FLOW: the old code fails to
subscribe and reports nothing; the new code subscribes and reports absence.

### (pre-v0.83) SharedRay moved to the shared path

`SharedRay/SharedRay_v2.lua` is now `scripts/SharedRay/SharedRay_v2.lua`,
the path Take a Seat and ForceChoke use. The file was already byte-identical
to theirs. At the root path it ran as a redundant second script that stood
down behind the version guard; now it merges with theirs.
