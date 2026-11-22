#!/usr/bin/env python3
"""Live proof for context write tracking (needs a running 3ds Max).

The static contract test proves the *declaration* is complete and that the
dispatcher is wired to it.  It cannot prove the thing that actually broke:

    a successful write -> the right domains marked dirty -> revision moves ->
    context_get(since:) re-sends exactly those domains, with a newer changedAt

That needs the real ledger inside Max, so this script drives the real bridge and
reads the real answers back.  It is deliberately small and reversible:

    READ   context_get (all sections)              -> baseline revision
    READ   list_render_engines                     -> revision must not move
    WRITE  render_set_resolution (w+1, h+1)        -> render must go dirty
    WRITE  render_set_resolution (w, h)            -> restore, render dirty again
    FAIL   render_set_output without a path        -> revision must not move
    WRITE  create_box + delete_objects             -> scene/objects/selection dirty

Nothing else is touched; the resolution is restored in a `finally` block and the
probe box is deleted on every exit path.  Still, it writes to a live scene, so it
refuses to run without --yes.

The bridge must already be running the code under test: deploy `src/ms/*.ms` to
the Max user-scripts folder and reload the bridge first, otherwise this measures
the old dispatcher.

Usage:
    python test/live/write_tracking_test.py --port 8765            # dry run: prints the plan
    python test/live/write_tracking_test.py --port 8765 --yes      # actually run
Exit codes: 0 all cases pass, 1 a case failed, 2 harness error, 3 refused.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from typing import Any, Dict, List, Optional, Tuple

PROBE_BOX = "mcp_ledger_probe"


class Bridge(object):
    def __init__(self, host: str, port: int, timeout: float = 30.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))
        self.buf = b""
        self.seq = 0

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def _read_line(self, timeout: float = 30.0) -> str:
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("bridge closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace")

    def call(self, method: str, params: Optional[Dict[str, Any]] = None,
             timeout: float = 30.0) -> Tuple[bool, Any]:
        """Returns (ok, result_or_error)."""
        self.seq += 1
        payload = {"id": self.seq, "method": method, "params": params or {}}
        self.sock.sendall((json.dumps(payload) + "\n").encode("ascii"))
        reply = json.loads(self._read_line(timeout))
        if reply.get("ok"):
            return True, reply.get("result")
        return False, reply.get("error")


CASES: List[str] = [
    "read-only command does not move the revision",
    "render_set_resolution marks render dirty and changes the value",
    "context_get(since:) re-sends render with a newer changedAt",
    "failed command does not move the revision",
    "create_box marks scene + objects + selection",
]


def sections_of(reply: Dict[str, Any]) -> Dict[str, Any]:
    return reply.get("sections") or {}


def changed_at(reply: Dict[str, Any], domain: str) -> Optional[int]:
    section = sections_of(reply).get(domain) or {}
    return section.get("changedAt")


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--yes", action="store_true", help="confirm the scene writes")
    parser.add_argument("--json", action="store_true", help="machine report")
    args = parser.parse_args(argv[1:])

    print("plan (reversible, needs a live bridge):")
    for index, name in enumerate(CASES, 1):
        print("  {0}. {1}".format(index, name))
    print("temporary state: render resolution, one Box named {0!r}".format(PROBE_BOX))

    if not args.yes:
        print("\nrefusing to touch a live scene without --yes")
        return 3

    bridge = Bridge(args.host, args.port)
    results: List[Dict[str, Any]] = []
    origin: Dict[str, Any] = {}
    box_created = False

    def record(name: str, passed: bool, detail: str, evidence: Any = None) -> None:
        results.append({"case": name, "passed": bool(passed), "detail": detail, "evidence": evidence})
        print("  [{0}] {1} :: {2}".format("PASS" if passed else "FAIL", name, detail))

    try:
        ok, status = bridge.call("bridge_status")
        if not ok:
            print("bridge_status failed: {0}".format(status))
            return 2

        # -- baseline: a full read primes mcpCtxSent for every domain ---------
        ok, base = bridge.call("context_get", {"detail": "brief"})
        if not ok:
            print("context_get failed: {0}".format(base))
            return 2
        r0 = base.get("revision", 0)
        print("\nbaseline revision: {0}".format(r0))

        # -- 1. a read must not move the revision ----------------------------
        ok, _ = bridge.call("list_render_engines")
        ok2, after_read = bridge.call("context_get", {"sections": ["scene"]})
        r1 = after_read.get("revision") if ok2 else None
        record(CASES[0], ok and ok2 and r1 == r0,
               "revision {0} -> {1}".format(r0, r1))

        # -- 2/3. a real write must mark render dirty ------------------------
        ok, settings = bridge.call("render_get_settings")
        if not ok:
            print("render_get_settings failed: {0}".format(settings))
            return 2
        origin = {"width": int(settings.get("width") or 0), "height": int(settings.get("height") or 0)}
        new_w, new_h = origin["width"] + 1, origin["height"] + 1

        ok, applied = bridge.call("render_set_resolution", {"width": new_w, "height": new_h})
        r2 = None
        if ok:
            _, bumped = bridge.call("context_get", {"sections": ["render"], "since": r0})
            r2 = bumped.get("revision")
            sent = "render" in sections_of(bumped)
            at = changed_at(bumped, "render")
            record(
                CASES[1],
                applied.get("width") == new_w and applied.get("height") == new_h and r2 is not None and r2 > r0,
                "resolution {0}x{1} -> {2}x{3}, revision {4} -> {5}".format(
                    origin["width"], origin["height"],
                    applied.get("width"), applied.get("height"), r0, r2),
                {"settings": applied},
            )
            record(
                CASES[2],
                sent and at is not None and at > r0,
                "render re-sent={0}, changedAt={1} (since={2}), unchanged={3}".format(
                    sent, at, r0, bumped.get("unchanged")),
                {"unchanged": bumped.get("unchanged"), "built": bumped.get("built")},
            )
        else:
            record(CASES[1], False, "render_set_resolution failed: {0}".format(applied))
            record(CASES[2], False, "skipped: the write did not succeed")

        # -- 4. failure must not be recorded as a write ----------------------
        # A write tool that fails before touching anything: render_set_output
        # requires `path`, so the handler throws err.missing_param.  Using
        # delete_objects here would be a bad idea -- it falls back to the
        # current selection when a name does not resolve.
        _, before_fail = bridge.call("context_get", {"sections": ["scene"]})
        r3 = before_fail.get("revision")
        ok_fail, err = bridge.call("render_set_output", {})
        _, after_fail = bridge.call("context_get", {"sections": ["scene"]})
        r4 = after_fail.get("revision")
        record(CASES[3], (not ok_fail) and r3 == r4,
               "ok={0}, revision {1} -> {2}".format(ok_fail, r3, r4),
               {"error": err})

        # -- 5. multi-domain write -------------------------------------------
        _, before_box = bridge.call("context_get", {"sections": ["scene", "objects", "selection"]})
        r5 = before_box.get("revision")
        # `class` is injected by the MCP server from the tool's catalog preset
        # (`preset={"class": "Box"}` in catalog/objects.py).  This script talks to
        # the bridge directly, so it has to supply the preset itself or the
        # handler fails with err.missing_param:class before it creates anything.
        ok_box, created = bridge.call("create_box", {"class": "Box", "name": PROBE_BOX,
                                                     "length": 10, "width": 10, "height": 10})
        if ok_box:
            box_created = True
        _, after_box = bridge.call(
            "context_get", {"sections": ["scene", "objects", "selection"], "since": r5}
        )
        got = sections_of(after_box)
        named = [d for d in ("scene", "objects", "selection") if d in got]
        fresh = [d for d in named if (changed_at(after_box, d) or 0) > (r5 or 0)]
        record(CASES[4], ok_box and len(named) == 3 and len(fresh) == 3,
               "created={0}, re-sent={1}, changedAt>since for {2}".format(
                   ok_box, named, fresh),
               {"created": created if ok_box else None, "unchanged": after_box.get("unchanged")})

    except Exception as exc:  # noqa: BLE001
        record("harness", False, "{0}: {1}".format(type(exc).__name__, exc))
    finally:
        # -- restore -------------------------------------------------------
        try:
            if origin:
                bridge.call("render_set_resolution",
                            {"width": origin["width"], "height": origin["height"]})
            if box_created:
                # Only delete when the name resolves: delete_objects falls back
                # to the current selection when nothing matches, and this script
                # must never eat a user selection.
                _, probe = bridge.call("find_objects", {"name": PROBE_BOX})
                if isinstance(probe, dict) and (probe.get("count") or 0) > 0:
                    bridge.call("delete_objects", {"objects": [PROBE_BOX]})
            _, restored = bridge.call("render_get_settings")
            _, cleanup = bridge.call("find_objects", {"name": PROBE_BOX})
            print("\nrestored: render {0}x{1}; probe object remaining={2}".format(
                restored.get("width") if restored else "?",
                restored.get("height") if restored else "?",
                cleanup.get("count") if isinstance(cleanup, dict) else cleanup))
        except Exception as exc:  # noqa: BLE001
            print("restore failed: {0}: {1}".format(type(exc).__name__, exc))
        bridge.close()

    passed = sum(1 for r in results if r["passed"])
    total = len(CASES)
    if args.json:
        print(json.dumps({"passed": passed, "total": total, "cases": results}, ensure_ascii=False, indent=2))
    else:
        print("\n{0}/{1} cases passed".format(passed, total))
    return 0 if passed == total and total == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
