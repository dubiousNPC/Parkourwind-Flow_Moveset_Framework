# Parkourwind-Flow_Moveset_Framework
A modular framework to animate and improve Morrowind's traversal gameplay

## Changes
**REQUIRES AnimRefresh_V6**


## Layout

Every FLOW-owned Lua file lives under `scripts/Flow/`. Only the paths the engine
dictates stay at the VFS root:

| at the root | why |
|---|---|
| `FLOW_AMF.omwscripts` | the content file |
| `animations/<skeleton>/` | OpenMW resolves animation sources by skeleton folder |
| `l10n/FLOW_AMF/` | the localisation root is fixed |
| `shaders/` | post-process shaders are looked up by root path |
| `scripts/AnimRefresh/`, `scripts/SharedRay/` | shared third-party paths, so OpenMW merges every mod's copy into one script |

The namespace is not cosmetic. At the old root layout FLOW shipped `main.lua`,
`settings.lua`, `playerAnim.lua`, `core/` and `states/` at the VFS root, and any
other mod shipping a root `settings.lua` would occupy the same VFS path — the
same collision the AnimRefresh filename version guard exists for.

**`require` resolves against the VFS root, not relative to the requiring
script.** So moving the tree means rewriting every path, and `core/sensor` is
now `scripts/Flow/core/sensor`. Dots and slashes are interchangeable.
`tools/check_requires.py` resolves all of them against the shipped file list;
v0.78b moved the tree without that pass and left 13 paths dangling, which takes
`main.lua` offline before it registers a single handler.

`playerAnim.lua` and `settings.lua` are **modules**, not scripts, and are not
listed in the manifest. Registering a module there loads a second instance that
no `require` ever sees, and `settings.lua` registers its page at file scope, so
the second instance re-registers it.

## Action priority

The lowest available action always wins. Each rung is only reached when the one
below it has refused, so WallJump exists for the case where the top is out of
reach of everything else.

| | rung | gate |
|---|---|---|
| 1 | **Vault** | 18-58% of height, destination not blocked |
| 2 | **Mantle** | to 95%, destination not blocked |
| 3 | **LedgeHang** | hands can reach the lip (78-138% of height), lip above the catch floor, **and the camera looking at or above level** |

WallJump was rung 4 until v0.82 and is parked in `states/optional/`; see that
folder's README for the exact rung it occupied and what has to come back with
it.

**The bands overlap on purpose.** The ladder resolves lowest-first, so an
overlap costs nothing and a gap costs a refused move. The reach numbers were
widened across the board in v0.81 - `BASE_REACH` 70→95, `MAX_REACH` 160→200,
`LOW_SCAN_REACH` 55→75, `MIN_VAULT_ANGLE` 78→70°, the wall-jump window
0.45→0.70s and its cooldown 2.0→1.2s, the ledge aim tolerance 16→34 units, the
ladder reach 70→95 and the roll's minimum air time 1.0→0.75s.

Skydive is **not** on this ladder. It is a pose, not a state (see below), so
everything above stays reachable while it runs.

Resolved in `states/airborne.lua`'s `update`, in that order. From the ground,
`states/idle.lua` resolves Vault then Mantle; the other two are airborne-only.

The camera gate uses `I.SharedRay`, which is camera-aimed, and compares its hit
height to the lip. That answers "pitched up towards the target" without
depending on a pitch sign convention. No SharedRay means no gate.


## LedgeHang reach

The detector runs **only while airborne**, from the player's current feet, so
anything measured purely as a band above the feet travels upward with the jump.
A window equal to the design band alone (110-130% of height, 30 units) left a
given lip inside it for about two frames, which is why LedgeHang stopped firing
at all.

The window is therefore anchored on the hands and deliberately wider than the
band: `HANDS_FRAC` 110%, `PROBE_BELOW` 32% and `PROBE_ABOVE` 28% give a 77-unit
span at a 128-unit actor, so a lip is caught while rising to it.

The aim test compares the **look direction** - camera position to whatever the
camera ray hit - rather than that hit's absolute height. The absolute form
rejected any shot that landed on the wall below the lip, which is most of them.
Direction also avoids depending on a pitch sign convention, which is not
documented.

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

`tools/check_anims.py` is the mechanical version of that probe: it reads the
text keys out of every shipped `.kf` length-prefixed, pulls the group names out
of `playerAnim.lua`, and reports any slot with no playable clip on some
skeleton. Each `variants` direction is its own slot, because up, down and idle
are different clips rather than alternatives.

