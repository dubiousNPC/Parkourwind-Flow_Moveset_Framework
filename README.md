# Parkourwind-Flow_Moveset_Framework
A modular framework to animate and improve Morrowind's traversal gameplay

## Changes

## Action priority

The lowest available action always wins. Each rung is only reached when the one
below it has refused, so WallJump exists for the case where the top is out of
reach of everything else.

| | rung | gate |
|---|---|---|
| 1 | **Vault** | 25-50% of height, destination not blocked |
| 2 | **Mantle** | 51-80%, destination not blocked |
| 3 | **LedgeHang** | 110-130%, lip above hand height, **and the camera aimed at or above the lip** |
| 4 | **WallJump** | all three refused, wall contact, forward held, off cooldown |

Resolved in `states/airborne.lua`'s `update`, in that order. From the ground,
`states/idle.lua` resolves Vault then Mantle; the other two are airborne-only.

The camera gate uses `I.SharedRay`, which is camera-aimed, and compares its hit
height to the lip. That answers "pitched up towards the target" without
depending on a pitch sign convention. No SharedRay means no gate.

WallJump is driven by a jump **edge**, not held jump: the trigger handler sets a
flag and the ladder consumes it, so the three lower rungs get first refusal on
the same frame. Holding jump keeps Vault, Mantle and LedgeHang live as before.
The wall ray is only cast once the ladder reaches rung 4.

## Animation assets

`Anim.verifyGroups` probes every configured clip at startup and logs the group
**and its named text keys**, because a group that exists while its start key
does not is unplayable and completely silent. Read that block in the log before
diagnosing an animation.

Every clip in the shipped `.kf` sets is keyed `start` / `stop`. An earlier pass
claimed otherwise and set Mantle, LedgeHang and left-Shimmy to `startxw` /
`startgf`; those are not keys, they were an artifact of reading the binary with
a regex that ran past each string's length prefix into the next string. Read
`.kf` strings length-prefixed, or just read the verifyGroups log.

One real asset gap was found and has since been fixed upstream: `pwladderup`
was missing its `stop` key in every set except first-person.

Measured clip lengths, used to set state durations, animation speeds and blend
times:

| clip | length |
|---|---|
| `pwwalljump1/2` | 0.23s |
| `pwvault1/2/3`, `pwmantle1/2/3` | 0.40s |
| `pwboostbkl/r`, `pwropeidle` | 0.50s |
| `pwladderidle` | 0.83s |
| `pwropeup/dwn` | 1.00s |
| `pwroll1`, `pwshimmyl1/r1`, `pwwallhangidle` | 1.07s |
| `pwrun1` | 1.33s |
| `pwladderdwn` | 2.50s |
| `pwladderup` | 2.83s |

A state that ends before its clip cuts the animation, and a clip much shorter
than its move is invisible. WallJump plays its 0.23s clip at `speed = 0.45` so
it spans the hop instead of flashing.

**Priority.** The engine plays its jump at `PRIORITY.Jump` (4) and locomotion at
`Movement` (5). Equal priority in all four bone groups means *neither* animation
is visible, so a default of `Jump` ties the engine mid-air and loses on the
ground. The default is `Weapon` (7); committed poses use `Block` (8).

**Blending.** `animations/*/xParkourwind1*.yaml` carries the blend rules. A
blend longer than about a third of the clip never fully asserts, and these clips
are short, so the wildcard base is 0.25s with shorter bottom-most overrides per
group. Bottom-most rule wins.

## Implementation notes

Constraints that span two files, where nothing else connects them. Everything
else lives in `RESEARCH.md`.

- **`global/flow_amf_backend.lua` cannot raycast.** `openmw.nearby` is a
  local-script module and does not exist in the global context; requiring it
  there stops the whole backend loading. Ground detection for every move is
  therefore done player-side, by the state, watching `syncData.isGrounded`.
- **`Sensor.registerSharedRay()` and `Anim.registerAnimRefresh()` must be called
  from `main.lua`'s `onActive`,** not at file scope. Only by then has every
  player script loaded, so `I.SharedRay` and `I.AnimRefresh` are whichever copy
  won the version race. At file scope it worked only by load-order luck.
