#!/usr/bin/env python3
"""Live proof that modifier parameter types survive Catalog -> Python -> Max.

Needs a running 3ds Max with the bridge up.  Unlike the other live tests this
one does **not** talk to the bridge socket directly: it goes through
``MaxMcpServer.on_tools_call``, i.e. the same path a client takes

    tool call -> catalog schema -> _coerce -> bridge -> MAXScript handler

which is exactly the layer the two defects lived in.  The earlier live matrix
bypassed it (`live_matrix.py` builds the payload itself), which is why
``mod_set_param(value=2)`` was green there and failed for every real client.

Scenarios:
  1. mod_add with a `params` object   -> modifier added AND parameters really set
  2. integer value                    -> read back as an integer
  3. string that means a number       -> converted, read back as a number
  4. float value                      -> read back as a float
  5. string-valued property           -> read back as that string (skipped with
                                         a note when the modifier has none)
  6. invalid value                    -> error, property unchanged
  7. non-integral value for an int    -> error, not truncated
  8. unsupported property             -> error naming it, nothing written
  9. batch all-valid / batch partial  -> appliedParams / rejected are truthful

Every write is confirmed by reading the property back out of 3ds Max with
``mod_get_params`` (a separate call, not the handler's own word).

Usage:
    python test/live/modifier_param_types_test.py --port 8765          # plan
    python test/live/modifier_param_types_test.py --port 8765 --yes    # run
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

PROBE = "T15_MOD_PROBE_{0}".format(os.getpid())
INT_MOD = "TurboSmooth"     # iterations is an integer property
FLOAT_MOD = "Bend"          # angle is a float property

FAILURES: List[str] = []


class Mcp:
    """The real server object, driven the way a client drives it."""

    def __init__(self, port: int, language: str = "en") -> None:
        from maxmcp.config import Config
        from maxmcp.protocol import NullTransport
        from maxmcp.server import MaxMcpServer

        self.server = MaxMcpServer(
            Config(port=port, tool_profile="full", language=language, runtime_verify=False),
            NullTransport(),
        )

    def call(self, tool: str, arguments: Optional[Dict[str, Any]] = None) -> Tuple[bool, Any, bool]:
        """Run one tool. Returns (ok, payload_or_error, is_error_flag)."""
        result = self.server.on_tools_call({"name": tool, "arguments": arguments or {}})
        is_error = bool(result.get("isError"))
        blocks = result.get("content") or []
        text = blocks[0].get("text", "") if blocks else ""
        try:
            payload = json.loads(text)
        except ValueError:
            payload = text
        if is_error:
            return False, payload, True
        return True, payload, False


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def err_message(payload: Any) -> str:
    if isinstance(payload, dict):
        return str((payload.get("error") or {}).get("message", ""))
    return str(payload)


def readback(mcp: Mcp, modifier: str) -> Dict[str, Any]:
    """Read the modifier's real property values out of Max."""
    ok, data, _ = mcp.call("mod_get_params", {"objects": [PROBE], "modifier": modifier})
    out: Dict[str, Any] = {}
    if ok and isinstance(data, dict):
        for row in data.get("params") or []:
            if isinstance(row, dict):
                out[str(row.get("property"))] = row.get("value")
    return out


