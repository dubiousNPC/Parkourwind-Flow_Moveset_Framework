#!/usr/bin/env python3
"""check_requires.py - every require() must resolve to a file in the VFS.

THE BUG CLASS. OpenMW resolves `require` against the VFS ROOT, not relative to
the requiring script. Moving the Lua into scripts/Flow/ without rewriting the
paths therefore leaves `require('states/base_state')` pointing at nothing, and
the failure is total: the first unresolved require raises while main.lua is
still loading, so no handler is ever registered and the mod does nothing. That
is indistinguishable in game from "the mod is not installed".

v0.78b shipped exactly that: 27 files with no syntax error at all and 13
unresolved module paths.

Dots and slashes are interchangeable in an OpenMW module path, so both spellings
resolve to the same file here.

Usage:  check_requires.py <mod-root>
Exit 0 clean, 1 on any unresolved path, 2 on a setup problem.
"""
import glob
import os
import re
import sys

REQUIRE = re.compile(r"""require\s*\(\s*['"]([^'"]+)['"]\s*\)""")


def strip_comments(src):
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    return re.sub(r"--[^\n]*", "", src)


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    root = argv[0]
    files = sorted(glob.glob(os.path.join(root, '**', '*.lua'), recursive=True))
    files = [f for f in files if 'tools' not in os.path.relpath(f, root).split(os.sep)]
    if not files:
        print('no .lua files under %s' % root)
        return 2

    vfs = {os.path.relpath(f, root).replace(os.sep, '/')[:-4] for f in files}

    bad = {}
    checked = 0
    for f in files:
        src = strip_comments(open(f, encoding='utf-8').read())
        for m in REQUIRE.finditer(src):
            mod = m.group(1)
            if mod.startswith('openmw'):
                continue
            checked += 1
            if mod.replace('.', '/') not in vfs:
                bad.setdefault(mod, set()).add(
                    os.path.relpath(f, root).replace(os.sep, '/'))

    for mod in sorted(bad):
        print('  UNRESOLVED  %-34s required by %s'
              % (mod, ', '.join(sorted(bad[mod]))))

    if bad:
        print('\nFAIL  %d unresolved module path(s) of %d require(s) in %d file(s)'
              % (len(bad), checked, len(files)))
        return 1
    print('OK    %d module require(s) in %d file(s) all resolve' % (checked, len(files)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