- **A version guard does not guard interface shape.** Nine mods bundle a
  `SharedRay_v2`, all declaring version 2, so the first to load wins and FLOW's
  stands down. `core/sensor.lua` resolves the accessor rather than the
  interface, and derives distance from `hitPos`, which every copy provides.
- **`main.lua`'s `OVERRIDE_STATES` must list every state that holds an
  `I.Controls` override.** The per-tick safety net releases overrides for any
  state not in that set, silently, so an unlisted state's override lasts one
  frame. Currently: Vault, Mantle, LedgeHang, Shimmy, WallBoost, Ladder, Roll.
- **`wallJumpUsed` clears on touchdown only,** never in `AirborneState:enter`.
  WallJump exits back into Airborne, so clearing on entry gives an unlimited
  vertical climb.
- **`playerAnim.lua`'s `resolveGroup` falls back through pending variant, then
  last played, then any key.** Ladder's variants are up/down/idle with no
  "right", so a replay that sets no variant must not resolve to nil.
- **`reissue()` checks `animation.isPlaying` before replaying.** AnimRefresh v4
  delivers on subscribe and twice on load, so it is called when nothing was
  lost; without the check, entering a cell while hanging restarts the pose.
- **`core/h3lp_compat.lua` prints its live timer backend once at load.** h3lp is
  a soft dependency tested with `vfs.fileExists`, so which implementation is
  running is otherwise unanswerable from a log.

### WallJump, rebuilt

Jump into a wall, then press jump again within 0.45s while still touching it,
for a boosted second jump straight up. `pwwalljump1`, one-shot. Acrobatics
scales the apex and is fortified for the launch, alongside a `Jump` active
effect so the boost reads correctly in the magic menu. Toggle: **Wall Jump**.

The original was removed for three separate reasons, and none of them survive
here:

| old cause | now |
|---|---|
| fixed teleport-lerp toward a spawned platform mesh | ballistic `FLOW_Boost_Start`, nothing spawned |
| per-tick collision cage clamped the move to zero against the wall | the boost path does no cage work at all |
| animation group named `pwwalljump`, which does not exist | `pwwalljump1`, verified in all three shipped `.kf` sets |

That third one was the T-pose: a full-body blend mask over a missing group
leaves nothing driving the skeleton.

**Cost when idle: nothing.** Wall contact is answered in the Jump trigger
handler, so no ray is cast until the player actually asks for a wall jump, and
the common case (facing the wall) costs one ray. The only per-frame addition
anywhere is a single `timeAirborne` accumulator.

One wall jump per airborne period, cleared on touchdown rather than on entering
Airborne — WallJump exits back into Airborne, so clearing on entry would give an
unlimited vertical climb.

### Roll is now a committed action

- **Needs a real fall.** One second airborne before a tap arms anything, so hops
  and single steps down no longer offer a roll.
- **Uninterruptible** except by knockdown, paralysis or death — one
  `types.Actor.canMove()` call covers all three. The old "ground went away" bail
  is gone, so rolling off a ledge finishes the roll.
- **Always travels forward**, on the character's facing rather than the stick, at
  run speed.
- **Jump does nothing** for the duration.

The last three are one mechanism: `overrideMovementControls(true)` suppresses
jump *and* stops the engine writing `self.controls`, so the state drives movement
itself. `Roll` is therefore in `main.lua`'s `OVERRIDE_STATES` — without that the
per-tick safety net releases the override and the roll is silently jumpable and
stationary.

The fall gate and the wall-jump window also disambiguate the two gestures
without a priority rule: a wall jump is only offered below 0.45s airborne and a
roll only above 1.0s, so one tap can never satisfy both.

### AnimRefresh v3 → v4

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

### SharedRay moved to the shared path

`SharedRay/SharedRay_v2.lua` is now `scripts/SharedRay/SharedRay_v2.lua`,
the path Take a Seat and ForceChoke use. The file was already byte-identical
to theirs. At the root path it ran as a redundant second script that stood
down behind the version guard; now it merges with theirs.