**Skeletons do not fall back.** Third person loads `base_anim.nif`, or
`base_animkna.nif` for beasts, plus `base_anim_female.nif` for non-beast
females. First person always loads `base_anim.1st.nif` and adds
`base_animkna.1st.nif` or `base_anim_female.1st.nif`. A group is therefore
only playable for the players whose own set declares it, and an undefined group
is a silent no-op. `resolveGroup` filters a list of interchangeable clips by
`animation.hasGroup` for that reason, caching the answer and dropping the cache
on an AnimRefresh callback, since a POV switch changes the answer.

Measured clip lengths, used to set state durations, animation speeds and blend
times. As of v0.79 every set agrees, which it did not before:

| clip | length |
|---|---|
| `pwwalljump1` (brace) | 0.333s |
| `pwvault1/2/3`, `pwmantle1/2/3` | 0.40s |
| `pwboostup`, `pwboostbkl/r`, `pwropeidle`, `skydivel/r` | 0.50s |
| `pwladderidle` | 0.833s |
| `pwropeup/dwn`, `skydivefwd`, `dbsfall`, `dbsdive` | 1.00s |
| `pwroll1`, `pwwallhangidle` | 1.067s |
| `pwfalling` | 1.50s (loops 0.033-1.467) |
| `pwrun1` | 1.50s |
| `pwladderdwn` | 2.50s |
| `pwladderup` | 2.867s |
| `skydive1` (windup) | 9.967s, `release` at 5.967 |
| `skydive` (idle) | 2.867s, loops 10.533-13.333 |

Shimmy is keyed `pwshimmyl1`/`pwshimmyr1` in the three third-person sets and
`pwshimmy1l`/`pwshimmy1r` in the three `.1st` sets. Both spellings are listed
as interchangeable so either POV resolves.

`pwwalljump2` was removed from every set and is no longer referenced.
`pwropeup2` is gone with the last `xClimbing1kna.kf`; nothing played it.

**`dbsdive` was re-cut in v0.82** from 1.967s with `loop start` / `loop stop` to
a flat 1.000s with start/stop only. That silently unplayed Dive's loop and land
passes, which named those keys - and is why `tools/check_anims.py` now verifies
the keys a slot names and not just that start and stop exist.

**One group, one file per folder.** Every `.kf` in `animations/<skeleton>/` is
added as an animation source, so a group defined in two files in the same folder
resolves by load order rather than by intent. Resolved in v0.81-82 by deleting
the `xclimbing1.kf` / `xClimbing1kna.kf` duplicates; no folder now declares a
group twice.

Measured clip lengths, used to set state durations, animation speeds and blend
times. As of v0.79 every set agrees, which it did not before:

| clip | length |
|---|---|
| `pwwalljump1` (brace) | 0.333s |
| `pwvault1/2/3`, `pwmantle1/2/3` | 0.40s |
| `pwboostup`, `pwboostbkl/r`, `pwropeidle`, `skydivel/r` | 0.50s |
| `pwladderidle` | 0.833s |
| `pwropeup/dwn`, `skydivefwd`, `dbsfall`, `dbsdive` | 1.00s |
| `pwroll1`, `pwwallhangidle` | 1.067s |
| `pwfalling` | 1.50s (loops 0.033-1.467) |
| `pwrun1` | 1.50s |
| `pwladderdwn` | 2.50s |
| `pwladderup` | 2.867s |
| `skydive1` (windup) | 9.967s, `release` at 5.967 |
| `skydive` (idle) | 2.867s, loops 10.533-13.333 |

Shimmy is keyed `pwshimmyl1`/`pwshimmyr1` in the three third-person sets and
`pwshimmy1l`/`pwshimmy1r` in the three `.1st` sets. Both spellings are listed
as interchangeable so either POV resolves.

`pwwalljump2` was removed from every set and is no longer referenced.
`pwropeup2` is gone with the last `xClimbing1kna.kf`; nothing played it.

**`dbsdive` was re-cut in v0.82** from 1.967s with `loop start` / `loop stop` to
a flat 1.000s with start/stop only. That silently unplayed Dive's loop and land
passes, which named those keys - and is why `tools/check_anims.py` now verifies
the keys a slot names and not just that start and stop exist.

**One group, one file per folder.** Every `.kf` in `animations/<skeleton>/` is
added as an animation source, so a group defined in two files in the same folder
resolves by load order rather than by intent. Two live cases:

- **Fixed for the human skeletons, still live for the beast one.**
  `xbase_animkna/` has both `xClimbing1kna.kf` and `xParkourwind1kna.kf`
  declaring `pwladderidle`, `pwladderup`, `pwladderdwn` and the three rope
  groups, at different times (`pwladderup` is 2.867s in one and 2.833s in the
  other). The human folders were resolved by deleting `xclimbing1.kf`; the same
  decision is still outstanding here.
