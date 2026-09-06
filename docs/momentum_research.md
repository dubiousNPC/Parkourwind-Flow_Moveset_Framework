# Momentum: research notes for a future FLOW system

Not wired into FLOW. This documents two reference mods for when a
momentum system gets designed, once the core movement mechanics are
solid. Neither is altered - both are treated as read-only references.

## surf.zip (ErnGlider)

Interface names (both are separate registered mod-script interfaces):
`ErnGliderSurf` and `ErnGliderGlider`. Momentum-relevant one is Surf:

```lua
interfaceName = "ErnGliderSurf"
interface = {
    version = 1,
    isApplied = function() ... end,  -- bool
    remove = removeSurf,              -- function(wipeout: bool)
    jump = onJump,                    -- function() - call on an intentional jump while surfing
    apply = applySurf,                -- function() - starts surfing if canApply() passes
}
```

Soft-dependency pattern (this is the shape to copy for any future
integration): check `I.ErnGliderSurf` exists before touching it, same as
this project already does for `I.SharedRay`.

**Important constraint:** `applySurf()` is gated by `canApply()`, which
requires **a shield equipped in the off hand** - it's specifically a
shield-surfing mechanic, not a general-purpose momentum utility. Also
requires: not swimming, not levitating, weapon/spell not readied, and
fatigue above a minimum. Any future integration needs to either accept
that precondition or not really be "using ErnGliderSurf" at all.

**The interesting bit, per your note:** collision at speed is a *failure
state*, not just a wall bump. `onHit()` (surf.lua) plays a knockdown/hit
animation, deals a crime-worthy assault via `Crimes.commitCrime` if you
hit an actor, and `removeSurf(wipeout=true)` halves the run's earned
points. Worth studying as a model for "what happens when momentum-based
movement fails" - FLOW doesn't have an equivalent concept right now
(Vault/Mantle either complete or just don't trigger; there's no "you were
carrying speed and hit something" case).

**Architecture pattern worth reusing regardless of the shield gate:**
Surf never teleports - it drives `pself.controls.movement / sideMovement /
run` every frame and lets the engine's own collision resolve it. This is
*why* it never gets a player stuck in geometry (see the comparative
analysis from the sensor/WallJump work). Any FLOW momentum system that
wants to be as stable as surf.zip should look hard at doing the same:
modulate `self.controls.*`, don't drive position directly, and reserve
teleport-tweening (now collision-aware, see `flow_amf_backend.lua`) for
genuinely discontinuous moves like Vault/Mantle.

## SourceMovement.zip

A from-scratch Quake/Source movement simulation (ground accel/friction,
air strafing, bunnyhop, surf ramps, water) built entirely on top of
`self.controls`. No teleporting anywhere. Excellent reference, not because
it's a soft-dependency candidate (it isn't registering any interface -
it's a standalone full movement replacement, not something to call into)
but because of *how* it solves problems FLOW will eventually hit too:

- **OpenMW Lua has no velocity setter.** `speed.lua` works around this by
  raising the Speed attribute's *modifier* just enough that
  `getRunSpeed()` covers the simulated velocity, then drives
  `controls.movement = 1` to realize it. The slope (run-speed gained per
  Speed point) is calibrated empirically on the first two frames rather
  than reimplementing the engine's GMST formula - robust to
  encumbrance/Athletics/magic effects without having to track any of them.
  Directly relevant if a future FLOW momentum system ever wants speed to
  exceed the character's natural cap (carrying speed into a Sprint,
  say).
- **Vertical velocity has no getter either** - estimated from
  `(position.z - lastZ) / dt`. Same technique `core/engine_sync.lua`
  already uses (`ZSmoother`), good confirmation that's the right approach.
- **Ramp/surf sliding** uses Source's `ClipVelocity`: `v' = v - n(v·n)`,
  removing only the velocity component pointing into the surface so speed
  redirects along it instead of stopping dead. `surf.lua`'s `clip()`. This
  is the standard technique for "slide along a slope without losing all
  your momentum" and would be the right building block if FLOW ever wants
  slopes/ramps to feel less like a wall.
- **Softening engine gravity on a ramp** by injecting a `slowfall` magic
  effect modifier (tracked separately so it never touches a real
  Slow Fall spell/enchantment the player has), rather than fighting
  gravity directly - gravity itself isn't scriptable, so this reuses an
  existing effect the engine already respects.

**Compatibility warning worth flagging for later:** its own README says
plainly, "Overwrites the player's movement/jump controls each frame; mods
that also drive `self.controls.movement` on the player will conflict."
FLOW's Sprint/Vault/Mantle/LedgeHang/WallJump all touch `self.controls`
too - a future FLOW momentum system built the same way needs to actively
coordinate with (or fully replace) whichever FLOW state is active each
frame, not just run alongside it unaware.

## Takeaway for whenever this gets built

Both references agree on the core lesson: **`self.controls`-driven
movement is what buys collision safety for free.** Reserve
teleport-tweening for moves that are inherently discontinuous (a vault
arc, a mantle climb) where `self.controls` genuinely can't express the
motion, and keep those collision-aware (as `flow_amf_backend.lua` now is).
A FLOW momentum system modeled on surf.zip/SourceMovement's philosophy,
sitting alongside (not fighting) the Sprint/Vault/Mantle state machine,
is the shape to aim for - not a port of either mod's code.
