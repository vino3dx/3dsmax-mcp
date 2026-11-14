"""Guard: the numbers on the context stats page mean what their names say.

No 3ds Max required.  Source-level audit of a unit bug that no amount of
reading the JSON would reveal, because the value looked like a plausible
number.

Measured on 3ds Max 2022, after a refresh that took well under a second:

    "lastRefreshMs": 32243072

The handler assigned `mcpCtxLastFullScan = (timeStamp())`, and `timeStamp()` is
Max's uptime in milliseconds - so the field that means "how long the last
refresh took" was publishing "how long Max has been running". The panel and the
Context page both read it.

Checks:
  1. the refresh handler measures a duration (two timeStamp() readings, minus);
  2. it no longer stores a bare timestamp;
  3. the counter still starts at 0, so "never refreshed" is not a huge number;
  4. the refresh response carries `elapsedMs`, so a caller can see the cost of
     its own call without a second one;
  5. `valid`, `stale` and `supported` are still three separate fields - the
     whole point of the row is that a failed read, a missing API and an
     out-of-date copy are not the same thing.

Usage:  python test/static/context_stats_units_test.py
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
    refresh = function_body(text, "mcpH_context_refresh")
    stats = function_body(text, "mcpH_context_stats")

    print("1. lastRefreshMs is a duration")
    check("refresh handler found", bool(refresh))
    check("takes a start reading", re.search(r"local\s+t0\s*=\s*\(timeStamp\(\)\)", refresh))
    check("stores the difference",
          re.search(r"mcpCtxLastFullScan\s*=\s*\(timeStamp\(\)\)\s*-\s*t0", refresh),
          "expected (timeStamp()) - t0")
    bare = re.search(r"mcpCtxLastFullScan\s*=\s*\(timeStamp\(\)\)\s*$", refresh, re.M)
    check("does not store a bare timestamp", bare is None,
          "a bare timeStamp() is Max uptime, not elapsed ms")

    print("2. counter starts at zero")
    check("initialised to 0", re.search(r"if\s+mcpCtxLastFullScan\s*==\s*undefined\s+do\s+mcpCtxLastFullScan\s*=\s*0", text))

    print("3. the caller can see its own cost")
    check("refresh response carries elapsedMs", '"elapsedMs"' in refresh)
    check("stats response keeps lastRefreshMs", '"lastRefreshMs"' in stats)

    print("4. provenance stays three separate fields")
    for field in ("valid", "supported", "stale"):
        check("row publishes {0}".format(field), '"%s"' % field in stats)
    check("valid is read from the section when cached",
          'mcpToBool (mcpGet w "valid")' in stats)
    check("supported is read from the section when cached",
          'mcpToBool (mcpGet w "supported")' in stats)
    check("stale is derived from the cache miss", '"stale" (not cached)' in stats)

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("context stats units: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
