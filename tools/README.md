# tools/

Three mechanical checks. None of them needs OpenMW, a Lua interpreter or a
network connection — they are Python 3 and the mod's own source.

```sh
python3 tools/check_syntax.py .
python3 tools/check_context.py . /path/to/Cod3x
python3 tools/check_regressions.py .
```

All three exit 0 when clean and 1 when they find something, so they chain:

```sh
python3 tools/check_syntax.py . && \
python3 tools/check_context.py . ../Cod3x && \
python3 tools/check_regressions.py .
```

## Why these three

Each one guards a failure class that has cost a real testing session in this
project, and that a playtest is bad at catching.

**check_syntax.py** — a load error takes an entire script offline, and OpenMW
reports it once at startup where it is easy to miss. Every such failure this mod
has shipped was a balance failure: an `end` lost in a merge, a long comment that
swallowed the code after it, a paren left open. It is a structural check, not a
parser: it will not find a missing `then`.

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

The fixtures for all three are cheap to recreate; the negative cases that matter
are a missing `end`, an extra `end`, an unterminated string and long comment, an
unclosed paren, a require from the wrong context, a require mentioned only in a
comment, a marker satisfied only by a comment, and a renamed constant.
