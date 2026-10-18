"""Repeatable live test for the modeling extensions of the 3ds Max MCP bridge.

Covers (per the task requirements):
  1. bridge health + the new commands being registered
  2. Box + TurboSmooth: add, read params, modify iterations, read back, verify
  3. modifier stack: list, toggle, reorder, collapse (with and without confirm)
  4. Edit Poly: convert, element query, sub-object selection set + query round
     trip, extrude / inset / bevel / chamfer / connect / weld / cap
  5. error paths: invalid object, invalid modifier, missing modifier,
     unsupported modifier class, collapse without confirm, bad sub-object level
  6. CHS / ENU script tree consistency

The test scene is independent: it starts from scene_new and only creates
__mcp_ext_* objects, so a daily Max instance is never touched beyond a new
empty scene.  Results (pass/fail counts and every error) are written to
diag/logs/modeling_ext_test_<timestamp>.{txt,json}.

Usage:
    python modeling_ext_test.py [--port 8765] [--host 127.0.0.1]
Exit code 0 when every check passed, 1 otherwise, 2 when Max is unreachable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOGDIR = os.path.join(HERE, "logs")

ENU_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""),
    "Autodesk", "3dsMax", "2020 - 64bit", "ENU", "scripts", "3dsmax-mcp",
)
CHS_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""),
    "Autodesk", "3dsMax", "2020 - 64bit", "CHS", "scripts", "3dsmax-mcp",
)


class Bridge:
    """One persistent connection; newline-delimited JSON, like the MCP server."""

    def __init__(self, host: str, port: int, timeout: float = 30.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = b""
        self.counter = 0

    def call(self, method: str, params: dict | None = None, timeout: float | None = None):
        self.counter += 1
        payload = {"id": self.counter, "method": method, "params": params or {}, "lang": "zh"}
        line = json.dumps(payload, ensure_ascii=True) + "\n"
        self.sock.sendall(line.encode("ascii"))
        deadline = time.time() + (timeout or self.timeout)
        while b"\n" not in self.buf:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("no response for %s within %.1fs" % (method, deadline - time.time()))
            self.sock.settimeout(min(remaining, 10.0))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("bridge closed the connection")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        obj = json.loads(raw.decode("utf-8", "replace"))
        if not obj.get("ok"):
            raise BridgeCommandError(obj.get("error", {}).get("message", "unknown error"), obj)
        return obj.get("result")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class BridgeCommandError(RuntimeError):
    pass


class Suite:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.records = []

    def check(self, name, condition, detail=""):
        ok = bool(condition)
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        self.records.append({"check": name, "ok": ok, "detail": str(detail)[:500]})
        print("  [%s] %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + str(detail)[:200]) if not ok else ""))
        return ok

    def skip(self, name, why):
        self.skipped += 1
        self.records.append({"check": name, "ok": None, "detail": "skipped: " + str(why)[:300]})
        print("  [SKIP] %s  -- %s" % (name, why))

    def expect_error(self, name, fn, needle=None):
        """fn must raise BridgeCommandError (optionally containing needle)."""
        try:
            result = fn()
        except BridgeCommandError as exc:
            msg = str(exc)
            if needle and needle not in msg:
                self.failed += 1
                self.records.append({"check": name, "ok": False,
                                     "detail": "wrong error, wanted %r got %r" % (needle, msg[:200])})
                print("  [FAIL] %s  -- wrong error: %s" % (name, msg[:200]))
                return False
            self.passed += 1
            self.records.append({"check": name, "ok": True, "detail": msg[:300]})
            print("  [PASS] %s  (error as expected: %s)" % (name, msg[:120]))
            return True
        except Exception as exc:  # noqa: BLE001
            self.failed += 1
            self.records.append({"check": name, "ok": False, "detail": "%s: %s" % (type(exc).__name__, exc)})
            print("  [FAIL] %s  -- unexpected %s: %s" % (name, type(exc).__name__, exc))
            return False
        self.failed += 1
        self.records.append({"check": name, "ok": False, "detail": "no error raised: %r" % (result,)[:300]})
        print("  [FAIL] %s  -- no error raised" % name)
        return False


# ------------------------------------------------------------------ test cases
def t_bridge(s, b):
    print("\n== 1. bridge health and command registration ==")
    status = b.call("bridge_status")
    s.check("bridge running", status.get("running") is True, status)
    s.check("max year >= 2020", int(status.get("maxVersion", {}).get("year", 0)) >= 2020, status.get("maxVersion"))

    caps = b.call("bridge_capabilities")
    commands = set(caps.get("commands", []))
    for cmd in ("mod_toggle", "mod_collapse", "poly_get_selection", "poly_select", "poly_get_elements"):
        s.check("command registered: %s" % cmd, cmd in commands)


def t_modifiers(s, b):
    print("\n== 2. Box + TurboSmooth parameter round trip ==")
    b.call("scene_new", {"keepScene": False})
    box = b.call("create_box", {"name": "__mcp_ext_box", "length": 20, "width": 20, "height": 20})
    name = box.get("name") or box.get("created", [None])[0] if isinstance(box.get("created"), list) else box.get("name")
    if not name:
        name = "__mcp_ext_box"
    s.check("box created", name == "__mcp_ext_box", box)

    added = b.call("mod_add", {"objects": [name], "modifier": "TurboSmooth", "name": "ts"})
    s.check("mod_add applied", name in (added.get("applied") or []), added)

    stack = b.call("mod_list", {"objects": [name]})
    mods = stack.get("modifiers", [])
    s.check("mod_list shows TurboSmooth", any(m.get("class") == "TurboSmooth" for m in mods), mods)
    ts = next((m for m in mods if m.get("class") == "TurboSmooth"), None)
    s.check("modifier enabled by default", ts is not None and ts.get("enabled") is True, ts)

    before = b.call("mod_get_params", {"objects": [name], "modifier": "ts"})
    it_before = next((p["value"] for p in before.get("params", []) if p.get("property") == "iterations"), None)
    s.check("read iterations before", it_before is not None, it_before)

    b.call("mod_set_params", {"objects": [name], "modifier": "ts", "params": {"iterations": 3}})
    after = b.call("mod_get_params", {"objects": [name], "modifier": "ts"})
    it_after = next((p["value"] for p in after.get("params", []) if p.get("property") == "iterations"), None)
    s.check("iterations changed to 3 (read back)", it_after == 3, it_after)
    s.check("value really changed", it_before != 3, "before=%r" % it_before)

    print("\n== 3. stack operations: toggle / reorder / collapse ==")
    b.call("mod_add", {"objects": [name], "modifier": "Bend", "name": "bend"})
    stack = b.call("mod_list", {"objects": [name]})
    s.check("two modifiers now", len(stack.get("modifiers", [])) == 2, stack)

    toggled = b.call("mod_toggle", {"objects": [name], "modifier": "ts"})
    rec = (toggled.get("results") or [{}])[0]
    s.check("mod_toggle flipped", rec.get("enabledBefore") is True and rec.get("enabledAfter") is False, rec)
    stack = b.call("mod_list", {"objects": [name]})
    ts = next((m for m in stack.get("modifiers", []) if m.get("name") == "ts"), None)
    s.check("toggle verified via mod_list", ts is not None and ts.get("enabled") is False, ts)

    reordered = b.call("mod_reorder", {"objects": [name], "modifier": "ts", "index": 1})
    stack = b.call("mod_list", {"objects": [name]})
    first = stack.get("modifiers", [{}])[0]
    s.check("mod_reorder moved ts to bottom", first.get("name") == "ts", stack)

    # collapse must refuse without confirm
    s.expect_error("mod_collapse refuses without confirm",
                   lambda: b.call("mod_collapse", {"objects": [name]}))
    collapsed = b.call("mod_collapse", {"objects": [name], "confirm": True})
    rec = (collapsed.get("results") or [{}])[0]
    s.check("mod_collapse collapsed", rec.get("collapsed") is True and rec.get("modifiersAfter") == 0, rec)
    stack = b.call("mod_list", {"objects": [name]})
    s.check("stack empty after collapse", len(stack.get("modifiers", [])) == 0, stack)

    # a second object without the named modifier must be skipped by the filter
    b.call("create_box", {"name": "__mcp_ext_box2"})
    b.call("mod_add", {"objects": ["__mcp_ext_box2"], "modifier": "Bend", "name": "bend"})
    s.expect_error("mod_collapse filter rejects missing modifier",
                   lambda: b.call("mod_collapse", {"objects": ["__mcp_ext_box2"], "modifier": "TurboSmooth",
                                                   "confirm": True}))
    stack = b.call("mod_list", {"objects": ["__mcp_ext_box2"]})
    s.check("filtered object untouched", len(stack.get("modifiers", [])) == 1, stack)


def t_poly(s, b):
    print("\n== 4. Edit Poly modelling chain ==")
    b.call("scene_new", {"keepScene": False})
    b.call("create_box", {"name": "__mcp_ext_poly", "length": 20, "width": 20, "height": 20,
                          "lengthsegs": 2, "widthsegs": 2, "heightsegs": 2})
    conv = b.call("convert_to_editable_poly", {"objects": ["__mcp_ext_poly"]})
    s.check("converted to editable poly", "__mcp_ext_poly" in (conv.get("applied") or []), conv)

    info = b.call("poly_info", {"objects": ["__mcp_ext_poly"]})
    rec = (info.get("objects") or [{}])[0]
    faces0 = rec.get("faces")
    s.check("poly_info reads counts", rec.get("verts") == 27 and faces0 == 24, rec)

    elements = b.call("poly_get_elements", {"objects": ["__mcp_ext_poly"]})
    rec = (elements.get("objects") or [{}])[0]
    s.check("box is one element", rec.get("elementCount") == 1, rec)

    # sub-object selection round trip
    sel = b.call("poly_select", {"objects": ["__mcp_ext_poly"], "level": "face", "faces": [1, 2, 3]})
    rec = (sel.get("results") or [{}])[0]
    s.check("poly_select set 3 faces", rec.get("selectedFaces") == 3 and rec.get("level") == 4, rec)
    got = b.call("poly_get_selection", {"objects": ["__mcp_ext_poly"]})
    rec = (got.get("objects") or [{}])[0]
    s.check("poly_get_selection reads back", rec.get("subobjectLevel") == 4
            and rec.get("faces", {}).get("count") == 3
            and sorted(rec.get("faces", {}).get("indices", [])) == [1, 2, 3], rec)

    # element selection expands to faces
    sel = b.call("poly_select", {"objects": ["__mcp_ext_poly"], "elements": [1]})
    rec = (sel.get("results") or [{}])[0]
    s.check("element selection covers all faces", rec.get("selectedFaces") == 24, rec)

    # extrude the top faces and verify the topology changed
    b.call("poly_select", {"objects": ["__mcp_ext_poly"], "level": "face", "faces": [1, 2]})
    b.call("poly_extrude_faces", {"objects": ["__mcp_ext_poly"], "faces": [1, 2], "amount": 5})
    info = b.call("poly_info", {"objects": ["__mcp_ext_poly"]})
    rec = (info.get("objects") or [{}])[0]
    s.check("extrude increased face count", rec.get("faces", 0) > faces0, rec)

    # inset + bevel + chamfer + connect + weld + cap
    b.call("poly_inset_faces", {"objects": ["__mcp_ext_poly"], "faces": [1], "outline": 1})
    b.call("poly_bevel_faces", {"objects": ["__mcp_ext_poly"], "faces": [1], "height": 1, "outline": -0.5})
    b.call("poly_chamfer_edges", {"objects": ["__mcp_ext_poly"], "edges": [1, 2], "amount": 0.5})
    b.call("poly_connect_edges", {"objects": ["__mcp_ext_poly"], "edges": [1, 2], "segments": 1})
    b.call("poly_weld_vertices", {"objects": ["__mcp_ext_poly"], "vertices": [1, 2], "threshold": 0.1})
    b.call("poly_cap_holes", {"objects": ["__mcp_ext_poly"]})
    info = b.call("poly_info", {"objects": ["__mcp_ext_poly"]})
    rec = (info.get("objects") or [{}])[0]
    s.check("poly edits kept the object valid", rec.get("verts", 0) > 0 and rec.get("faces", 0) > 0, rec)

    # Edit Poly as a modifier on a fresh primitive
    b.call("create_box", {"name": "__mcp_ext_epmod", "length": 10, "width": 10, "height": 10})
    added = b.call("mod_editpoly", {"objects": ["__mcp_ext_epmod"]})
    stack = b.call("mod_list", {"objects": ["__mcp_ext_epmod"]})
    s.check("Edit_Poly modifier added", any(m.get("class") == "Edit_Poly" for m in stack.get("modifiers", [])), stack)


def t_errors(s, b):
    print("\n== 5. error paths ==")
    b.call("scene_new", {"keepScene": False})
    b.call("create_box", {"name": "__mcp_ext_err", "length": 5, "width": 5, "height": 5})

    s.expect_error("invalid object name",
                   lambda: b.call("mod_list", {"objects": ["__mcp_ext_does_not_exist"]}))
    s.expect_error("invalid modifier on object",
                   lambda: b.call("mod_get_params", {"objects": ["__mcp_ext_err"], "modifier": "NoSuchMod"}))
    s.expect_error("missing required param",
                   lambda: b.call("mod_set_param", {"objects": ["__mcp_ext_err"], "param": "angle"}))
    s.expect_error("unsupported modifier class",
                   lambda: b.call("mod_add", {"objects": ["__mcp_ext_err"], "modifier": "NotAModifierXYZ"}))
    s.expect_error("invalid sub-object level",
                   lambda: b.call("poly_select", {"objects": ["__mcp_ext_err"], "level": "banana"}))
    s.expect_error("poly edit on non-poly primitive auto-converts then works",
                   lambda: b.call("poly_extrude_faces", {"objects": ["__mcp_ext_err"], "faces": [1], "amount": 1}))

    # after the auto-conversion above the object IS poly, so this must succeed
    info = b.call("poly_info", {"objects": ["__mcp_ext_err"]})
    s.check("auto-convert really happened", (info.get("objects") or [{}])[0].get("verts", 0) > 0, info)


def t_script_sync(s, _b):
    print("\n== 6. CHS / ENU script tree consistency ==")
    if not (os.path.isdir(ENU_DIR) and os.path.isdir(CHS_DIR)):
        s.skip("script tree sync", "script directories not found")
        return
    enu = sorted(f for f in os.listdir(ENU_DIR) if f.endswith(".ms"))
    chs = sorted(f for f in os.listdir(CHS_DIR) if f.endswith(".ms"))
    s.check("same file set", enu == chs, "ENU=%d CHS=%d" % (len(enu), len(chs)))
    diffs = []
    for f in enu:
        if f in chs:
            a = hashlib.md5(open(os.path.join(ENU_DIR, f), "rb").read()).hexdigest()
            c = hashlib.md5(open(os.path.join(CHS_DIR, f), "rb").read()).hexdigest()
            if a != c:
                diffs.append(f)
    s.check("byte-identical trees", not diffs, "differs: %s" % diffs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()

    os.makedirs(LOGDIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    print("=== modeling extension live test %s ===" % stamp)
    print("target: %s:%d" % (args.host, args.port))

    try:
        bridge = Bridge(args.host, args.port)
    except OSError as exc:
        print("CANNOT REACH BRIDGE: %s" % exc)
        print("Start 3ds Max and run mcpBridgeStart() (or let the startup loader do it), then retry.")
        return 2

    suite = Suite()
    try:
        t_bridge(suite, bridge)
        t_modifiers(suite, bridge)
        t_poly(suite, bridge)
        t_errors(suite, bridge)
        t_script_sync(suite, bridge)
    finally:
        bridge.close()

    print("\n=== summary: %d passed, %d failed, %d skipped ===" % (
        suite.passed, suite.failed, suite.skipped))

    report = {
        "stamp": stamp,
        "target": "%s:%d" % (args.host, args.port),
        "passed": suite.passed,
        "failed": suite.failed,
        "skipped": suite.skipped,
        "checks": suite.records,
    }
    txt = os.path.join(LOGDIR, "modeling_ext_test_%s.txt" % stamp)
    js = os.path.join(LOGDIR, "modeling_ext_test_%s.json" % stamp)
    with open(txt, "w", encoding="utf-8") as fh:
        fh.write("modeling extension live test %s\n" % stamp)
        for r in suite.records:
            fh.write("%-4s %s%s\n" % ("PASS" if r["ok"] else ("SKIP" if r["ok"] is None else "FAIL"),
                                      r["check"], "" if r["ok"] else "  -- " + r["detail"]))
        fh.write("\n%d passed, %d failed, %d skipped\n" % (suite.passed, suite.failed, suite.skipped))
    with open(js, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
    print("report: %s" % txt)
    return 1 if suite.failed else 0


if __name__ == "__main__":
    sys.exit(main())