def reload_modules(mcp: Mcp) -> str:
    src = REPO.replace("\\", "/") + "/src/ms/"
    code = (
        '( local repo = "{0}"; local r1 = "ok"; local r2 = "ok"; local r3 = "ok"; '
        'try ( fileIn (repo + "mcp_core.ms") ) catch ( r1 = "ERR:" + (getCurrentException() as string) ); '
        'try ( fileIn (repo + "mcp_modifiers.ms") ) catch ( r2 = "ERR:" + (getCurrentException() as string) ); '
        'try ( fileIn (repo + "mcp_context.ms") ) catch ( r3 = "ERR:" + (getCurrentException() as string) ); '
        'mcpSetLanguage "en"; r1 + "|" + r2 + "|" + r3 )'
    ).format(src)
    ok, data, _ = mcp.call("execute_maxscript", {"code": code})
    return str((data or {}).get("result", "")) if isinstance(data, dict) else str(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--yes", action="store_true", help="actually mutate the live scene")
    args = ap.parse_args()

    if not args.yes:
        print("DRY RUN - would reload 3 modules and mutate a temporary box '{0}'.".format(PROBE))
        print("Pass --yes to execute against the running 3ds Max on port {0}.".format(args.port))
        return 0

    mcp = Mcp(args.port)

    ok, status, _ = mcp.call("bridge_status")
    if not ok:
        print("harness error: bridge not reachable on port {0}: {1}".format(args.port, status))
        return 2
    print("bridge: {0}".format(json.dumps(status, ensure_ascii=False)[:160]))

    try:
        print("0. reload the modules under test from the working tree")
        loaded = reload_modules(mcp)
        check("modules reloaded", loaded == "ok|ok|ok", loaded)

        created_ok, created, _ = mcp.call("create_box", {"name": PROBE, "length": 10,
                                                         "width": 10, "height": 10})
        check("probe box created", created_ok, json.dumps(created, ensure_ascii=False)[:160])

        print("1. mod_add with a params object really applies them")
        ok, added, _ = mcp.call("mod_add", {"objects": [PROBE], "modifier": FLOAT_MOD,
                                            "params": {"angle": 45.5}})
        check("mod_add ok", ok, json.dumps(added, ensure_ascii=False)[:200])
        check("mod_add reports no rejected parameters",
              isinstance(added, dict) and not added.get("rejected"),
              json.dumps(added, ensure_ascii=False)[:200] if isinstance(added, dict) else "")
        rb = readback(mcp, FLOAT_MOD)
        check("Bend was really created", "angle" in rb, str(sorted(rb))[:200])
        check("angle really is 45.5 in Max", _num(rb.get("angle")) == 45.5, repr(rb.get("angle")))
        if isinstance(added, dict):
            check("mod_add publishes the read-back value",
                  _num((added.get("readback") or {}).get(PROBE + ".angle")) == 45.5,
                  json.dumps(added.get("readback"), ensure_ascii=False)[:200])

        print("2/3/4. integer, numeric string and float")
        ok, _ = mcp.call("mod_add", {"objects": [PROBE], "modifier": INT_MOD})
        check("TurboSmooth added", ok)
        mcp.call("mod_set_param", {"objects": [PROBE], "modifier": INT_MOD,
                                   "param": "iterations", "value": 3})
        rb = readback(mcp, INT_MOD)
        check("integer 3 applied and read back", _num(rb.get("iterations")) == 3,
              repr(rb.get("iterations")))
        ok, r, _ = mcp.call("mod_set_param", {"objects": [PROBE], "modifier": INT_MOD,
                                              "param": "iterations", "value": 3})
        check("reply carries the read-back value", isinstance(r, dict)
              and _num((r.get("readback") or {}).get(PROBE + ".iterations")) == 3,
              json.dumps(r.get("readback") if isinstance(r, dict) else r, ensure_ascii=False)[:200])
        mcp.call("mod_set_param", {"objects": [PROBE], "modifier": INT_MOD,
                                   "param": "iterations", "value": "4"})
        rb = readback(mcp, INT_MOD)
        check("string \"4\" converted to the integer 4", _num(rb.get("iterations")) == 4,
              repr(rb.get("iterations")))
        mcp.call("mod_set_param", {"objects": [PROBE], "modifier": FLOAT_MOD,
                                   "param": "angle", "value": -12.75})
        rb = readback(mcp, FLOAT_MOD)
        check("float -12.75 applied and read back", _num(rb.get("angle")) == -12.75,
              repr(rb.get("angle")))

        print("5. a string-valued property")
        string_prop = _find_string_property(readback(mcp, FLOAT_MOD))
        if string_prop:
            target = "T15_STRING_VALUE"
            ok, r, _ = mcp.call("mod_set_param", {"objects": [PROBE], "modifier": FLOAT_MOD,
                                                  "param": string_prop, "value": target})
            rb = readback(mcp, FLOAT_MOD)
            check("string property {0} set and read back".format(string_prop),
                  str(rb.get(string_prop)) == target, repr(rb.get(string_prop)))
        else:
            print("  note  Bend and TurboSmooth expose no string-valued property; the string "
                  "path is covered by step 2/3 (a string argument converted to a number)")

        print("6/7. invalid values are refused and change nothing")
        before = readback(mcp, FLOAT_MOD).get("angle")
        ok, r, _ = mcp.call("mod_set_param", {"objects": [PROBE], "modifier": FLOAT_MOD,
                                              "param": "angle", "value": "__not_a_number__"})
        check("non-numeric string refused", not ok, json.dumps(r, ensure_ascii=False)[:200])
        check("error names the property", "angle" in err_message(r), err_message(r)[:200])
        after = readback(mcp, FLOAT_MOD).get("angle")
        check("angle unchanged after the refusal", _num(after) == _num(before),
              "{0} -> {1}".format(before, after))

        before = readback(mcp, INT_MOD).get("iterations")
        ok, r, _ = mcp.call("mod_set_param", {"objects": [PROBE], "modifier": INT_MOD,
                                              "param": "iterations", "value": 2.5})
        check("2.5 refused for an integer property", not ok, json.dumps(r, ensure_ascii=False)[:200])
        after = readback(mcp, INT_MOD).get("iterations")
        check("iterations not truncated to 2", _num(after) == _num(before),
              "{0} -> {1}".format(before, after))

        print("8. an unsupported property is named, not ignored")
        ok, r, _ = mcp.call("mod_set_param", {"objects": [PROBE], "modifier": INT_MOD,
                                              "param": "totally_fake_property", "value": 1})
        check("unsupported property refused", not ok, json.dumps(r, ensure_ascii=False)[:200])
        check("error says it is unsupported", "unsupported" in err_message(r).lower(),
              err_message(r)[:200])

        print("9. batch results are truthful")
        ok, r, _ = mcp.call("mod_set_params", {"objects": [PROBE], "modifier": INT_MOD,
                                               "params": {"iterations": 2, "isolineDisplay": True}})
        check("batch all-valid ok", ok, json.dumps(r, ensure_ascii=False)[:200])
        check("batch all-valid: partial false",
              isinstance(r, dict) and r.get("partial") is False, json.dumps(r, ensure_ascii=False)[:200])
        rb = readback(mcp, INT_MOD)
        check("batch iterations == 2 in Max", _num(rb.get("iterations")) == 2,
              repr(rb.get("iterations")))
        check("batch isolineDisplay == true in Max",
              _bool(rb.get("isolineDisplay")) is True, repr(rb.get("isolineDisplay")))

        ok, r, _ = mcp.call("mod_set_params", {"objects": [PROBE], "modifier": INT_MOD,
                                               "params": {"iterations": 4, "fake_prop_zzz": 9}})
        check("batch partial still ok (something applied)", ok, json.dumps(r, ensure_ascii=False)[:200])
        check("batch partial: partial true, success false",
              isinstance(r, dict) and r.get("partial") is True and r.get("success") is False,
              json.dumps(r, ensure_ascii=False)[:200])
        check("batch partial: rejected names the fake key",
              any("fake_prop_zzz" in str(x) for x in (r.get("rejected") or [])),
              str(r.get("rejected"))[:200])
        rb = readback(mcp, INT_MOD)
        check("batch partial: iterations really 4 in Max", _num(rb.get("iterations")) == 4,
              repr(rb.get("iterations")))

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
    print("modifier parameter types (live, through the MCP server): all checks passed")
    return 0


def _find_string_property(values: Dict[str, Any]) -> str:
    for name, value in values.items():
        if isinstance(value, str):
            return name
    return ""


def _num(value: Any) -> Optional[float]:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return round(float(value), 6)
    except (TypeError, ValueError):
        return None


def _bool(value: Any) -> Optional[bool]:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() == "true"
    if isinstance(value, (int, float)):
        return bool(value)
    return None


if __name__ == "__main__":
    sys.exit(main())
