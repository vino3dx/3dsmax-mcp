#!/usr/bin/env python3
"""Live proof that ``context_stats`` survives a built-but-uncached domain.

Needs a running 3ds Max with the bridge up.  Driven through
``MaxMcpServer.on_tools_call``, i.e. the real client path.

The defect: a domain that had been built once and then invalidated (any scene
write bumps its revision and drops the cache entry) has ``built:true,
cached:false`` and ``entry == undefined``.  ``mcpH_context_stats`` read
``entry[3]`` before checking, so it raised "Unknown property or index" on the
one state it exists to report -- and the whole tool call failed.

Scenarios:
  1. baseline context_stats
  2. context_get then context_stats (everything cached)
  3. write to the scene then context_stats immediately -- built:true,
     cached:false -- which used to throw
  4. five consecutive context_stats calls
  5. context_stats after the probe is deleted (another dirty->stale cycle)
  6. context_get still serves the same domains afterwards (no behaviour drift)

Usage:
    python test/live/context_stats_test.py --port 8765          # plan
    python test/live/context_stats_test.py --port 8765 --yes    # run
Exit codes: 0 all pass, 1 a case failed, 2 harness error.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "src", "python")
if SRC not in sys.path:
    sys.path.insert(0, SRC)

PROBE = "T15_CTX_PROBE_{0}".format(os.getpid())
FAILURES: List[str] = []


class Mcp:
    def __init__(self, port: int, language: str = "en") -> None:
        from maxmcp.config import Config
        from maxmcp.protocol import NullTransport
        from maxmcp.server import MaxMcpServer

        self.server = MaxMcpServer(
            Config(port=port, tool_profile="full", language=language, runtime_verify=False),
            NullTransport(),
        )

    def call(self, tool: str, arguments: Optional[Dict[str, Any]] = None) -> Tuple[bool, Any]:
        result = self.server.on_tools_call({"name": tool, "arguments": arguments or {}})
        blocks = result.get("content") or []
        text = blocks[0].get("text", "") if blocks else ""
        try:
            payload = json.loads(text)
        except ValueError:
            payload = text
        return (not bool(result.get("isError"))), payload


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def rows(payload: Any) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    if isinstance(payload, dict):
        for row in payload.get("domains") or []:
            if isinstance(row, dict) and row.get("domain"):
                out[str(row["domain"])] = row
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--yes", action="store_true", help="actually mutate the live scene")
    args = ap.parse_args()

    if not args.yes:
        print("DRY RUN - would reload the context module and cycle a temporary box '{0}'.".format(PROBE))
        print("Pass --yes to execute against the running 3ds Max on port {0}.".format(args.port))
        return 0

    mcp = Mcp(args.port)
    ok, status = mcp.call("bridge_status")
    if not ok:
        print("harness error: bridge not reachable on port {0}: {1}".format(args.port, status))
        return 2
    print("bridge: {0}".format(json.dumps(status, ensure_ascii=False)[:160]))

    try:
        src = REPO.replace("\\", "/") + "/src/ms/"
        ok, loaded = mcp.call("execute_maxscript", {"code":
            '( local repo = "{0}"; local r = "ok"; '
            'try ( fileIn (repo + "mcp_context.ms") ) catch ( r = "ERR:" + (getCurrentException() as string) ); '
            'mcpSetLanguage "en"; r )'.format(src)})
        check("context module reloaded",
              ok and isinstance(loaded, dict) and loaded.get("result") == "ok",
              json.dumps(loaded, ensure_ascii=False)[:200])

        print("1. baseline")
        ok, stats = mcp.call("context_stats")
        check("context_stats ok on entry", ok, json.dumps(stats, ensure_ascii=False)[:300])
        base = rows(stats)
        check("every domain has a row", len(base) >= 9, str(sorted(base)))

        print("2. everything cached")
        ok, _ = mcp.call("context_get", {})
        check("context_get ok", ok)
        ok, stats = mcp.call("context_stats")
        check("context_stats ok when cached", ok)
        cached_rows = [d for d, r in rows(stats).items() if r.get("cached")]
        check("at least one domain reports cached:true", bool(cached_rows), str(cached_rows))

        print("3. the crash case: built:true, cached:false")
        created, _ = mcp.call("create_box", {"name": PROBE, "length": 5, "width": 5, "height": 5})
        check("probe box created", created)
        ok, stats = mcp.call("context_stats")
        check("context_stats survives a dirty scene", ok,
              json.dumps(stats, ensure_ascii=False)[:300])
        scene = rows(stats).get("scene") or {}
        check("scene domain reports built:true", scene.get("built") is True, json.dumps(scene)[:200])
        check("scene domain reports cached:false", scene.get("cached") is False, json.dumps(scene)[:200])
        check("scene domain reports state stale", str(scene.get("state")) == "stale",
              repr(scene.get("state")))
        check("scene domain is listed as stale", scene.get("stale") is True, json.dumps(scene)[:200])
        check("revision is still reported", isinstance(scene.get("revision"), int),
              repr(scene.get("revision")))

        print("4. five consecutive calls")
        for i in range(5):
            ok, stats = mcp.call("context_stats")
            if not ok:
                break
        check("5 consecutive context_stats calls ok", ok,
              json.dumps(stats, ensure_ascii=False)[:200])

        print("5. another dirty -> stale cycle after the write is gone")
        deleted, _ = mcp.call("delete_objects", {"objects": [PROBE]})
        check("probe box deleted", deleted)
        ok, stats = mcp.call("context_stats")
        check("context_stats ok after the delete", ok,
              json.dumps(stats, ensure_ascii=False)[:200])
        scene = rows(stats).get("scene") or {}
        check("scene still reports built:true after the delete", scene.get("built") is True,
              json.dumps(scene)[:200])

        print("6. context_get is unaffected")
        ok, ctx = mcp.call("context_get", {"sections": ["scene", "selection"]})
        check("context_get ok", ok, json.dumps(ctx, ensure_ascii=False)[:200])
        check("context_get still reports a revision",
              isinstance(ctx, dict) and isinstance(ctx.get("revision"), int),
              json.dumps(ctx, ensure_ascii=False)[:200])
        ok, stats = mcp.call("context_stats")
        check("context_stats ok straight after context_get", ok)

    finally:
        try:
            mcp.call("delete_objects", {"objects": [PROBE]})
            print("  cleanup: removed " + PROBE)
        except Exception as exc:  # noqa: BLE001
            print("  cleanup WARNING: " + str(exc))

    print()
    if FAILURES:
        print("{0} case(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("context_stats entry guard (live): all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
