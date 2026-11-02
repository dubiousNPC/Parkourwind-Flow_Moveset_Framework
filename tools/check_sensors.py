#!/usr/bin/env python3
"""check_sensors.py - a state that reads a sensor must have asked for it.

THE BUG CLASS. Sensors are demand-gated in main.lua:

    local asked = want and (intents.jump or debugOn)

so `Sensor.data` is only fresh for a state whose `traits.sensors` lists it, and
only on a frame where jump is held - OR in debug mode, which runs them
regardless so the HUD stays live. That last clause is the trap: a read placed
outside those conditions WORKS WITH THE HUD ON and sees a reset table in play.
A bug that disappears when you turn on the tool you would debug it with is the
worst shape there is, and nothing else in this toolchain can see it.

THE RULE. A read of `Sensor.data` needs `sensors.forward`; a read of
`SensorExt.data` needs `sensors.ledge` - UNLESS the read is inside `canEnter`.
canEnter runs during the offering state's frame, so Vault, Mantle and LedgeHang
legitimately read sensors they never declare: Idle and Airborne declared them,
and jump is held because that is what prompted the offer.

Function extents are found by brace- and `function`/`end`-matching, the same
method tools/check_handlers.py uses, so a nested closure cannot shift the
boundary.

LIMITS. Reads are matched by the module's conventional local name, so an alias
(`local S = require(...sensor)`; `S.data`) is invisible. And the canEnter
exemption trusts that whoever OFFERS the state declared the sensor; a new
offerer without the trait gets a silent refusal, which the sim catches and this
does not.

Usage:  check_sensors.py <mod-root>
Exit 0 clean, 1 on any finding, 2 on a setup problem.
"""
import glob
import os
import re
import sys

NEEDS = {'Sensor.data': 'forward', 'SensorExt.data': 'ledge'}
WORD = re.compile(r'[A-Za-z_]\w*')


def strip_comments(src):
    # Block comments keep their newlines, or every reported line below one
    # drifts upward.
    src = re.sub(r'--\[(=*)\[.*?\]\1\]', lambda m: '\n' * m.group(0).count('\n'),
                 src, flags=re.S)
    return re.sub(r'--[^\n]*', '', src)


def declared_sensors(src):
    """{'forward': True, ...} from this file's BaseState.new traits."""
    m = re.search(r'BaseState\.new\(\s*"(\w+)"\s*,', src)
    if not m:
        return None, {}
    name = m.group(1)
    sm = re.search(r'sensors\s*=\s*\{([^}]*)\}', src[m.end():])
    if not sm:
        return name, {}
    return name, {k: True for k in re.findall(r'(\w+)\s*=\s*true', sm.group(1))}


# Lua block structure. `function`, `if`, `for`, `while` and `repeat` each take
# exactly one `end` (or `until`); `then`, `else` and `elseif` take none.
#
# Counting `then` as an opener - which the first cut of this file did, copying
# check_handlers.py - breaks on `if a then ... elseif b then ... end`: two
# `then` against one `end`, so the depth never returns to zero and canEnter's
# span swallows the rest of the file. Mantle's canEnter uses elseif, so the
# checker silently excused every later read. A negative test caught it.
OPENERS = ('function', 'if', 'for', 'while', 'repeat')


def can_enter_span(src):
    """(start, end) character offsets of canEnter's body, or None."""
    m = re.search(r'function\s+\w+:canEnter\s*\(', src)
    if not m:
        return None
    depth = 1
    i = src.index(')', m.end() - 1) + 1
    start = i
    pending_do = False      # a `for`/`while` already counted; its `do` is syntax
    while i < len(src):
        w = WORD.match(src, i)
        if w:
            word = w.group(0)
            if i == 0 or not re.match(r'[\w.:]', src[i - 1]):
                if word in OPENERS:
                    depth += 1
                    pending_do = word in ('for', 'while')
                elif word == 'do':
                    if pending_do:
                        pending_do = False      # consumed
                    else:
                        depth += 1              # a standalone do ... end block
                elif word in ('end', 'until'):
                    depth -= 1
                    if depth == 0:
                        return start, i
            i = w.end()
            continue
        i += 1
    return start, len(src)


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    root = argv[0]
    files = sorted(glob.glob(os.path.join(root, '**', 'states', '*.lua'),
                             recursive=True))
    files = [f for f in files if 'optional' not in f.replace(os.sep, '/')]
    if not files:
        print('no state files under %s' % root)
        return 2

    findings = []
    checked = 0
    for f in files:
        src = strip_comments(open(f, encoding='utf-8').read())
        name, sensors = declared_sensors(src)
        if not name:
            continue
        span = can_enter_span(src)
        rel = os.path.relpath(f, root).replace(os.sep, '/')
        for token, trait in NEEDS.items():
            for m in re.finditer(re.escape(token), src):
                checked += 1
                if span and span[0] <= m.start() < span[1]:
                    continue        # offering state's frame; see the docstring
                if not sensors.get(trait):
                    line = src.count('\n', 0, m.start()) + 1
                    findings.append(
                        '%s:%d: %s reads %s outside canEnter without '
                        'traits.sensors.%s' % (rel, line, name, token, trait))

    for x in findings:
        print('  ' + x)
    if findings:
        print('\nFAIL  %d read(s) a demand-gated sensor it never asked for' % len(findings))
        return 1
    print('OK    %d sensor read(s) in %d state file(s), all accounted for'
          % (checked, len(files)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
