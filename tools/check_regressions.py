#!/usr/bin/env python3
"""
check_regressions.py - assert that fixes which have been lost before are present.

WHY. Five separate fixes in this project have been fixed, verified in play, and
then silently lost in a later merge:

  * the collision-cage revert in the Vault/Mantle backend
  * LIP_SANITY_RANGE, whose absence teleported the player to 0,0
  * the Vault/Mantle animation randomiser (list-form GROUPS entries)
  * WallBoost on jump alone, which the back-key requirement made unreachable
  * playerAnim's isPlaying guard in reissue(), without which AnimRefresh
    restarts a pose that was never lost

Every one cost a testing session to rediscover. A marker per fix costs nothing
and finds all five in under a second.

FORMAT of regressions.txt - one record per fix, blank-line separated:

    file: <path relative to the mod root>
    why: <one line: what breaks if this is missing>
    needs: <literal text, or a bare identifier, that must appear in the file>
    needs: <a record may list several>
    needs: not-present <text that must NOT appear>

NEGATIVE MARKERS matter as much as positive ones. Two of the worst bugs in this
project were something coming BACK rather than something going missing:
`openmw.nearby` reappearing in the global script kills the whole backend at
load, and `jump AND back` reappearing in Shimmy makes WallBoost unreachable. A
checker that can only assert presence cannot guard either.

Matching:
  * a bare identifier (\\w+ only) is matched on WORD BOUNDARIES, so
    ROLL_HEIGHT_WINDOW does not match ROLL_HEIGHT_WINDOW_RENAMED. This
    mattered: the first version of this script used plain substring matching
    and passed its own negative test, which is exactly the failure a checker
    must not have.
  * anything else is matched as a literal substring.
  * comments are stripped before matching, so a marker cannot be satisfied by
    a comment that merely mentions the constant it is meant to guard. The
    surviving-comment case is real - that is how a lost fix looks after a
    careless merge.

Exit 0 when every marker is present, 1 otherwise.
"""
import re
import sys
from pathlib import Path

IDENT = re.compile(r"\w+\Z")
NEGATIVE = "not-present "


def strip_comments(src):
    """Remove long comments then line comments. Deliberately crude: a `--`
    inside a string becomes a comment here. That can only cause a FALSE
    FAILURE, never a false pass, which is the safe direction for this tool."""
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    return src


def found(src, pattern):
    if IDENT.match(pattern):
        return re.search(r"\b" + re.escape(pattern) + r"\b", src) is not None
    return pattern in src


def parse(spec_path):
    records, cur = [], None
    for lineno, raw in enumerate(spec_path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            if not line and cur:
                records.append(cur)
                cur = None
            continue
        if ":" not in line:
            print(f"{spec_path}:{lineno}: expected 'key: value', got {raw!r}")
            sys.exit(2)
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if key == "file":
            if cur:
                records.append(cur)
            cur = {"file": value, "why": "", "needs": []}
        elif cur is None:
            print(f"{spec_path}:{lineno}: '{key}' before any 'file:'")
            sys.exit(2)
        elif key == "why":
            cur["why"] = value
        elif key == "needs":
            cur["needs"].append(value)
        else:
            print(f"{spec_path}:{lineno}: unknown key {key!r}")
            sys.exit(2)
    if cur:
        records.append(cur)
    return records


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    spec = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / "regressions.txt"

    if not spec.exists():
        print(f"FAIL  marker file not found: {spec}")
        return 2

    records = parse(spec)
    total = sum(len(r["needs"]) for r in records)
    failures = []

    for rec in records:
        target = root / rec["file"]
        if not target.exists():
            failures.append((rec, None, f"file missing: {rec['file']}"))
            continue
        src = strip_comments(target.read_text(encoding="utf-8", errors="replace"))
        for pattern in rec["needs"]:
            if pattern.startswith(NEGATIVE):
                needle = pattern[len(NEGATIVE):].strip()
                if found(src, needle):
                    failures.append((rec, needle, f"{rec['file']}: {needle!r} is BACK"))
            elif not found(src, pattern):
                failures.append((rec, pattern, f"{rec['file']}: missing {pattern!r}"))

    for rec, _pattern, note in failures:
        print(f"  {note}\n      why: {rec['why']}")

    if failures:
        print(f"\nFAIL  {len(failures)} of {total} marker(s) failed "
              f"across {len(records)} guarded fix(es)")
        return 1
    print(f"OK    {total}/{total} markers pass across {len(records)} guarded fix(es)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
