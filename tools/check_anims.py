#!/usr/bin/env python3
"""check_anims.py - every group playerAnim.lua plays must exist in every .kf set.

THE BUG CLASS. `animation.playBlended` on a group the actor's skeleton does not
define is a SILENT no-op: no error, no clip, and the actor keeps the pose it
had. Nothing in the log says so. Two live examples found by this check:

  * pwwalljump2 existed in ONE of six sets while playerAnim listed it as a
    random alternative to pwwalljump1, so half of all wall jumps played nothing.
  * the three .1st sets key shimmy pwshimmy1l/pwshimmy1r and the three
    third-person sets pwshimmyl1/pwshimmyr1, so one naming is always silent.

OpenMW resolves animation sources per skeleton and does NOT fall back to
xbase_anim: third person loads base_anim.nif, or base_animkna.nif for beasts,
plus base_anim_female.nif for non-beast females; first person always loads
base_anim.1st.nif and adds base_animkna.1st.nif or base_anim_female.1st.nif.
So a group is only playable for the players whose set declares it.

Text keys are read LENGTH-PREFIXED. A regex sweep runs past one string's length
prefix into the next and invents keys that do not exist; that mistake once
broke Mantle, LedgeHang and left-Shimmy for two releases.

Usage:  check_anims.py <mod-root>
Exit 0 clean, 1 if any slot is unplayable on some skeleton, 2 on a setup problem.
"""
import glob
import os
import re
import struct
import sys

KEYLINE = re.compile(r'^\s*([A-Za-z][\w ]*?)\s*:\s*(.+?)\s*$')
# Any quoted identifier inside a `group` or `variants` value is a group name:
# those are the only quoted strings in those captures. Matching only `pw*`
# silently dropped every skydive slot.
QUOTED = re.compile(r'"([A-Za-z][A-Za-z0-9_]*)"')


def kf_keys(path):
    """{group: {key: time}}, read length-prefixed."""
    data = open(path, 'rb').read()
    out, i, n = {}, 0, len(data)
    while i < n - 4:
        ln = struct.unpack_from('<I', data, i)[0]
        if 2 <= ln <= 256 and i + 4 + ln <= n:
            raw = data[i + 4:i + 4 + ln]
            if all(32 <= c < 127 or c in (10, 13) for c in raw):
                t = None
                if i >= 4:
                    (f,) = struct.unpack_from('<f', data, i - 4)
                    if 0.0 <= f <= 10000.0:
                        t = f
                if t is not None:
                    for line in raw.decode('ascii', 'replace').splitlines():
                        m = KEYLINE.match(line)
                        if m:
                            out.setdefault(m.group(1).strip().lower(), {})[
                                m.group(2).strip().lower()] = t
                i += 4 + ln
                continue
        i += 1
    return out


def braced(src, i):
    """src[i] is '{'. Returns (inner text, index after the matching '}')."""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                return src[i + 1:j], j + 1
    raise ValueError('unbalanced brace')


def keytable(entry, name):
    """{variant: key} from a variantStartKey / variantStopKey table."""
    m = re.search(re.escape(name) + r'\s*=\s*\{', entry)
    if not m:
        return {}
    inner, _ = braced(entry, m.end() - 1)
    return {k: v for k, v in re.findall(r'(\w+)\s*=\s*"([^"]*)"', inner)}


def scalar(entry, name):
    m = re.search(re.escape(name) + r'\s*=\s*"([^"]*)"', entry)
    return m.group(1) if m else None


