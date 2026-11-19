"""Source contract for the ``context_stats`` crash on a built-but-uncached domain.

No 3ds Max required.  The failure is in MAXScript, so the shape is pinned from
the source; ``test/live/context_stats_test.py`` proves the behaviour against a
real Max.

The defect (src/ms/mcp_context.ms, ``mcpH_context_stats``):

    local entry    = mcpCtxCachedEntry d      -- undefined when not cached
    local anyEntry = mcpCtxAnyEntry d         -- the last snapshot, any revision
    local cached   = entry != undefined
    local built    = anyEntry != undefined
    ...
    if built do
    (
        local w = entry[3]                    -- index into undefined
        if w == undefined do w = anyEntry[3]  -- fallback, one line too late

A domain that has been built once and then invalidated (revision bumped, cache
entry dropped) has ``built:true, cached:false`` and ``entry == undefined``, so
``entry[3]`` raises.  That is not a corner case: it is the state
``context_stats`` exists to describe, and it is reached by any scene write.

What this test pins:
  * the entry index is guarded before it is read;
  * the fallback to ``anyEntry`` is still there and is guarded too;
  * the rest of the function is untouched -- built/cached derivation, the
    state vocabulary, the "older snapshot is stale" rule, and every row field.

Usage:  python test/static/context_stats_guard_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPO, "src", "ms", "mcp_context.ms")

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def function_body(text: str, name: str) -> str:
    start = text.find("fn {0}".format(name))
    if start < 0:
        return ""
    end = text.find("\n)", start)
    return text[start:end + 2] if end > 0 else text[start:]


def strip_comments(text: str) -> str:
    """Drop MAXScript comments so a comment that *mentions* entry[3] is not
    mistaken for a read of it.  String literals in this function contain no
    comment marker, which is why a line scanner is enough here."""
    out = []
    in_block = False
    for line in text.splitlines():
        s = line
        if in_block:
            end = s.find("*/")
            if end < 0:
                out.append("")
                continue
            s = s[end + 2:]
            in_block = False
        while "/*" in s:
            start = s.find("/*")
            end = s.find("*/", start + 2)
            if end < 0:
                s = s[:start]
                in_block = True
                break
            s = s[:start] + s[end + 2:]
        cut = s.find("--")
        if cut >= 0:
            s = s[:cut]
        out.append(s)
    return "\n".join(out)


def main() -> int:
    text = open(SOURCE, encoding="utf-8").read()
    body = function_body(text, "mcpH_context_stats")

    print("1. the function is still there and still reports what it did")
    check("mcpH_context_stats is defined", bool(body))
    for field in ("domain", "revision", "changedAt", "sentAt", "built", "cached",
                  "valid", "supported", "stale", "state", "unreadable",
                  "updatedAt", "buildMs"):
        check("row carries {0}".format(field), '"{0}"'.format(field) in body)

    print("2. built and cached are still different questions")
    check("cached comes from the current-revision entry",
          "local cached = entry != undefined" in body)
    check("built comes from the last snapshot", "local built = anyEntry != undefined" in body)

    print("3. the entry is guarded before it is indexed")

    def unguarded(name):
        """Lines that read <name>[3] without proving <name> is defined."""
        needle = "{0}[3]".format(name)
        guard = "{0} != undefined".format(name)
        return [line.strip() for line in strip_comments(body).splitlines()
                if needle in line and guard not in line]

    check("entry index is guarded by entry != undefined",
          re.search(r"if\s+entry\s*!=\s*undefined.*entry\[3\]", body) is not None)
    check("entry index is guarded by count >= 3",
          re.search(r"entry\.count\s*>=\s*3", body) is not None)
    check("anyEntry index is guarded too",
          re.search(r"anyEntry\s*!=\s*undefined.*anyEntry\[3\]", body) is not None)
    check("every entry[3] read is guarded", not unguarded("entry"), "; ".join(unguarded("entry")))
    check("every anyEntry[3] read is guarded", not unguarded("anyEntry"),
          "; ".join(unguarded("anyEntry")))
    check("reads happen only when something was found",
          re.search(r"if\s+w\s*!=\s*undefined\s+do", body) is not None)
    empty_catches = re.findall(r"catch\s*\(\s*\)", body)
    check("no new empty catch was added",
          len(empty_catches) == 1,
          "expected only the pre-existing unreadable read, got {0}".format(len(empty_catches)))

    print("4. the surrounding behaviour is unchanged")
    check("state still derives from the snapshot vocabulary", "mcpCtxState" in body)
    check("an older snapshot is still stale", 'if not cached do state = "stale"' in body)
    check("valid still defaults to the cache state", "local valid = cached" in body)
    check("unreadable list is still published", "mcpGet w \"unreadable\"" in body)
    check("build duration is still published", "mcpGet w \"buildMs\"" in body)
    check("revision and changedAt still come from the domain arrays",
          "mcpCtxRev[i]" in body and "mcpCtxStamp[i]" in body)

    print("5. no refactor crept in")
    check("cache lookup helpers still used",
          "mcpCtxCachedEntry" in body and "mcpCtxAnyEntry" in body)
    check("function did not grow a new tool or handler",
          body.count("fn ") == 1, str(body.count("fn ")))

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("context_stats entry guard: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
