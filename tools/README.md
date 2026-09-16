# tools/

Three checks, none of which need a Lua interpreter or a running game. Run all
three before shipping a build.

    python3 tools/check_syntax.py                    # from the mod root
    python3 tools/check_regressions.py .
    python3 tools/check_context.py <cod3x_dir> .

## check_regressions.py

Asserts that previously-fixed bugs are still fixed, by looking for a marker
string per fix. Driven by `regressions.txt`, which is the file to edit.

**This exists because merges silently drop fixes.** FLOW is developed across
several drifting copies that get combined by hand, and by the time this was
written four diagnosed fixes had been lost that way — two of them twice. None
announced itself: the mod loads, the log is clean, and the symptom returns
looking like a new bug. This check found one the moment it was first run.

Add a line whenever a fix would be silent if reverted. Markers are matched
against code with comments stripped, so an entry cannot pass on a file where
only the explanation survived.

When a marker trips because the line was legitimately reworded, **update the
marker — do not delete the entry.** Deleting it is how the check quietly stops
covering that fix.

## check_context.py

Every `require('openmw.X')` against the `---@omw-context` header in the Cod3x
stubs for that module, resolved transitively from `.omwscripts` so a module
pulled in by `main.lua` inherits PLAYER context.

Two of the worst bugs in this project were context errors that this catches
mechanically:

* `openmw.nearby` (`local|player`) required from the GLOBAL backend — the whole
  script failed to start, so every Vault, Mantle and Shimmy fired its state and
  animation while nothing moved the player.
* `I.Settings.registerRenderer` called outside MENU — it logs a refusal and
  returns normally, so the group named a renderer that did not exist and the
  entire settings page vanished, including the Debug HUD toggle.

**Re-validate this against every Cod3x release.** Per RESEARCH §4.9 a reformat
alone once cut the previous checker from 25 modules to 19 without erroring — a
short read looks identical to a clean one. It prints nothing on success, so
confirm the module count separately when the stubs change:

    grep -l "omw-context" <cod3x_dir>/openmw/*.lua | wc -l

## check_syntax.py

Block structure (`function`/`if`/`for`/`while`/`do`/`repeat` against
`end`/`until`) and bracket balance, with comments and strings stripped.

It does **not** parse Lua. It catches the mistakes that come from scripted
edits — an unbalanced block after a bad find-and-replace — and nothing subtler.
A file can pass this and still be wrong.
