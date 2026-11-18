"""Contract check for bridge recovery after `bridge_stop`.

No 3ds Max required -- this is a source-level audit of a one-way door.

What happened, measured on 3ds Max 2022: `bridge_stop` runs `mcpNetStop()`,
which stops the 25 ms pump timer, closes the listener and sets
`mcpRunning = false`. The pump is the only thing that ever executes Max-side
code, so once it is gone there is no code left that could bring it back. The
`bridge_restart` tool exists and `server.py` even treats its failure as
expected, but the command has to travel over the very socket that was just
closed, so it can never arrive. Recovery was possible only by typing
`mcpNetStart()` into the MAXScript Listener by hand.

The fix is the one place that still runs inside Max: the panel. It gets a
Start / Restart button that calls `mcpNetStart()` directly.

Checks:
  1. the recovery helpers exist in mcp_ui.ms and call mcpNetStart;
  2. the panel never calls mcpNetStop -- a second way to close the only door
     is a second way to lose the session;
  3. the button exists, is wired to the helper, and is labelled from live
     state when the panel opens;
  4. the bridge globals are declared, otherwise the state read is silently
     `undefined` and the button always claims the bridge is down;
  5. both `if` branches in the new helpers are parenthesised blocks (the
     `then <expr>` / newline / `else` form does not parse);
  6. the catalog says how to recover, and no longer claims bridge_restart can
     rescue a stopped bridge;
  7. `bridge_stop` is not an MCP tool at all (Phase B F14). The panel button
     covers a human in Max; it does not cover an AI client that would close the
     door and then have no way to reopen it, which is what the tool allowed.

Usage:  python test/static/bridge_recovery_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
UI = os.path.join(REPO, "src", "ms", "mcp_ui.ms")
CATALOG = os.path.join(REPO, "src", "python", "maxmcp", "catalog", "core.py")

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def function_body(text: str, name: str) -> str:
    """Text of `fn <name>` up to the closing paren at column 0."""
    start = text.find("fn {0}".format(name))
    if start < 0:
        return ""
    end = text.find("\n)", start)
    return text[start:end + 2] if end > 0 else text[start:]


def main() -> int:
    ui = open(UI, encoding="utf-8").read()
    catalog = open(CATALOG, encoding="utf-8").read()

    up_body = function_body(ui, "mcpUiBridgeUp")
    note_body = function_body(ui, "mcpUiBridgeNote")
    start_body = function_body(ui, "mcpUiBridgeStart")

    print("1. recovery helpers")
    check("mcpUiBridgeUp is defined", bool(up_body))
    check("mcpUiBridgeNote is defined", bool(note_body))
    check("mcpUiBridgeStart is defined", bool(start_body))
    check("start helper calls mcpNetStart", "mcpNetStart()" in start_body)
    check("start helper reports a bind failure", "catch" in start_body)
    check("start helper checks the pump came up", '"timer"' in start_body,
          "a listener without the 25 ms timer cannot serve a single call")
    check("start helper does not return early on false",
          "res[1] = timerOk" in start_body)

    print("2. the panel never closes the door")
    check("mcp_ui.ms does not call mcpNetStop", "mcpNetStop" not in ui)
    check("panel has no stop button", "btnBridgeStop" not in ui)
    check("only one bridge button", ui.count("button btnBridge ") == 1)

    print("3. the button is reachable and honest")
    check("btnBridge control declared", 'button btnBridge' in ui)
    handler = ui[ui.find("on btnBridge pressed do"):]
    check("pressed handler exists", "on btnBridge pressed do" in ui)
    check("pressed handler calls the start helper", "mcpUiBridgeStart()" in handler[:600])
    check("label is synced when the panel opens",
          "syncBridge()" in ui[ui.find("on mcpUiRollout open do"):][:400])
    check("label reflects live state", 'btnBridge.text = "Restart bridge"' in ui
          and 'btnBridge.text = "Start bridge"' in ui)

    print("4. bridge globals are declared")
    decl = re.search(r"^global\s+mcpRunning.*$", ui, re.M)
    check("global declaration for bridge state exists", bool(decl))
    for name in ("mcpRunning", "mcpListener", "mcpTimer", "mcpHost", "mcpPort", "mcpConns"):
        check("{0} declared".format(name), bool(decl) and name in decl.group(0),
              "an undeclared global reads as undefined, so the panel would always say DOWN")

    print("5. no bare then/else in the new helpers")
    for fn_name, body in (
        ("mcpUiBridgeUp", up_body),
        ("mcpUiBridgeNote", note_body),
        ("mcpUiBridgeStart", start_body),
    ):
        bare = re.search(r"\bthen\s+[^(\n][^\n]*\n\s*else\b", body)
        check("{0} uses parenthesised branches".format(fn_name), bare is None,
              "found {0!r}".format(bare.group(0) if bare else ""))

    print("6. catalog tells the truth about recovery")
    check("bridge_restart exists as a tool", '"bridge_restart", "system"' in catalog)
    restart = catalog[catalog.find('"bridge_restart", "system"'):]
    restart = restart[:restart.find("mutating=False")]
    check("bridge_restart mentions the in-Max recovery path", "mcpNetStart()" in restart)
    check("bridge_restart does not promise recovery after stop",
          "当 AI 客户端断连后无法恢复时使用" not in restart)

    print("7. bridge_stop is not reachable from an AI client")
    # Phase B F14: the panel kept its Start button, but the MCP tool surface
    # still offered bridge_stop -- so one tool call could still close the last
    # door with nobody in Max to reopen it. The tool is gone; the command stays.
    check("bridge_stop is not a catalog tool", '"bridge_stop", "system"' not in catalog,
          "an AI client must not be able to stop the only channel it has")
    check("the removal is documented in the catalog", "bridge_stop" in catalog)
    system_ms = open(os.path.join(REPO, "src", "ms", "mcp_system.ms"), encoding="utf-8").read()
    check("the MAXScript command still exists for the panel / Listener",
          'mcpRegister "bridge_stop"' in system_ms)
    stop_body = function_body(system_ms, "mcpH_bridge_stop")
    check("stopping prints the recovery line where a human can see it",
          "mcpBridgeStart()" in stop_body,
          "the JSON reply cannot be delivered once the pump is gone")
    check("stopping reports how to recover", '"recovery"' in stop_body)

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("bridge recovery: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