def slots(root):
    """[(label, [group names], startKey, stopKey)] from playerAnim's GROUPS.

    A `variants` direction is its OWN slot: up, down and idle are different
    clips, not alternatives, so a missing pwladderup must not be excused by a
    present pwladderdwn. Only a list under `group` is interchangeable.

    The KEYS each slot names are carried too. A group that exists while the
    start key it is played with does not is silent, exactly like a missing
    group - and that is not hypothetical: dbsdive lost its `loop start` and
    `loop stop` keys in a re-cut, which left Dive's loop and land passes
    unplayable while this check still reported them fine.
    """
    found_at = glob.glob(os.path.join(root, '**', 'playerAnim.lua'), recursive=True)
    if not found_at:
        raise SystemExit('no playerAnim.lua under %s' % root)
    src = open(found_at[0], encoding='utf-8').read()
    body, _ = braced(src, src.index('{', src.index('local GROUPS')))
    found = []
    for m in re.finditer(r'(\w+)\s*=\s*\{', body):
        state = m.group(1)
        if state in ('variants',):
            continue
        entry, _ = braced(body, m.end() - 1)
        sk = scalar(entry, 'startKey') or 'start'
        tk = scalar(entry, 'stopKey') or 'stop'
        vm = re.search(r'variants\s*=\s*\{', entry)
        if vm:
            vstart = keytable(entry, 'variantStartKey')
            vstop = keytable(entry, 'variantStopKey')
            inner, _ = braced(entry, vm.end() - 1)
            for d in re.finditer(r'(\w+)\s*=\s*(\{[^}]*\}|"[A-Za-z][A-Za-z0-9_]*")', inner):
                names = QUOTED.findall(d.group(2))
                if names:
                    v = d.group(1)
                    found.append(('%s/%s' % (state, v), names,
                                  vstart.get(v, sk), vstop.get(v, tk)))
        else:
            gm = re.search(r'group\s*=\s*(\{[^}]*\}|"[A-Za-z][A-Za-z0-9_]*")', entry)
            names = QUOTED.findall(gm.group(1)) if gm else []
            if names:
                found.append((state, names, sk, tk))
    return found


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    root = argv[0]
    anim_root = os.path.join(root, 'animations')
    if not os.path.isdir(anim_root):
        print('no animations/ under %s' % root)
        return 2

    sets = {}
    for d in sorted(os.listdir(anim_root)):
        files = sorted(glob.glob(os.path.join(anim_root, d, '*.kf')))
        if files:
            merged = {}
            for f in files:
                merged.update(kf_keys(f))
            sets[d] = merged
    if not sets:
        print('no .kf files found')
        return 2

    names = sorted(sets)
    found = slots(root)
    if not found:
        print('parsed no group names out of playerAnim.lua')
        return 2

    print('skeleton sets: %s' % ', '.join(names))
    print('slots playerAnim can play: %d\n' % len(found))

    bad = 0
    for label, alts, sk, tk in found:
        broken = []
        for d in names:
            ok = [g for g in alts
                  if sk in sets[d].get(g, {}) and tk in sets[d].get(g, {})]
            if not ok:
                broken.append(d)
        keys = '' if (sk, tk) == ('start', 'stop') else '  [%s..%s]' % (sk, tk)
        if broken:
            bad += 1
            print('  UNPLAYABLE %-16s %s%s  -> no clip in: %s'
                  % (label, '/'.join(alts), keys, ', '.join(broken)))
        else:
            print('  ok         %-16s %s%s' % (label, '/'.join(alts), keys))

    print('\nclip lengths (stop - start), per set:')
    every = sorted({g for slot in found for g in slot[1]})
    print('  %-16s %s' % ('group', ''.join('%-14s' % d[:13] for d in names)))
    for g in every:
        cells = []
        for d in names:
            k = sets[d].get(g, {})
            if 'start' in k and 'stop' in k:
                cells.append('%-14s' % ('%.3f' % (k['stop'] - k['start'])))
            elif k:
                cells.append('%-14s' % ('keys: ' + ','.join(sorted(k))[:7]))
            else:
                cells.append('%-14s' % '-')
        print('  %-16s %s' % (g, ''.join(cells)))

    if bad:
        print('\nFAIL  %d slot(s) unplayable on at least one skeleton' % bad)
        return 1
    print('\nOK    every slot has a playable clip on every skeleton')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
