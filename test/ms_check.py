#!/usr/bin/env python3
"""Static sanity checker for the 3dsmax-mcp MAXScript bridge.

Three independent checks, all of which map to a real failure mode:

1. encoding  -- MAXScript reads a .ms file with the ANSI code page unless the
                file is UTF-8 **with** BOM.  A UTF-8 file without BOM that
                contains non-ASCII text is mis-decoded (Autodesk documents that
                only "UTF-8 with BOM" is supported for international text).
2. structure -- unbalanced () [] / unterminated string literals make fileIn
                raise a compile error, so the whole bridge silently dies.
3. symbols   -- identifiers in the mcp*/MCP* namespace that are used but never
                defined (left over from a refactor) fail at run time.
4. callchain -- MAXScript cannot read a member off the result of a method call:
                "obj.Method().Member" is a **syntax** error, so the whole file
                fails to compile and every symbol in it stays undefined.

Usage:  python ms_check.py <bridge-dir> [more dirs ...]
Exit code 1 when a hard problem is found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

IDENT = re.compile(r"\b(mcp[A-Za-z0-9_]*|MCP[A-Za-z0-9_]*)\b")


def strip_code(src: str):
    """Return (code_without_comments_or_strings, list_of_lex_errors)."""
    out = []
    errors = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            while i < n and src[i] not in "\r\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            if j < 0:
                errors.append(("unterminated block comment", src.count("\n", 0, i) + 1))
                break
            i = j + 2
        elif c == "@" and i + 1 < n and src[i + 1] == '"':
            j = src.find('"', i + 2)
            while j >= 0 and j + 1 < n and src[j + 1] == '"':
                j = src.find('"', j + 2)
            if j < 0:
                errors.append(("unterminated verbatim string", src.count("\n", 0, i) + 1))
                break
            out.append(" __STR__ ")
            i = j + 1
        elif c == '"':
            j = i + 1
            closed = False
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    closed = True
                    break
                if src[j] in "\r\n":
                    break
                j += 1
            if not closed:
                errors.append(("unterminated string literal", src.count("\n", 0, i) + 1))
                break
            out.append(" __STR__ ")
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out), errors


def check_structure(code: str, name: str):
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for idx, ch in enumerate(code):
        if ch in "([{":
            stack.append((ch, idx))
        elif ch in ")]}":
            if not stack:
                line = code.count("\n", 0, idx) + 1
                return [f"{name}:{line}: unmatched closing '{ch}'"]
            top, pos = stack.pop()
            if top != pairs[ch]:
                line = code.count("\n", 0, idx) + 1
                return [f"{name}:{line}: '{ch}' closes '{top}'"]
    if stack:
        top, pos = stack[-1]
        line = code.count("\n", 0, pos) + 1
        return [f"{name}:{line}: unclosed '{top}' (1 of {len(stack)} open)"]
    return []


DEF_FN = re.compile(r"\bfn\s+(\w+)")
DEF_GLOBAL = re.compile(r"\bglobal\s+([^\n;]+)")
DEF_STRUCT = re.compile(r"\bstruct\s+(\w+)")
DEF_ASSIGN = re.compile(r"^\s*(\w+)\s*=(?!=)", re.M)


def defined_names(files):
    defs = {}
    for path in files:
        src = path.read_text(encoding="utf-8", errors="replace")
        code, _ = strip_code(src)
        for m in DEF_FN.finditer(code):
            defs.setdefault(m.group(1), []).append(path.name)
        for m in DEF_STRUCT.finditer(code):
            defs.setdefault(m.group(1), []).append(path.name)
        for m in DEF_GLOBAL.finditer(code):
            for part in re.split(r"[,]", m.group(1)):
                ident = part.strip().split(":")[0].strip()
                if re.fullmatch(r"\w+", ident or ""):
                    defs.setdefault(ident, []).append(path.name)
        for m in DEF_ASSIGN.finditer(code):
            defs.setdefault(m.group(1), []).append(path.name)
    return defs


# Identifiers that are defined by 3ds Max itself, not by the bridge.
BUILTIN = {
    "mcp",  # never a symbol, guard against false positives
}

# Locals (parameters / for-loop vars) are per-function; collect them crudely.
LOCAL_DECL = re.compile(r"\blocal\s+([^\n;]+)")
FOR_VAR = re.compile(r"\bfor\s+(\w+)\s+(?:in|=)")
PARAM = re.compile(r"(?:^|[\s(,])(\w+)\s*:\s*(?=[^=])")


def used_names(files):
    used = {}
    for path in files:
        src = path.read_text(encoding="utf-8", errors="replace")
        code, _ = strip_code(src)
        # remove local declarations, for vars and named params: they are not globals
        scrub = code
        for m in LOCAL_DECL.finditer(code):
            for part in m.group(1).split(","):
                ident = part.strip().split(":")[0].strip()
                scrub = re.sub(r"\b%s\b" % re.escape(ident), " ", scrub) if ident else scrub
        for m in FOR_VAR.finditer(code):
            scrub = re.sub(r"\b%s\b" % re.escape(m.group(1)), " ", scrub)
        for m in PARAM.finditer(code):
            scrub = re.sub(r"\b%s\b" % re.escape(m.group(1)), " ", scrub)
        for m in IDENT.finditer(scrub):
            word = m.group(1)
            # "#name" is a MAXScript Name literal, not a symbol reference
            if m.start() > 0 and scrub[m.start() - 1] == "#":
                continue
            if word in ("mcp", "MCP"):
                continue
            used.setdefault(word, set()).add(
                "%s:%d" % (path.name, scrub.count("\n", 0, m.start()) + 1)
            )
    return used


def main(argv):
    dirs = [Path(a) for a in argv[1:]] or [Path(".")]
    files = []
    for d in dirs:
        files.extend(sorted(p for p in d.glob("*.ms") if p.is_file()))
    if not files:
        print("no .ms files found")
        return 2

    problems = 0
    print("== 1. encoding ==")
    for path in files:
        raw = path.read_bytes()
        has_bom = raw.startswith(b"\xef\xbb\xbf")
        non_ascii = any(b > 127 for b in raw)
        if has_bom:
            state = "utf-8+bom  OK"
        elif not non_ascii:
            state = "ascii       OK"
        else:
            try:
                raw.decode("gbk")
                state = "ansi(gbk)   OK"
            except UnicodeDecodeError:
                state = "utf-8 no bom + non-ASCII  <-- MAXScript reads ANSI"
                problems += 1
        print(f"  {path.name:22s} {state}")

    print("\n== 2. structure (brackets / strings) ==")
    for path in files:
        src = path.read_text(encoding="utf-8", errors="replace")
        code, lex_errors = strip_code(src)
        errs = [f"{path.name}:{ln}: {msg}" for msg, ln in lex_errors]
        errs += check_structure(code, path.name)
        if errs:
            problems += 1
            for e in errs:
                print("  FAIL " + e)
        else:
            print(f"  {path.name:22s} balanced")

    print("\n== 3. method-call member access (syntax error in MAXScript) ==")
    CALL_MEMBER = re.compile(r"\w\s*\.\s*\w+\s*\([^()]*\)\s*\.")
    for path in files:
        src = path.read_text(encoding="utf-8", errors="replace")
        code, _ = strip_code(src)
        hits = [
            f"{path.name}:{code.count(chr(10), 0, m.start()) + 1}: {m.group(0).strip()}"
            for m in CALL_MEMBER.finditer(code)
        ]
        if hits:
            problems += 1
            for h in hits:
                print("  FAIL " + h)
        else:
            print(f"  {path.name:22s} clean")

    print("\n== 4. mcp*/MCP* symbols used but never defined ==")
    defs = defined_names(files)
    used = used_names(files)
    missing = {k: v for k, v in used.items() if k not in defs and k not in BUILTIN}
    if missing:
        for name in sorted(missing):
            problems += 1
            where = ", ".join(sorted(missing[name])[:6])
            print(f"  UNDEFINED {name:26s} used at {where}")
    else:
        print("  none")

    print("\n%d problem(s)" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
