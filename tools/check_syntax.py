#!/usr/bin/env python3
"""
check_syntax.py - structural Lua syntax check for every .lua file in the mod.

WHY THIS EXISTS RATHER THAN `luac -p`. There is no Lua toolchain in the
environment these checks run in, and no network to fetch one. A structural
check is not a parser and will not catch a semantic mistake, but it does catch
the class of error that has actually shipped in this project: an `end` lost in
a merge, a long comment that swallowed the code after it, a paren left open in
a refactor. Those are the failures that take a whole script offline with a
single load error, and they are all balance failures.

WHAT IT CHECKS
  * every string and comment terminates (short strings, [[ ]] / [==[ ]==]
    long strings, -- and --[[ ]] comments)
  * ( ) { } [ ] balance, reported at the opening token
  * do/if/for/while/function/repeat ... end/until balance, with a note of
    which construct was left open and on which line

WHAT IT DOES NOT CHECK
  Anything requiring a grammar: a missing `then`, an expression in statement
  position, a bad assignment target. Run the mod to find those.

Exit 0 when clean, 1 when anything is reported.
"""
import re
import sys
from pathlib import Path

# Keywords that open a block terminated by `end`.
OPENERS = {"do", "if", "for", "while", "function"}
# `repeat` is terminated by `until`, not `end`.
BRACKETS = {")": "(", "}": "{", "]": "["}


def tokenize(src, path, errors):
    """Yield (kind, text, line) for words and punctuation, skipping strings
    and comments. Appends to `errors` on an unterminated construct."""
    i, line, n = 0, 1, len(src)
    while i < n:
        c = src[i]

        if c == "\n":
            line += 1
            i += 1
            continue

        # Comments. Check before the long-bracket handling below, because a
        # --[[ comment is a comment first and a long bracket second.
        if src.startswith("--", i):
            j = i + 2
            m = re.match(r"\[(=*)\[", src[j:])
            if m:
                close = "]" + m.group(1) + "]"
                end = src.find(close, j + m.end())
                if end == -1:
                    errors.append(f"{path}:{line}: unterminated long comment --{m.group(0)}")
                    return
                line += src.count("\n", i, end)
                i = end + len(close)
            else:
                nl = src.find("\n", i)
                i = n if nl == -1 else nl
            continue

        # Long strings.
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            end = src.find(close, i + m.end())
            if end == -1:
                errors.append(f"{path}:{line}: unterminated long string {m.group(0)}")
                return
            line += src.count("\n", i, end)
            i = end + len(close)
            continue

        # Short strings. Lua does not allow a raw newline inside one, so a
        # newline before the closing quote is itself the error.
        if c in "\"'":
            j, quote = i + 1, c
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "\n":
                    errors.append(f"{path}:{line}: unterminated string ({quote})")
                    return
                if src[j] == quote:
                    break
                j += 1
            else:
                errors.append(f"{path}:{line}: unterminated string ({quote})")
                return
            i = j + 1
            continue

        if c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_]\w*", src[i:])
            yield ("word", m.group(0), line)
            i += m.end()
            continue

        # Skip numbers whole so 0x1p+4 and 1e-3 cannot leak stray tokens.
        if c.isdigit():
            m = re.match(r"0[xX][0-9a-fA-F.]+([pP][-+]?\d+)?|[\d.]+([eE][-+]?\d+)?", src[i:])
            i += m.end() if m else 1
            continue

        if c in "(){}[]":
            yield ("punct", c, line)
        i += 1


def check(path):
    src = path.read_text(encoding="utf-8", errors="replace")
    errors = []
    brackets = []   # (char, line)
    blocks = []     # (keyword, line)

    # `for`/`while` open ONE block, but their header ends with `do`, which is
    # also an opener in its own right. The first version of this checker tested
    # `prev_word in ("for", "while")` when it met `do`, which is wrong for every
    # real loop: in `for k in pairs(t) do` the previous word is `t`, not `for`.
    # Every `for` and `while` in the mod was therefore counted twice and 22
    # files were reported as missing an `end`. A flag set by the loop keyword and
    # consumed by its `do` is what the grammar actually says.
    pending_do = False

    prev_word = None
    for kind, text, line in tokenize(src, path, errors):
        if kind == "punct":
            if text in "({[":
                brackets.append((text, line))
            else:
                want = BRACKETS[text]
                if not brackets:
                    errors.append(f"{path}:{line}: '{text}' with nothing open")
                elif brackets[-1][0] != want:
                    o, oline = brackets[-1]
                    errors.append(f"{path}:{line}: '{text}' closes '{o}' opened at line {oline}")
                    brackets.pop()
                else:
                    brackets.pop()
            prev_word = None
            continue

        # `end` closes one block; `until` closes a repeat.
        if text == "end":
            if not blocks:
                errors.append(f"{path}:{line}: 'end' with no open block")
            else:
                kw, kwline = blocks[-1]
                if kw == "repeat":
                    errors.append(f"{path}:{line}: 'end' closes the 'repeat' at line {kwline}, which needs 'until'")
                blocks.pop()
        elif text == "until":
            if not blocks or blocks[-1][0] != "repeat":
                errors.append(f"{path}:{line}: 'until' with no open 'repeat'")
            else:
                blocks.pop()
        elif text == "repeat":
            blocks.append(("repeat", line))
        elif text == "do":
            # The `do` closing a for/while header belongs to the block that
            # keyword already opened. A bare `do ... end` block opens its own.
            if pending_do:
                pending_do = False
            else:
                blocks.append(("do", line))
        elif text in OPENERS:
            blocks.append((text, line))
            if text in ("for", "while"):
                pending_do = True

        prev_word = text

    for ch, line in brackets:
        errors.append(f"{path}:{line}: '{ch}' never closed")
    for kw, line in blocks:
        closer = "until" if kw == "repeat" else "end"
        errors.append(f"{path}:{line}: '{kw}' never closed (missing '{closer}')")

    return errors


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(root.rglob("*.lua"))
    if not files:
        print(f"no .lua files under {root}")
        return 1

    all_errors = []
    for f in files:
        all_errors.extend(check(f))

    for e in all_errors:
        print("  " + e)

    if all_errors:
        print(f"\nFAIL  {len(all_errors)} problem(s) in {len(files)} file(s)")
        return 1
    print(f"OK    {len(files)} file(s) structurally clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
