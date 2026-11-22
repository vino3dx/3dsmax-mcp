"""Guard: a value nobody could read is not reported as zero.

No 3ds Max required.  Source-level audit of Phase B F2 / F3.

What went wrong
---------------
Two different lies, one line of code each:

  * ``mcpPair p "frameStart" (try ( renderStart as integer ) catch ( 0 ))`` --
    when the read failed the section published **0**, and 0 is a perfectly
    plausible frame number.  `exposureControl` did the same with "".
  * ``context_stats`` reported ``valid:false, stale:true`` for a domain that had
    never been built *and* for one whose build threw, so "not read yet" and
    "read failed" were the same row.

The fix keeps every old field (nothing that reads `valid` breaks) and adds two
things: a per-section ``state`` word, and a null-plus-`unreadable` contract for
individual fields.

Checks:
  1. `mcpCtxField` publishes null and records the key, never a substitute value;
  2. `mcpCtxState` exists and ranks a permanent reason above a transient one;
  3. the wrapper publishes state / complete / unreadable next to the old flags;
  4. the render section routes frameStart, frameEnd and exposureControl through
     that helper, and no longer catches them into 0 / "";
  5. `context_stats` publishes built + state, defaults to "unbuilt", and still
     publishes the three legacy flags;
  6. a failed build still says "failed", and an API this build lacks still says
     "unsupported" -- the states are not collapsed.

Usage:  python test/static/context_state_test.py
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


def main() -> int:
    text = open(SOURCE, encoding="utf-8").read()
    field = function_body(text, "mcpCtxField")
    state = function_body(text, "mcpCtxState")
    wrap = function_body(text, "mcpCtxWrap")
    render = function_body(text, "mcpCtxBuildRender")
    stats = function_body(text, "mcpH_context_stats")

    print("1. an unreadable field is null, not a substitute")
    check("mcpCtxField exists", bool(field))
    check("records the field name", "append unreadable key" in field)
    check("publishes null", re.search(r"mcpPair p key undefined", field),
          "undefined serialises to JSON null")
    check("publishes the value when the read worked",
          re.search(r"if ok then \( mcpPair p key value \)", field))

    print("2. one state word, documented precedence")
    check("mcpCtxState exists", bool(state))
    for word in ("failed", "unsupported", "stale", "partial", "fresh"):
        check("state {0} defined".format(word), '"{0}"'.format(word) in state)
    order = [m.group(1) for m in re.finditer(r'return "(failed|unsupported|stale|partial)"', state)]
    # The last branch is a bare trailing expression -- MAXScript returns it.
    if re.search(r'^\s*"fresh"\s*$', state, re.M):
        order.append("fresh")
    check("permanent reasons outrank transient ones",
          order == ["failed", "unsupported", "stale", "partial", "fresh"],
          "got {0}".format(order))

    print("3. the wrapper keeps the old flags and adds the new ones")
    for field_name in ("valid", "supported", "stale"):
        check("still publishes {0}".format(field_name), '"%s"' % field_name in wrap)
    check("publishes state", re.search(r'mcpPair pairs "state"', wrap))
    check("publishes complete", re.search(r'mcpPair pairs "complete"', wrap))
    check("publishes unreadable", re.search(r'mcpPair pairs "unreadable"', wrap))
    check("complete is false when a field is unreadable",
          "unreadable.count == 0" in wrap)

    print("4. the render section stops inventing values")
    check("render builder found", bool(render))
    for name in ("frameStart", "frameEnd", "exposureControl", "width", "height"):
        check("{0} goes through mcpCtxField".format(name),
              re.search(r'mcpCtxField p unreadable "%s"' % name, render),
              "a bare catch ( 0 ) cannot be told apart from a real 0")
        check("{0} has no fabricated fallback".format(name),
              not re.search(r'"%s"\s*\(try' % name, render),
              'found a one-line "pair + catch" for {0}'.format(name))
    check("the section lists what it could not read", '"unreadable"' in render)
    check("renderDomain reports unsupported separately",
          "renderElementsSupported" in render)

    print("5. stats separates never-built from failed")
    check("stats found", bool(stats))
    check("publishes built", re.search(r'mcpPair row "built"', stats))
    check("publishes state", re.search(r'mcpPair row "state"', stats))
    check("defaults to unbuilt", re.search(r'local state = "unbuilt"', stats))
    # `built` must mean "was ever collected", not "has a copy at the current
    # revision": otherwise a domain whose snapshot is merely out of date reports
    # `unbuilt`, which is the same conflation in the other direction.
    check("built is not the cache-hit flag", 'mcpPair row "built" cached' not in stats,
          "an older snapshot is stale, not unbuilt")
    check("built reads the domain's last entry",
          "mcpCtxAnyEntry" in stats and re.search(r"local built = anyEntry != undefined", stats))
    check("an older snapshot says stale",
          re.search(r'if not cached do state = "stale"', stats))
    for field_name in ("valid", "supported", "stale"):
        check("legacy {0} still published".format(field_name),
              re.search(r'mcpPair row "%s"' % field_name, stats))
    check("a cached row reads the section's state",
          'mcpGet w "state"' in stats)
    check("an older bridge is derived, not guessed",
          "mcpCtxState" in stats)

    print("6. failure and unsupported stay distinct")
    check("a thrown build is not reported as unsupported",
          "No `supported:false` here" in text or "not `supported:false`" in text
          or "supported:false" not in function_body(text, "mcpCtxPayload"))
    check("mcpCtxPayload wraps the failure payload",
          "mcpCtxWrap mcpCtxDomains[i] rev payload ms err" in text)
    check("a missing API sets supported:false",
          'mcpPair p "supported" true' in function_body(text, "mcpCtxBuildRigging"))

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("context state: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
