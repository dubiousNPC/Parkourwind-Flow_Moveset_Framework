#!/usr/bin/env python3
"""
check_regressions.py -- assert that previously-fixed bugs are still fixed.

    python3 tools/check_regressions.py [mod_dir]

Reads tools/regressions.txt and verifies each marker is still present in its
file. Exits non-zero if any are missing.

WHY: FLOW is developed across several drifting copies that get merged by hand.
Twice now a diagnosed fix has been silently dropped by a merge and the symptom
has come back looking like a new bug. Nothing announces it - the mod loads, the
log is clean. A marker check is the cheapest way to notice, and unlike a test
suite it needs no runtime.

This deliberately does NOT parse Lua. It looks for a literal substring. That is
crude, and it is the point: a check that is trivial to understand is one that
still runs in a year. The cost is that reformatting a guarded line can trip a
false alarm - when that happens, update the marker in regressions.txt rather
than deleting the entry.
"""
import os, re, sys

def strip_comments(src):
    """Markers must be live code, not a comment describing the fix that was
    removed. Several entries here name a constant that also appears in the
    comment block above it, so a comment-blind check would pass on a file where
    only the explanation survived."""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('--[[', i) or src.startswith('--[=[', i):
            j = src.find(']]', i)
            i = n if j < 0 else j + 2
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        out.append(src[i]); i += 1
    return ''.join(out)

def found(src, pattern):
    """Match on identifier boundaries, not bare substring.

    A plain `pattern in src` cannot distinguish ROLL_HEIGHT_WINDOW from
    ROLL_HEIGHT_WINDOW_RENAMED, so renaming a guarded constant - exactly the
    thing a merge does - passed the check. Found by deliberately breaking a
    marker and watching the checker stay green, which is the only way to know a
    checker works: run it against a known bug, then against known-good code.

    Patterns that are pure identifiers get \b anchors. Anything containing
    punctuation - `isPlaying(self, currentGroup)`, `type(dist)` - is matched
    literally, since a boundary means nothing there.
    """
    if re.fullmatch(r'\w+', pattern):
        return re.search(r'\b' + re.escape(pattern) + r'\b', src) is not None
    return pattern in src

def main():
    mod = sys.argv[1] if len(sys.argv) > 1 else '.'
    manifest = os.path.join(mod, 'tools', 'regressions.txt')
    if not os.path.exists(manifest):
        print("no manifest at %s" % manifest); return 2

    checked = missing = 0
    for raw in open(manifest, encoding='utf-8'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 3:
            print("  MALFORMED manifest line: %s" % line); missing += 1; continue
        rel, pattern, why = parts[0], parts[1], parts[2]

        path = os.path.join(mod, rel)
        checked += 1
        if not os.path.exists(path):
            print("  MISSING FILE  %s" % rel)
            print("                %s" % why)
            missing += 1
            continue

        src = open(path, encoding='utf-8', errors='replace').read()
        if rel.endswith('.lua'):
            src = strip_comments(src)
        if not found(src, pattern):
            print("  REGRESSED     %s  ->  '%s' not found" % (rel, pattern))
            print("                %s" % why)
            missing += 1

    print("%d markers checked, %d missing" % (checked, missing))
    return 1 if missing else 0

if __name__ == '__main__':
    sys.exit(main())
