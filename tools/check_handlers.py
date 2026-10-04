#!/usr/bin/env python3
"""
check_handlers.py - validate engine handler names and their context.

THE BUG CLASS. A name under `engineHandlers` that is not a documented engine
handler is REJECTED by the engine, with one log line and no further warning:

    [E] Not supported handler 'UiModeChanged' in L@0x1[...animrefresh_v4.lua]

AnimRefresh v4 registered `UiModeChanged` - which is an EVENT, sent to player
scripts by OpenMW's built-in scripts - under `engineHandlers`. Its Rest, Travel,
Training and Jail refresh therefore never ran, in every mod shipping that file.
Nothing in this toolchain looked at handler names, so a one-line mistake
survived a full sweep and a release.

The inverse is just as quiet: an engine handler placed under `eventHandlers` is
never called by anything, and there is no log line at all.

HOW THIS DIFFERS FROM LOADING THE MODULE. The upstream checker loads each file
and inspects the table the engine would read, which is the stronger method.
There is no Lua interpreter in this environment, so this one parses instead -
and the objection to parsing is real: a regex cannot tell a table key from an
assignment inside an inline `function() ... end`. This handles that by
brace-matching the table literal and taking keys at depth 1 ONLY, so a nested
assignment cannot be mistaken for a handler name. It reports the file and key
count it inspected, so a run that parsed nothing cannot look like a pass.

Usage:  check_handlers.py <root> [--skip NAME,NAME]
Exit 0 clean, 1 on any finding, 2 on a setup problem.
"""
import re
import sys
from pathlib import Path

# From the OpenMW engine-handlers reference. Context sets, not just names.
HANDLERS = {
    "onInterfaceOverride": {"global", "menu", "local", "player", "load"},
    "onInit": {"global", "local", "player"},
    "onUpdate": {"global", "local", "player"},
    "onSave": {"global", "local", "player"},
    "onLoad": {"global", "local", "player"},
    "onNewGame": {"global"},
    "onPlayerAdded": {"global"},
    "onObjectActive": {"global"},
    "onActorActive": {"global"},
    "onItemActive": {"global"},
    "onActivate": {"global"},
    "onNewExterior": {"global"},
    "onDropped": {"global"},
    "onPlaced": {"global"},
    "onActive": {"local", "player"},
    "onInactive": {"local", "player"},
    "onTeleported": {"local", "player"},
    "onActivated": {"local", "player"},
    "onConsume": {"local", "player"},
    "onFrame": {"menu", "player"},
    "onKeyPress": {"menu", "player"},
    "onKeyRelease": {"menu", "player"},
    "onControllerButtonPress": {"menu", "player"},
    "onControllerButtonRelease": {"menu", "player"},
    "onInputAction": {"menu", "player"},
    "onTouchPress": {"menu", "player"},
    "onTouchRelease": {"menu", "player"},
    "onTouchMove": {"menu", "player"},
    "onMouseButtonPress": {"menu", "player"},
    "onMouseButtonRelease": {"menu", "player"},
    "onMouseWheel": {"menu", "player"},
    "onConsoleCommand": {"menu", "player"},
    "onViewportResized": {"menu", "player"},
    "onQuestUpdate": {"player"},
    "onStateChanged": {"menu"},
    "onContentFilesLoaded": {"load"},
}

# Known events, sent by built-in scripts. These belong under eventHandlers.
KNOWN_EVENTS = {"UiModeChanged"}

ALL_CTX = {"global", "local", "player", "menu", "load"}
HEADER_RE = re.compile(r"---@omw-context\s+([a-z|]+)")


def strip_comments(src):
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    return re.sub(r"--[^\n]*", "", src)


def table_body(src, name):
    """The text inside `name = { ... }`, brace-matched. None if absent."""
    m = re.search(re.escape(name) + r"\s*=\s*\{", src)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        c = src[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def depth1_keys(body):
    """Keys written at depth 1 of a table literal. Nested assignments ignored.

    Brackets AND function bodies both count as nesting. Counting only brackets
    is not enough: `onUpdate = function() local x = {...} end` closes its paren
    immediately, so `local x` would read as depth 1 and be reported as a bogus
    handler. That false positive is the whole reason parsing has a bad name
    here, so it is handled rather than tolerated.
    """
    keys = []
    depth = 0
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        word = re.match(r"[A-Za-z_]\w*", body[i:])
        if word:
            w = word.group(0)
            prev_ok = i == 0 or not re.match(r"[\w.:]", body[i - 1])
            if w == "function" and prev_ok:
                depth += 1
                i += word.end()
                continue
            # `end` closes a function body; `do`/`then` open blocks inside one.
            if w in ("do", "then", "repeat") and prev_ok:
                depth += 1
                i += word.end()
                continue
            if w in ("end", "until") and prev_ok:
                depth -= 1
                i += word.end()
                continue
            if depth == 0 and prev_ok:
                m = re.match(r"([A-Za-z_]\w*)\s*=(?!=)", body[i:])
                if m:
                    keys.append(m.group(1))
                    i += m.end()
                    continue
            i += word.end()
            continue
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
        i += 1
    return keys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    skip = set()
    if "--skip" in sys.argv:
        skip = set(sys.argv[sys.argv.index("--skip") + 1].split(","))

    findings = []
    files = inspected = 0

    for f in sorted(root.rglob("*.lua")):
        if f.name in skip or "tools" in f.parts:
            continue
        raw = f.read_text(encoding="utf-8", errors="replace")
        src = strip_comments(raw)

        m = HEADER_RE.search(raw[:400])
        ctxs = set(m.group(1).split("|")) if m else set()
        if "all" in ctxs or "runtime" in ctxs or not ctxs:
            ctxs = set(ALL_CTX)

        eh = table_body(src, "engineHandlers")
        ev = table_body(src, "eventHandlers")
        if eh is None and ev is None:
            continue
        files += 1

        for k in depth1_keys(eh or ""):
            inspected += 1
            if k in KNOWN_EVENTS:
                findings.append(f"{f}: EVENT-AS-HANDLER '{k}' under engineHandlers "
                                f"- the engine rejects it; move to eventHandlers")
            elif not k.startswith("on"):
                findings.append(f"{f}: NOT-A-HANDLER '{k}' under engineHandlers")
            elif k not in HANDLERS:
                findings.append(f"{f}: UNKNOWN-HANDLER '{k}' - not in the documented set")
            elif ctxs and not (ctxs & HANDLERS[k]):
                findings.append(f"{f}: WRONG-CONTEXT '{k}' allowed in "
                                f"[{'|'.join(sorted(HANDLERS[k]))}], file declares "
                                f"[{'|'.join(sorted(ctxs))}]")

        for k in depth1_keys(ev or ""):
            inspected += 1
            if k in HANDLERS:
                findings.append(f"{f}: HANDLER-AS-EVENT '{k}' under eventHandlers "
                                f"- nothing will ever call it")

    for x in findings:
        print("  " + x)

    if findings:
        print(f"\nFAIL  {len(findings)} finding(s); inspected {inspected} key(s) "
              f"in {files} file(s)")
        return 1
    print(f"OK    {inspected} handler/event key(s) in {files} file(s), 0 findings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
