# H3lp Yours3lf and Cod3x: evaluation notes

## H3lp Yours3lf - adopted (timers only), documented but not adopted (s3lf)

### Adopted: `core/h3lp_compat.lua`

FLOW now soft-depends on `scripts.s3.every` and `scripts.s3.cooldown`:

- **`states/sprint.lua`'s controller throttle** (`main.lua`'s
  `IDLE_THROTTLE_INTERVAL`, via `H3.every()`) is exactly what
  `scripts.s3.every` is for - "did at least one interval pass?"
- **`states/wall_jump.lua`'s cooldown** (via `H3.cooldown()`) replaced a
  hand-rolled `dt`-decrement counter, and fixed a real bug in it: the old
  counter only decremented while `AirborneState:update()` was actually
  being called, so it silently froze while grounded/Idle and could
  wrongly block a legitimate wall-jump attempt much later. `H3.cooldown()`
  (and its fallback) use `core.getRealTime()` internally, so elapsed time
  is correct regardless of whether/how often the calling code runs.

**Why a compat shim instead of calling `scripts.s3.*` directly:** those
modules are plain `require()`'d files, not something exposed through
`openmw.interfaces` like `I.SharedRay` or `I.ErnGliderSurf` - a missing
file throws on `require()` rather than returning `nil`. `core/h3lp_compat.lua`
wraps that `require()` in `pcall`, and provides small independent
fallback implementations (not copies of H3's code - just the same tiny
algorithm, since there's really only one sane way to write "fire once per
interval") with an identical calling convention, so nothing else in FLOW
needs to know or care whether H3 is actually installed.

Also worth knowing: `scripts.s3.*` utility modules only need H3's data
directory merged (`require()` succeeding is enough) - unlike `s3lf` below,
they don't need "H3lp Yours3lf.esp" enabled in the content list at all.

### Documented, not adopted: `s3lf`

`s3lf` (`I.s3.lf`) is a facade over `openmw.self` - `s3lf.fatigue.current`
instead of `types.Actor.stats.dynamic.fatigue(mwSelf).current`, values
cached on first access rather than re-derived from the API each time.

**Didn't adopt it, for two reasons:**

1. **Caching correctness is a real open question, not a nitpick.** Looking
   at `lf.lua`'s metatable: most fields are resolved once via `__index`
   and then `rawset` onto the instance table - meaning every *subsequent*
   read of that key returns the cached value directly, without hitting
   the metatable again. `position` and `cell` are the only fields
   explicitly refreshed every tick (in `s3lf`'s own `onUpdate`). Whether
   things like `s3lf.fatigue.current` stay live afterward depends on
   whether `types.Actor.stats.dynamic.fatigue(actor)` returns a
   live-updating handle or a frozen snapshot at call time - I can't verify
   which from reading the code alone, and FLOW's own existing pattern
   (idle.lua, sprint.lua, vault.lua, mantle.lua) is to re-call that
   accessor fresh every time specifically to avoid ever trusting a stale
   value. Given `states/sprint.lua`'s fatigue gate directly controls
   whether the player is allowed to sprint, vault, or mantle, a
   silently-stale reading there is a correctness bug, not a rounding
   error. This needs to actually be tested in-game before I'd trust it,
   not assumed from source.

2. **It requires the ESP, not just the data directory.** `s3lf` registers
   itself per-object (`---@omw-context local | player`) via
   `interfaceName = "s3"` - for `I.s3.lf` to exist on the player at all,
   "H3lp Yours3lf.esp" needs to be enabled in the content list, since
   that's what attaches the script to actors in the first place. That's a
   real, user-facing dependency (like requiring a master file), not the
   "just have the data directory present" shape `scripts.s3.every`/
   `cooldown` and `I.SharedRay`/`I.ErnGliderSurf` all have. Worth being
   deliberate about taking that on, rather than adopting it opportunistically.

**Indirect win worth keeping in mind regardless:** `s3lf` is imported as
`local s3lf = require(...)`, never as `local self = ...`. That sidesteps
the exact naming collision that caused the `wall_jump.lua` bug from
before (colon-method syntax implicitly shadows `self` with the receiver
table) - not because `s3lf` technically prevents it (nothing can; it's a
Lua language semantic, not an API design problem), but because nobody's
in the habit of naming a local `s3lf` inside a state file the way they
are `self`. If `s3lf` does get adopted later, that's a real (if modest)
reason to prefer it as the standard import name across FLOW's state
files, on top of whatever ergonomics/caching questions get resolved first.

### Not touched: `statemachine.lua`

A more full-featured FSM (entry/exit/tick callbacks, deferred
transitions, transition validation, history) than FLOW's hand-rolled
`core/state_manager.lua`. Genuinely nicer in places, but adopting it would
mean rewriting every state file's `enter`/`exit`/`update` calling
convention to match its API - a full architectural change, not something
to pull in opportunistically alongside a timer utility. Flagging it here
in case a future rewrite of `state_manager.lua` is ever on the table.

## Cod3x

Not a runtime dependency at all - it's Lua Language Server annotations
plus a context-checking plugin for editing OpenMW Lua in an IDE (VSCode +
the Sumneko/Lua plugin, or anything else LuaLS-compatible). Nothing to
integrate into FLOW's code. Added a template `.luarc.json` at the project
root (`./​.luarc.json`) based on Cod3x's own example - fill in the two
`/absolute/path/to/Cod3x` placeholders with wherever you extract it
locally, and your editor gets real autocomplete/hover docs for
`openmw.*`, plus warnings for exactly the kind of context mistake called
out in its own pitch (`:teleport` only working in a GLOBAL script, for
instance - directly relevant, since `global/flow_amf_backend.lua` is the
only file in FLOW that calls it).