- `xbase_animkna.1st/` shipped `xParkourwind1kna.kf` beside
  `xParkourwind1.1st.kf`, declaring the same groups with the pre-v0.79 timings
  and no `pwboostup` at all. That file is deleted here.

A state that ends before its clip cuts the animation, because leaving the state
cancels the group. Visible time is `min(state window, clip / speed)`:

| state | window | clip / speed |
|---|---|---|
| Vault | `0.45 + dist/500 + 0.06` ≈ 0.71s | 0.40 / 0.8 = 0.50s |
| Mantle | `max(0.58, rise/200) + 0.06` ≥ 0.64s | 0.40 / 0.7 = 0.57s |
| Roll | 1.07s | 1.067 / 1 = 1.07s |
| WallBoost | 0.52s | 0.50 / 1 = 0.50s |
| Stumble | 1.00s | 1.00 / 1 = 1.00s |
| Knockdown | 1.50s | 1.50 / 1 = 1.50s |

Skydive is not in this table: it is a pose with no state window, and it
resolves on its own clip keys.

Shimmy is the exception: it ends on travelled distance, not a clock, and hands
back to LedgeHang after each 30-unit step, so only as much of the 1.07s clip
plays as one step takes.

**Priority.** The engine plays its jump at `PRIORITY.Jump` (4) and locomotion at
`Movement` (5). Equal priority in all four bone groups means *neither* animation
is visible, so a default of `Jump` ties the engine mid-air and loses on the
ground. The default is `Weapon` (7); committed poses use `Block` (8).

**Blending.** `animations/*/xParkourwind1*.yaml` carries the blend rules. A
blend longer than about a third of the clip never fully asserts, and these clips
are short, so the wildcard base is 0.25s with shorter bottom-most overrides per
group. Bottom-most rule wins. The overrides are sized against clip length
*after* `speed`, which is why mantle's 0.4s clip gets 0.18s and vault's gets
0.13s.

## Skill checks never block a move

`core/skill_check.lua` holds the only difficulty and cost numbers. One formula:

```
chance = 30 + 0.55*Acrobatics + 0.35*(Agility - 50)
         scaled by Morrowind's own fatigue term, 1.25 - 0.5*(1 - fatigue/max)
```

A failed check **does not refuse the move and does not slow it down**. The move
happens; `pwfalling` takes over while the player is still in the air, and the
landing is a `Stumble` - `dbsfall`, one second, controls held. The stumble also
pre-empts the landing roll, because the stumble *is* the failure.

| move | difficulty | fatigue |
|---|---|---|
| LedgeHang, Roll, Ladder, Skydive | **exempt** | 0 |
| Vault | 8 | 3 |
| Shimmy | 15 | 2 |
| Mantle | 18 | 6 |
| Dive | 30 | 6 |
| WallBoost | 35 | 8 |
| WallJump | 45 | 10 |

**There is no fatigue gate.** Exhaustion is already in the formula through the
fatigue term, and nowhere else. An earlier affordability test sat *ahead* of the
"are skill checks even on" question, so switching skill checks off still left
every move blocked or halved on a low bar - which is exactly what "unresponsive
even with skill disabled" was.

A botch that ends on the ground (Vault, Mantle, WallBoost) resolves there; one
that ends in the air resolves on landing; and `Idle` clears a stale flag so it
can never survive into the next jump.

## Air poses: Skydive and the botched fall

`core/air_pose.lua` owns two cosmetic poses. **They are not states.** Airborne
stays active and keeps resolving the priority ladder, so a skydive can still be
interrupted by a vault, a mantle or a ledge. Nothing in that file moves the
actor: no teleport, no lerp, no backend event, and a marker enforces that.

**Skydive.** Arms by itself after 1.2s airborne with 1200 units of air below,
once per airborne period. Jump controls stay native throughout and **a jump
press cancels it**. The only mechanical effect is +250 Acrobatics and +150 Jump,
through `Owned`, so a save taken mid-skydive is undone on load.

`xSkyFall.kf` splits the move across **two groups** as of v0.82, which is what
makes the hand-over smooth: `skydive1` is the windup, and `skydive` is a
separate looping group with its own `loop start` / `loop stop`. Before the
split both halves were `skydive1` played with different keys, which needed a
forced replay of the group already playing.

The windup runs from `skydive1: start` to the author's own `skydive1: release`
key — 5.47 seconds of clip — played at whatever speed makes that take the
**Skydive Windup** setting, 3.0s by default. The key is read at runtime with
`animation.getTextKeyTime`, so moving it in the `.kf` retunes the mod without a
code change. After release the pose switches to `skydive`, and the movement keys
pick `skydivefwd`, `skydivel` or `skydiver` — pose only, no velocity of their
own.

