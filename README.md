# Parkourwind-Flow_Moveset_Framework
A modular framework to animate and improve Morrowind's traversal gameplay

## Changes

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
