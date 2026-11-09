# tools/

Seven mechanical checks. None of them needs OpenMW, a Lua interpreter or a
network connection — they are Python 3 and the mod's own source.

```sh
python3 tools/check_syntax.py .
python3 tools/check_requires.py .
python3 tools/check_sensors.py .
python3 tools/check_context.py . /path/to/Cod3x
python3 tools/check_handlers.py .
python3 tools/check_anims.py .
python3 tools/check_regressions.py .
```

All of them exit 0 when clean and 1 when they find something, so they chain:

```sh
python3 tools/check_syntax.py . && \
python3 tools/check_requires.py . && \
python3 tools/check_sensors.py . && \
python3 tools/check_context.py . ../Cod3x && \
python3 tools/check_handlers.py . && \
python3 tools/check_anims.py . && \
python3 tools/check_regressions.py .
```

## Why these

Each one guards a failure class that has cost a real testing session in this
project, and that a playtest is bad at catching.

**check_syntax.py** — a load error takes an entire script offline, and OpenMW
reports it once at startup where it is easy to miss. Every such failure this mod
has shipped was a balance failure: an `end` lost in a merge, a long comment that
swallowed the code after it, a paren left open. It is a structural check, not a
parser: it will not find a missing `then`.

**check_requires.py** — OpenMW resolves `require` against the VFS **root**,
never relative to the requiring script. v0.78b moved the Lua under
`scripts/Flow/` and left the paths alone: 27 files with no syntax error at all
and 13 unresolved module paths. The first one raises while `main.lua` is still
loading, so no handler is ever registered and the mod is indistinguishable in
game from not being installed. A syntax check cannot see this, and neither can
reading the files one at a time.

**check_anims.py** — `animation.playBlended` on a group the skeleton does not
define is a silent no-op: no error, no clip, the actor keeps its pose. Skeletons
do not fall back on each other, so a clip missing from one `.kf` set works for
you and not for half your players. It found `pwwalljump2` present in one set of
six while `playerAnim` randomised between it and `pwwalljump1`, and shimmy keyed
`pwshimmy1l/1r` in the `.1st` sets against `pwshimmyl1/r1` in the rest. Each
`variants` direction is its own slot, because up, down and idle are different
clips and a present `pwladderdwn` must not excuse a missing `pwladderup`. Text
keys are read length-prefixed; a regex sweep runs past one string's length
prefix into the next and invents keys that do not exist.

**check_sensors.py** — sensors are demand-gated: `Sensor.data` is only fresh
for a state whose `traits.sensors` lists it, on a frame where jump is held, **or
in debug mode**, which runs them regardless so the HUD stays live. That last
clause is the trap. A read placed outside those conditions works with the HUD on
and sees a reset table in play, so the bug vanishes the moment you turn on the
tool you would debug it with. A read inside `canEnter` is exempt: that runs
during the offering state's frame, which is why Vault, Mantle and LedgeHang
legitimately read sensors they never declare.

**check_context.py** — OpenMW modules are restricted to certain script contexts,
and some violations are *silent*. `require('openmw.nearby')` from the global
script raised at load and took the whole movement backend down; that one at
least announced itself. `I.Settings.registerRenderer` from a player script logs
a refusal and **returns normally**, so a `pcall` around it reported success while
the entire settings page vanished — twice. No amount of playtesting finds that
reliably. Reads the policy from Cod3x's `---@omw-context` annotation stubs.
Cod3x is a dev-time dependency of this check only and is not shipped.

**check_regressions.py** — five verified fixes have been silently lost in later
merges, each rediscovered the expensive way. A marker per fix costs two lines.
Markers live in `regressions.txt` and can be positive (must be present) or
`not-present` (must not have come back) — the second kind matters because two of
the worst bugs were something *returning*, not something going missing.

**check_handlers.py** — a name under `engineHandlers` that is not a documented
engine handler is rejected by the engine with one log line and no other warning.
AnimRefresh v4 registered `UiModeChanged` — an **event** — as an engine handler,
so its Rest/Travel/Training/Jail refresh never ran in any mod shipping that
file, and nothing in this toolchain looked at handler names. The inverse is
quieter still: an engine handler under `eventHandlers` is never called and logs
nothing. Checked against the documented handler set and each file's
`---@omw-context`.

