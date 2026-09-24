#!/usr/bin/env python3
"""
check_context.py - catch OpenMW script-context violations mechanically.

THE BUG CLASS THIS EXISTS FOR. OpenMW Lua modules are only available in certain
script contexts, and using one from the wrong context is the most damaging
mistake available in this project:

  * `openmw.nearby` required from global/flow_amf_backend.lua raised "module
    not found" at load, so the ENTIRE backend never started. Vault, Mantle and
    Shimmy all fired their states and their animations while nothing moved.
  * `I.Settings.registerRenderer` called from a player script does NOT raise.
    It logs a refusal and returns, so a pcall around it reported success and
    the whole settings page silently disappeared - twice.

The second one is why this check matters more than testing does: some context
violations are invisible at runtime. A file's context is declared once, in its
`---@omw-context` header, and that declaration can be compared against what
each module allows without running anything.

HOW IT WORKS
  Reads the allowed contexts for each openmw.* module from the Cod3x
  annotation stubs (`---@omw-context local|player` in openmw/<module>.lua),
  then reads each FLOW file's own `---@omw-context` header and reports any
  require() of a module that context is not allowed to use.

Cod3x is a DEV-TIME dependency of this check only. It is not required at
runtime and is not shipped with the mod.

Usage:  check_context.py <mod-root> <cod3x-root>
Exit 0 when clean, 1 on any violation, 2 on a setup problem.
"""
import re
import sys
from pathlib import Path

HEADER_RE = re.compile(r"---@omw-context\s+([a-z|]+)")
REQUIRE_RE = re.compile(r"""require\s*\(\s*['"](openmw[./][\w./]+)['"]\s*\)""")

# Long comments first, then line comments. The `---@omw-context` header is
# itself a comment, so it is read from the raw source BEFORE this runs.
LONG_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.S)
LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def strip_comments(src):
    """A require inside a COMMENT is not a require.

    This check reported global/flow_amf_backend.lua as violating its own
    context, because the file carries a comment recording the exact error that
    `require('openmw.nearby')` produced there - the comment that exists to stop
    the bug coming back was being read as the bug. A checker that cries wolf on
    the file it is protecting gets switched off, so the comment has to go.

    Crude on purpose: a `--` inside a string literal is treated as a comment
    here. That can only lose a require that follows it on the same line, which
    would be a false PASS - so the one case this gets wrong is guarded by the
    fact that nobody writes `require` after a `--` inside a string.
    """
    return LINE_COMMENT_RE.sub("", LONG_COMMENT_RE.sub("", src))

# A file declaring one of these is checked as that context. `all` in a Cod3x
# stub means every context, so nothing is ever rejected against it.
ALL = {"global", "local", "player", "menu", "load"}


def load_policy(cod3x_root):
    """module name -> set of contexts allowed, from the Cod3x stubs."""
    policy = {}
    stub_dir = cod3x_root / "openmw"
    if not stub_dir.is_dir():
        return policy
    for stub in sorted(stub_dir.glob("*.lua")):
        m = HEADER_RE.search(stub.read_text(encoding="utf-8", errors="replace")[:400])
        if not m:
            continue
        ctxs = set(m.group(1).split("|"))
        if "all" in ctxs:
            ctxs = set(ALL)
        policy["openmw." + stub.stem] = ctxs
    return policy


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    mod_root = Path(sys.argv[1])
    cod3x_root = Path(sys.argv[2])

    policy = load_policy(cod3x_root)
    if not policy:
        print(f"FAIL  no Cod3x stubs found under {cod3x_root}/openmw")
        return 2

    violations = []
    undeclared = []
    checked = 0

    for f in sorted(mod_root.rglob("*.lua")):
        # tools/ holds this script's own fixtures, never mod code.
        if "tools" in f.parts:
            continue
        src = f.read_text(encoding="utf-8", errors="replace")
        m = HEADER_RE.search(src[:400])
        if not m:
            undeclared.append(f)
            continue
        checked += 1
        file_ctxs = set(m.group(1).split("|"))
        if "all" in file_ctxs:
            file_ctxs = set(ALL)

        # Header read from the raw source above; requires read from the code.
        code = strip_comments(src)
        for mod in sorted(set(REQUIRE_RE.findall(code))):
            mod = mod.replace("/", ".")
            allowed = policy.get(mod)
            if allowed is None:
                continue        # openmw_aux and friends: no stub, no claim
            # A file is a violation only if NONE of its declared contexts can
            # use the module. A file declaring `local|player` is fine with a
            # module allowed in `player` alone, because it runs as one of them.
            if not (file_ctxs & allowed):
                violations.append(
                    f"{f}: requires {mod}, allowed in "
                    f"[{'|'.join(sorted(allowed))}], file declares "
                    f"[{'|'.join(sorted(file_ctxs))}]"
                )

    for v in violations:
        print("  " + v)

    # An undeclared file is not a violation, but it is unchecked, and an
    # unchecked file is how the nearby-in-global bug got in. Say so.
    for f in undeclared:
        print(f"  NOTE {f}: no ---@omw-context header, not checked")

    if violations:
        print(f"\nFAIL  {len(violations)} context violation(s)")
        return 1
    print(f"OK    {checked} declared file(s), 0 context violations"
          + (f" ({len(undeclared)} undeclared)" if undeclared else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
