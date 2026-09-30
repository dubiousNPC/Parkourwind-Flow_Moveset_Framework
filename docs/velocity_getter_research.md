# `types.Actor.getCurrentSpeed()`: open question, not wired in

**Status: RESEARCH. Nothing in FLOW uses this. `core/engine_sync.lua` still
synthesises `forwardVelocity` by differencing position, unchanged.**

An implementation branch was started and abandoned deliberately. The API exists,
but its semantics could not be established from any available source, and the
refactor it enables touches five files. This note records what is settled, what
is not, and the one experiment that would settle it — so the next attempt starts
from here rather than from the same three dead ends.

## What is settled

`types.Actor.getCurrentSpeed(actor)` **exists**. That alone corrects a claim
`core/engine_sync.lua` carried in its header for most of this project's life:

> OpenMW exposes no velocity getter - types.Actor gives runSpeed/walkSpeed
> (capability stats derived from the Speed attribute, NOT current motion)

The second half is still true and still worth knowing. The first half is not.
Confirmed present in the Cod3x 0.4 annotations and in the official Lua API
reference, with no script-context restriction noted — unlike `isOnGround` and
`isSwimming` immediately beside it, which are both flagged local-script-only.

Two neighbours found in the same pass ARE settled and ARE now used:

| API | Settled fact | Used in |
|---|---|---|
| `types.Actor.canMove(obj)` | false for dead, paralyzed **and** knocked down | `states/roll.lua` — the entire interrupt set in one call |
| `obj:getBoundingBox()` | world-space AABB; `halfSize` is this actor's real dimensions | `states/airborne.lua` — wall-contact reach, correct for beast races and scaled bodies without a per-race table |

## What is not settled

**Is it horizontal speed or 3D speed?** `forwardVelocity` is strictly the XY
magnitude. If `getCurrentSpeed` includes the vertical component, then swapping it
in changes behaviour in one specific place that matters:

```lua
-- core/sensor.lua
local dynamicReach = Sensor.BASE_REACH + (syncData.forwardVelocity * Sensor.VELOCITY_FACTOR)
dynamicReach = math.min(dynamicReach, Sensor.MAX_REACH)
```

A long fall reaches several hundred units/sec vertically. Fed through
`VELOCITY_FACTOR` that pins `dynamicReach` at `MAX_REACH` (160) for the whole
descent, so Vault and Mantle would detect further ahead while airborne than they
do now. That might even feel better — mid-air responsiveness has been a
complaint — but it would be an accidental retune of bands that were just
deliberately set, arriving disguised as a performance change. Not acceptable
without knowing.

**Is it measured velocity or intended locomotion speed?** These differ exactly
where FLOW lives. If it is derived from movement settings and stance — the
walk/run speed the actor is *trying* to move at — then:

- it reads near full run speed while airborne with forward held, though the
  player is actually drifting slowly;
- it reads ~0 during FLOW's own teleport-driven Vault, Mantle and Boost moves,
  because no input is driving them.

The second is the prize. If the reading is input-derived it is **immune to
scripted teleports by construction**, which would delete `TELEPORT_THRESHOLD`,
`prevPos`, `suspended` and `suspendTeleportDetection()` outright. If it is
measured physics velocity instead, it has exactly the teleport-contamination
problem that machinery exists to solve, and the swap buys close to nothing.

So the two possible answers point in opposite directions: one makes the refactor
clearly worth doing, the other makes it pointless.

## Why it was not resolved

Three sources, none sufficient:

1. Official Lua API reference — the whole description is "Current speed."
2. `MWWorld::Class::class.hpp` — `/// Return current movement speed.` Virtual,
   so the answer lives in the `mwclass` overrides, not the declaration.
3. `mwclass/creature.cpp` and `npc.cpp` — the override bodies could not be
   retrieved. The raw hosts are blocked from this environment (403 through the
   proxy; GitLab disallows it by robots.txt) and the GitHub blob view truncated
   before reaching the function.

Reading `Npc::getCurrentSpeed` and `Creature::getCurrentSpeed` answers both
questions in about a minute for anyone who can reach the source.

## The experiment, if reading the source stays awkward

Cheaper than arguing about it, and it answers both questions at once. Print
both values side by side for a few seconds under the debug HUD:

```lua
-- temporary, in main.lua's debug block
print(string.format("sync=%.1f engine=%.1f grounded=%s",
    EngineSync.data.forwardVelocity,
    types.Actor.getCurrentSpeed(self.object),
    tostring(EngineSync.data.isGrounded)))
```

Four readings decide it:

| Do this | If `engine` is… | Then it is… |
|---|---|---|
| Sprint in a straight line | ≈ `sync` | agreeing on the ground — necessary but proves nothing on its own |
| Stand still and fall off a cliff | ≈ 0 | horizontal-only |
| | large and climbing | 3D, includes gravity |
| Hold forward hard against a wall | ≈ 0 | measured |
| | ≈ run speed | input-derived — **this is the good answer** |
| Trigger a Vault | ≈ 0 throughout | input-derived, teleport-immune → do the refactor |
| | spikes with the tween | measured → the refactor buys nothing |

## If the answer turns out to be favourable

The blast radius, so it is scoped before it starts rather than discovered
halfway. `suspendTeleportDetection()` is called from four states:

- `core/engine_sync.lua` — the differencing, `TELEPORT_THRESHOLD`, `prevPos`,
  `suspended` and `suspendTeleportDetection()` all go. `isGrounded` stays; it is
  a separate `isOnGround` call and is unaffected.
- `states/vault.lua`, `states/mantle.lua`, `states/wall_boost.lua`,
  `states/wall_jump.lua` — each drops its paired suspend/resume calls.

Do it as its own build with no feature work alongside it, and check
`tools/regressions.txt` afterwards: several markers name those call sites.

## Cost, for completeness

Worth stating that the performance case alone is thin, so the refactor should be
justified by the teleport-immunity and the deleted machinery rather than by
frame time. Current per-frame cost is a vector subtract, a `length2`, a compare,
four multiplies and a `sqrt`. The replacement is one engine call. A Lua-to-C
boundary crossing is not obviously cheaper than that arithmetic, and neither has
ever shown up in a profile of this mod. `docs/` already has `measure-first` as a
principle for a reason.