**The botched fall.** `pwfalling`, looping, shown while a failed skill check is
outstanding and the player is still in the air.

## The landing you did not choose

`states/stumble.lua` is one state with two presentations:

| kind | clip | length | priority | when |
|---|---|---|---|---|
| `stumble` | `dbsfall` | 1.00s | FLOW_MAJOR | a botched manoeuvre |
| `knockdown` | `pwfalling` | 1.50s | **Scripted** | landing a released skydive |

Both hold the movement override and zero the controls for the clip's length,
then return to Idle. A skydive landing is checked **ahead** of both the botch
and the roll: it is the end of the fall, not a manoeuvre to recover from.

**There is no Lua setter for an engine knockdown.** `types.Actor.canMove()` only
reads one, and nothing in `openmw.types` sets it. So this is a held-controls
equivalent, which has the advantage of not depending on the fall damage landing
hard enough — and the skydive's +250 Acrobatics means it often would not. The
`Scripted` priority is what puts the pose over whatever the engine is doing,
including its own knockdown if the fall does trigger one.

`Scripted` is used here as a **uniform** tuple, which `core/anim_priority.lua`
warns against everywhere else. It is safe in this one place: the tuples the
engine builds constantly are shield (`Block`), torch (`Torch`) and hit (`Hit`),
and it never plays at uniform `Scripted` — only mwscript `PlayGroup` and other
mods' scripted animations do.

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
  That distance is horizontal from the feet: SharedRay's own `distance` is
  from the camera, which in third person sits behind the reach entirely.
- **`main.lua`'s `OVERRIDE_STATES` must list every state that holds an
  `I.Controls` override.** The safety net releases overrides once, on the
  frame FLOW leaves one of those states. It must not release every frame:
  `overrideMovementControls` is a single shared flag, and a per-frame release
  cancelled other mods' overrides (HookShot's rappel hang) while FLOW sat in
  Idle. Currently: Vault, Mantle, LedgeHang, Shimmy, WallBoost, Ladder, Roll.
- **One wall jump per confirmed landing.** `EngineSync` counts a landing once
  the feet have been down for `GROUND_CONFIRM`, every frame and in any state.
  The count used to live in Airborne, which leaves on the first grounded
  frame, so it never reached the threshold and the move worked once per
  session. Clearing in `AirborneState:enter` instead gives an unlimited climb,
  because WallJump exits back into Airborne.
- **Engine-side changes go through `core/owned.lua`.** Levitate and the stat
  bonuses are permanent once applied and are written into a save. `Owned`
  tracks what FLOW holds, `onSave` stores it, `onLoad` undoes it.
- **Ground state is read every frame.** `EngineSync` used a fixed 10 units per
  frame as its teleport test and returned before reading `isOnGround`, so at
  30 fps a running jump never left Idle. The test is now a horizontal speed.
- **Switching FLOW off, or Disable Indoors, stands the active state down** to
  Idle first, so its exit releases overrides and Levitate.
- **`playerAnim.lua`'s `resolveGroup` falls back through pending variant, then
  last played, then any key.** Ladder's variants are up/down/idle with no
  "right", so a replay that sets no variant must not resolve to nil.
- **`reissue()` checks `animation.isPlaying` before replaying.** AnimRefresh v4
  delivers on subscribe and twice on load, so it is called when nothing was
  lost; without the check, entering a cell while hanging restarts the pose.
- **`states/vault.lua`'s `apexPos` is a Bézier CONTROL point, not the arc's
  peak.** The backend evaluates `bezier(t, startPos, apexPos, landPos)`, whose
  peak at `t=0.5` is `0.25*start + 0.5*apex + 0.25*land`. `apexZ` solves that
  for the required peak, so the knob that sets vault arc height is
  `PEAK_SAFETY_CLEARANCE` (the curve peaks that far above the obstacle).
  `MIN_APEX_RISE` clamps the control point and never binds in the 25-50% band:
  the solved control point is already `1.5 * obstacle + 2 * clearance`.
- **AnimRefresh has to be in the manifest, not just in the zip.** v0.79 shipped
  `scripts/AnimRefresh/AnimRefresh_v6.lua` with no `PLAYER:` line for it, so
  `I.AnimRefresh` was nil and no pose survived a POV switch, a rest or a load.
  `tools/regressions.txt` carries the path, which is why the bump is caught.
- **`core/h3lp_compat.lua` prints its live timer backend once at load.** h3lp is
  a soft dependency tested with `vfs.fileExists`, so which implementation is
  running is otherwise unanswerable from a log.

### WallJump, rebuilt

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
safety net releases the override and the roll is silently jumpable and
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