It parses rather than loading the module, since there is no Lua interpreter
here. The usual objection — that a regex cannot tell a table key from an
assignment inside an inline `function() ... end` — is handled by brace- *and*
`function`/`end`-matching and taking keys at depth 1 only. That exact false
positive showed up in its own negative suite and was fixed before shipping.

## Adding a marker

Append to `regressions.txt` whenever a fix is verified in play:

```
file: states/ledge_hang.lua
why: without this a stale lip teleported the player to 0,0
needs: LIP_SANITY_RANGE
```

Bare identifiers match on word boundaries, so `FOO` will not be satisfied by
`FOO_RENAMED`. Anything else matches as a literal substring. Comments are
stripped from the target file first, so a marker cannot be satisfied by a
comment that merely mentions the constant — which is exactly what a lost fix
looks like after a careless merge.

## These checkers are tested

Each one has been run against deliberately broken fixtures as well as against
the mod, because a checker that passes everything is worse than no checker: it
grants false confidence. Two bugs were found that way and both were the
dangerous direction — silently passing, or crying wolf:

- `check_syntax.py` counted `for k, v in pairs(t) do` as two open blocks (the
  `for` and the `do`), because it tested whether the word before `do` was `for`,
  which in any real loop it is not. It reported 22 problems in 24 good files.
- `check_regressions.py` used plain substring matching, so a renamed constant
  satisfied its own marker. Fixed with word-boundary anchoring.
- `check_context.py` read a `require` inside a *comment* as a real require, and
  so reported the global backend as violating its own context — flagging the
  very comment that exists to stop that bug returning.
- `check_handlers.py` and the first cut of `check_sensors.py` counted `then` as
  a block opener, so an `if a then … elseif b then … end` was two `then`
  against one `end` and the depth never came back. In `check_handlers.py` that
  made every key after the first such handler invisible: a planted
  `UiModeChanged` under `engineHandlers` behind an `elseif` went unreported —
  the exact mistake the checker was written for. `function`, `if`, `for`,
  `while` and `repeat` each take one `end`; `then`, `else` and `elseif` take
  none, and a `do` is only an opener when no `for`/`while` already counted it.
  Both were found by planting the bug, not by reading the code.

The fixtures for all three are cheap to recreate; the negative cases that matter
are a missing `end`, an extra `end`, an unterminated string and long comment, an
unclosed paren, a require from the wrong context, a require mentioned only in a
comment, a marker satisfied only by a comment, and a renamed constant.

## sim/ - behaviour, not text

```sh
python3 tools/sim/run_lua.py tools/sim/test_fsm.lua .
python3 tools/sim/run_lua.py tools/sim/test_interop.lua .
```

Loads the real `main.lua` and `global/flow_amf_backend.lua` against mock
`openmw.*` modules: a box world with a ray caster, simple gravity, a clock, and
the backend's events delivered in-process. 54 checks cover sensor cost,
Vault/Mantle and their refusals, the hang/shimmy/boost chain, WallBoost under
an overhang, the Acrobatics roll, the botched fall, fatigue, the ladder,
standing down, real-collision behaviour, a lost hang, and a climb press right
after a Shimmy step.

The ray caster behaves like the engine on real meshes: **a ray that starts on
a surface hits it** (`M.surfaceStartHits`), and SharedRay's normal can be
skewed the way a rendering ray's is on a carved face (`M.renderNormal`). The
boxes used to be friendlier than real collision, and every vault, mantle and
ledge grab passed here while all of them were refused in the game. Needs the system `liblua5.4` (driven through ctypes), not an
interpreter. The mock is deliberately crude - it proves the state machine and
the holds, not how a move feels.

`test_interop.lua` (33 checks) puts FLOW beside the mods that hold the player:
WhyWalk mounts, Boats and Caravans, and Hookshot's hang. Each is emulated by
what its source does, which is the override flag, Levitate, a placement every
frame, and the Jump key. It covers `I.Flow` yields across a ride, a mount's
cliff leap, a hand-over mid-Vault, the jump that drops a hang, and a caravan
passenger. It also covers the Skydive's descent gate and its whole lifecycle.

Both suites run under real **LuaJIT**, the engine's interpreter, as well as
Lua 5.4: `luajit tools/sim/test_fsm.lua .`. The mock is plain Lua 5.1, and the
two languages disagree silently on things like `math.atan(y, x)`.
