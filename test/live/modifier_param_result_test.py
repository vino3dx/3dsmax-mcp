#!/usr/bin/env python3
"""Live proof that modifier parameter writes report the truth (needs 3ds Max).

The static test proves the source shape; this proves the behaviour inside the
real bridge, because the fake-success defect lived in MAXScript and can only be
confirmed by driving a real modifier and reading its value back.

The bridge must already be running the code under test.  This script reloads
mcp_core.ms and mcp_modifiers.ms from the repository working tree (fileIn) so a
source edit is exercised without touching the installed user-scripts copy.  It
then uses a single uniquely named temporary box with one TurboSmooth modifier
and removes it in a finally block.  No user object is created or deleted.

Scenarios (all on that one modifier):
  1. valid single param applied      -> ok, applied, read-back matches
  2. unsupported single param        -> transport error (isError), not ok
  3. invalid single value            -> transport error, not ok
  4. batch all-valid                 -> ok, partial:false, read-back matches
  5. batch partial (valid + unknown) -> ok but partial:true, rejected listed
  6. batch all-invalid               -> transport error, not ok

Usage:
    python test/live/modifier_param_result_test.py --port 8765            # plan
    python test/live/modifier_param_result_test.py --port 8765 --yes      # run
Exit codes: 0 all pass, 1 a case failed, 2 harness error, 3 refused.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from typing import Any, Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROBE = "T12_MOD_PROBE_{0}".format(os.getpid())
MOD = "TurboSmooth"


class Conn:
    def __init__(self, host: str, port: int, timeout: float = 30.0) -> None:
        self.s = socket.socket()
        self.s.settimeout(timeout)
        self.s.connect((host, port))
        self.buf = b""
        self.seq = 0

    def call(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        self.seq += 1
        req_id = self.seq
        self.s.sendall((json.dumps({"id": req_id, "method": method, "params": params}) + "\n").encode("ascii"))
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise RuntimeError("bridge closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        reply = json.loads(line.decode("utf-8", "replace"))
        if reply.get("id") != req_id:
            raise RuntimeError("out-of-order reply: {0}".format(reply.get("id")))
        return reply

    def close(self) -> None:
        try:
            self.s.close()
        except Exception:  # noqa: BLE001
            pass


def result_of(reply: Dict[str, Any]) -> Dict[str, Any]:
    """Return the handler result dict from an ok reply."""
    if not reply.get("ok"):
        return {}
    res = reply.get("result")
    return res if isinstance(res, dict) else {}


def readback(conn: Conn) -> Dict[str, Any]:
    """Read modifier params back; return {name: value} for the probe modifier."""
    reply = conn.call("mod_get_params", {"objects": [PROBE], "modifier": MOD})
    data = result_of(reply)
    out: Dict[str, Any] = {}
    for row in data.get("params", []) or []:
        if isinstance(row, dict):
            out[str(row.get("property"))] = row.get("value")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--yes", action="store_true", help="actually mutate the live scene")
    args = ap.parse_args()

    if not args.yes:
        print("DRY RUN - would reload two modules and mutate a temporary box '{0}'.".format(PROBE))
        print("Pass --yes to execute against the running 3ds Max on {0}:{1}.".format(args.host, args.port))
        return 0

    failures: List[str] = []
    conn = Conn(args.host, args.port)

    def check(name: str, cond: bool, detail: str = "") -> None:
        if cond:
            print("  ok   {0}".format(name))
        else:
            print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
            failures.append(name)

    try:
        # --- reload modules from the working tree so the edit is exercised ---
        src = REPO.replace("\\", "/") + "/src/ms/"
        code = (
            '( local repo = "{0}"; local r1 = "ok"; local r2 = "ok"; '
            'try ( fileIn (repo + "mcp_core.ms") ) catch ( r1 = "ERR:" + (getCurrentException() as string) ); '
            'try ( fileIn (repo + "mcp_modifiers.ms") ) catch ( r2 = "ERR:" + (getCurrentException() as string) ); '
            'mcpSetLanguage "en"; r1 + "|" + r2 )'
        ).format(src)
        rr = result_of(conn.call("execute_maxscript", {"code": code}))
        check("modules reloaded", rr.get("result") == "ok|ok", str(rr.get("result")))

        # --- create the probe box (scene write, cleaned in finally) ---
        # `class` is injected by the MCP server from the tool preset; this
        # script talks to the bridge directly, so supply it explicitly.
        created = conn.call("create_box", {"class": "Box", "name": PROBE,
                                            "length": 10, "width": 10, "height": 10})
        check("probe box created", bool(created.get("ok")), json.dumps(created)[:200])
        added = conn.call("mod_add", {"objects": [PROBE], "modifier": MOD})
        check("TurboSmooth added", bool(added.get("ok")), json.dumps(added)[:200])

        # Values cross the bridge as native JSON types: integers stay integers,
        # booleans stay booleans (see mcpParseNumber / mcpParseLiteral).
        # --- scenario 1: valid single param ---
        r = conn.call("mod_set_param", {"objects": [PROBE], "modifier": MOD, "param": "iterations", "value": 3})
        d = result_of(r)
        check("1 valid single: transport ok", bool(r.get("ok")), json.dumps(r)[:200])
        check("1 valid single: applied", PROBE in (d.get("applied") or []), str(d.get("applied")))
        check("1 valid single: success true, partial false",
              d.get("success") is True and d.get("partial") is False, json.dumps(d)[:200])
        rb = readback(conn)
        check("1 valid single: read-back iterations==3", str(rb.get("iterations")) == "3", str(rb.get("iterations")))

        # --- scenario 2: unsupported single param ---
        r = conn.call("mod_set_param", {"objects": [PROBE], "modifier": MOD,
                                        "param": "totally_fake_property", "value": "1"})
        d = result_of(r)
        check("2 unsupported single: transport error (not fake ok)", not r.get("ok"), json.dumps(r)[:200])
        err = (r.get("error") or {})
        check("2 unsupported single: error mentions no parameter applied",
              "No modifier parameter applied" in str(err.get("message", "")), str(err.get("message", "")))

        # --- scenario 3: invalid single value (string into integer property) ---
        r = conn.call("mod_set_param", {"objects": [PROBE], "modifier": MOD,
                                        "param": "iterations", "value": "__not_a_number__"})
        d = result_of(r)
        check("3 invalid value: transport error (not fake ok)", not r.get("ok"), json.dumps(r)[:200])

        # --- scenario 4: batch all valid ---
        r = conn.call("mod_set_params", {"objects": [PROBE], "modifier": MOD,
                                         "params": {"iterations": 2, "isolineDisplay": True}})
        d = result_of(r)
        check("4 batch all-valid: transport ok", bool(r.get("ok")), json.dumps(r)[:200])
        check("4 batch all-valid: success true, partial false",
              d.get("success") is True and d.get("partial") is False, json.dumps(d)[:200])
        check("4 batch all-valid: no rejected/failures",
              not d.get("rejected") and not d.get("failures"), json.dumps(d)[:200])
        rb = readback(conn)
        check("4 batch all-valid: read-back iterations==2", str(rb.get("iterations")) == "2", str(rb.get("iterations")))

        # --- scenario 5: batch partial (one valid, one unknown) ---
        r = conn.call("mod_set_params", {"objects": [PROBE], "modifier": MOD,
                                         "params": {"iterations": 4, "fake_prop_zzz": 9}})
        d = result_of(r)
        check("5 batch partial: transport ok (something applied)", bool(r.get("ok")), json.dumps(r)[:200])
        check("5 batch partial: partial true, success false",
              d.get("partial") is True and d.get("success") is False, json.dumps(d)[:200])
        check("5 batch partial: rejected lists the fake param",
              any("fake_prop_zzz" in str(x) for x in (d.get("rejected") or [])), str(d.get("rejected")))
        check("5 batch partial: applied lists iterations",
              any("iterations" in str(x) for x in (d.get("appliedParams") or [])), str(d.get("appliedParams")))
        rb = readback(conn)
        check("5 batch partial: read-back iterations==4 (real change)", str(rb.get("iterations")) == "4", str(rb.get("iterations")))

        # --- scenario 6: batch all invalid ---
        r = conn.call("mod_set_params", {"objects": [PROBE], "modifier": MOD,
                                         "params": {"fake_a": "1", "fake_b": "2"}})
        d = result_of(r)
        check("6 batch all-invalid: transport error (not fake ok)", not r.get("ok"), json.dumps(r)[:200])

    finally:
        # --- cleanup: delete only our uniquely named probe ---
        try:
            conn.call("delete_objects", {"objects": [PROBE]})
            print("  cleanup: removed " + PROBE)
        except Exception as exc:  # noqa: BLE001
            print("  cleanup WARNING: " + str(exc))
        conn.close()

    print()
    if failures:
        print("{0} case(s) failed: {1}".format(len(failures), ", ".join(failures)))
        return 1
    print("modifier parameter result (live): all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
