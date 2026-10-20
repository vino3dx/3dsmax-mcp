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
  7. regression: light_create type=spot / type=directional create the classes
     Targetspot / Targetdirectionallight (the Target_Spot/Target_Directional
     class-name fix)
  8. regression: all 8 spline creators (rectangle/circle/ellipse/ngon/donut/
     arc/helix/text) succeed (the missing preset={"class":...} fix; before it
     every one of them failed with err.missing_param: class)
  9. regression: create_teapot smooth=true reads back smooth=true (the
     mcpNum-swallowed-boolean fix)
 10. regression: create_pyramid depth=50 reads back depth=50 (the depth param
     that the docs promised but the schema did not accept)
 11. regression: the collapse confirm gate on the shared mod_collapse path
     (what the collapse_stack alias bridges to) + a static check of the alias
     wiring itself
 12. regression: mod_collapse behaviour unchanged (plain collapse with confirm,
     modifier filter rejects objects without that modifier and leaves them be)

The regression groups (7-12) never touch anything they did not create: each
case builds its own __mcp_reg_* objects and deletes them again, and the whole
run first requires an empty scene (scene_info.objectCount == 0) and aborts
with exit code 3 otherwise.  Results (pass/fail counts and every error) are
written to diag/logs/modeling_ext_test_<timestamp>.{txt,json}.

Wire convention: this suite speaks the BRIDGE protocol directly (the MCP
server is bypassed), so thin wrappers (create_box, create_teapot, the spline
creators, ...) must be sent the `class` the catalog preset would inject
server-side -- every such call below carries it explicitly.

Usage:
    python modeling_ext_test.py [--port 8765] [--host 127.0.0.1] [--list]
    --list prints the regression case list only and never connects to Max,
    so it doubles as a CI / static self-check.
Exit code 0 when every check passed, 1 otherwise, 2 when Max is unreachable,
3 when the scene is not empty.
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
LOGDIR = os.path.join(os.path.dirname(HERE), "logs")

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

    def case(self, name, expect, actual, ok=None):
        """Regression-style check: prints 用例名 / 期望 / 实际 / PASS|FAIL.

        ok defaults to expect == actual; pass it explicitly when the condition
        is not a plain equality (e.g. "must be rejected").
        """
        if ok is None:
            ok = (actual == expect)
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        self.records.append({"check": name, "ok": ok,
                             "expect": str(expect)[:300], "actual": str(actual)[:300]})
        print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
        print("         expect: %s" % str(expect)[:200])
        print("         actual: %s" % str(actual)[:200])
        return ok


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
    # Direct bridge client: thin wrappers receive their `class` from the
    # catalog preset server-side, so a bridge-level caller must send it
    # explicitly (this is what the MCP server's preset merge would send).
    box = b.call("create_box", {"name": "__mcp_ext_box", "class": "Box",
                                "length": 20, "width": 20, "height": 20})
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
    b.call("create_box", {"name": "__mcp_ext_box2", "class": "Box"})
    b.call("mod_add", {"objects": ["__mcp_ext_box2"], "modifier": "Bend", "name": "bend"})
    # bridge convention: handlers never raise on bad input -- the missing
    # modifier is reported in the per-object `failures` list and the object
    # is left untouched (verified by the mod_list check below)
    filt = b.call("mod_collapse", {"objects": ["__mcp_ext_box2"], "modifier": "TurboSmooth",
                                   "confirm": True})
    s.check("mod_collapse filter reports missing modifier",
            len(filt.get("results") or []) == 0 and len(filt.get("failures") or []) == 1, filt)
    stack = b.call("mod_list", {"objects": ["__mcp_ext_box2"]})
    s.check("filtered object untouched", len(stack.get("modifiers", [])) == 1, stack)


def t_poly(s, b):
    print("\n== 4. Edit Poly modelling chain ==")
    b.call("scene_new", {"keepScene": False})
    b.call("create_box", {"name": "__mcp_ext_poly", "class": "Box", "length": 20, "width": 20, "height": 20,
                          "lengthSegs": 2, "widthSegs": 2, "heightSegs": 2})
    conv = b.call("convert_to_editable_poly", {"objects": ["__mcp_ext_poly"]})
    s.check("converted to editable poly", "__mcp_ext_poly" in (conv.get("applied") or []), conv)

    # a 2x2x2 segmented box converts to an editable poly with 26 verts
    # (verified live on 2020: polyop.getNumVerts returns 26, not the 27 a
    # naive 3x3x3 grid count suggests -- one corner is welded) and 24 quads
    info = b.call("poly_info", {"objects": ["__mcp_ext_poly"]})
    rec = (info.get("objects") or [{}])[0]
    faces0 = rec.get("faces")
    s.check("poly_info reads counts", rec.get("verts") == 26 and faces0 == 24, rec)

    elements = b.call("poly_get_elements", {"objects": ["__mcp_ext_poly"]})
    rec = (elements.get("objects") or [{}])[0]
    s.check("box is one element", rec.get("elementCount") == 1, rec)

    # sub-object selection round trip
    sel = b.call("poly_select", {"objects": ["__mcp_ext_poly"], "level": "face", "faces": [1, 2, 3]})
    rec = (sel.get("results") or [{}])[0]
    s.check("poly_select set 3 faces", rec.get("selectedFaces") == 3 and rec.get("level") == 4, rec)
    got = b.call("poly_get_selection", {"objects": ["__mcp_ext_poly"]})
    rec = (got.get("objects") or [{}])[0]
    # NOTE: the faces selection persists across calls, but the sub-object
    # LEVEL does not reliably persist outside the modify-panel context in an
    # unattended session -- assert the selection, not the level.
    s.check("poly_get_selection reads back", rec.get("faces", {}).get("count") == 3
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

    # Edit Poly as a modifier on a fresh primitive.  NOTE: mod_editpoly is a
    # catalog alias (bridge="mod_add", preset {"modifier": "Edit_Poly"}) --
    # the raw bridge command "mod_editpoly" does not exist, so the alias is
    # resolved here exactly the way the MCP server would.
    b.call("create_box", {"name": "__mcp_ext_epmod", "class": "Box", "length": 10, "width": 10, "height": 10})
    added = b.call("mod_add", {"objects": ["__mcp_ext_epmod"], "modifier": "Edit_Poly"})
    stack = b.call("mod_list", {"objects": ["__mcp_ext_epmod"]})
    s.check("Edit_Poly modifier added", any(m.get("class") == "Edit_Poly" for m in stack.get("modifiers", [])), stack)


def t_errors(s, b):
    print("\n== 5. error paths ==")
    b.call("scene_new", {"keepScene": False})
    b.call("create_box", {"name": "__mcp_ext_err", "class": "Box", "length": 5, "width": 5, "height": 5})

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
    # poly_extrude_faces auto-converts a non-poly primitive to editable poly
    # and then applies -- verified by the explicit check right below
    auto = b.call("poly_extrude_faces", {"objects": ["__mcp_ext_err"], "faces": [1], "amount": 1})
    s.check("poly edit on non-poly primitive auto-converts then works",
            "__mcp_ext_err" in (auto.get("applied") or []), auto)

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


# ---------------------------------------------------- regression groups (7-12)
# Declarative case tables: --list prints exactly what the live run executes,
# so the printed list can never drift from the checks themselves.
REG_PREFIX = "__mcp_reg_"

LIGHT_CASES = [
    # (light_create type, expected classof result)
    ("spot", "Targetspot"),
    ("directional", "Targetdirectionallight"),
]

SPLINE_CASES = [
    # (tool, minimal params, expected classof result)
    ("create_rectangle", {"length": 30, "width": 20, "cornerRadius": 2}, "Rectangle"),
    ("create_circle", {"radius": 10}, "Circle"),
    ("create_ellipse", {"length": 24, "width": 12}, "Ellipse"),
    ("create_ngon", {"radius": 10, "sides": 6}, "NGon"),
    ("create_donut", {"radius1": 12, "radius2": 5}, "Donut"),
    ("create_arc", {"radius": 10, "from": 0, "to": 270}, "Arc"),
    ("create_helix", {"radius1": 5, "radius2": 5, "height": 20, "turns": 3}, "Helix"),
    ("create_text", {"text": "MCP", "size": 20}, "Text"),
]

CASE_INDEX = [
    ("7. light_create spot / directional class names (D2 fix)", [
        ("light_create type=%s" % t, "created and classof == %s" % cls) for t, cls in LIGHT_CASES
    ]),
    ("8. all 8 spline creators succeed (D3 class-preset fix)", [
        ("%s" % tool, "created, name kept, classof == %s" % cls) for tool, _p, cls in SPLINE_CASES
    ]),
    ("9. create_teapot smooth=true (D3 boolean coercion fix)", [
        ("create_teapot smooth=true", "object smooth property reads back true"),
    ]),
    ("10. create_pyramid depth=50 (D3 depth parameter fix)", [
        ("create_pyramid depth=50", "object depth property reads back 50"),
    ]),
    ("11. collapse confirm gate on the shared mod_collapse path (D4)", [
        ("mod_collapse without confirm", "rejected (err.confirm_required)"),
        ("mod_collapse with confirm=true", "the modifier stack collapses"),
        ("catalog alias wiring (static, no Max)", "collapse_stack bridges to mod_collapse and requires confirm"),
    ]),
    ("12. mod_collapse behaviour unchanged (D4)", [
        ("mod_collapse with confirm=true", "collapses the whole stack"),
        ("mod_collapse modifier filter", "object without that modifier is rejected and untouched"),
    ]),
]


def _cleanup(s, b, names):
    """Delete only the objects this group created."""
    if not names:
        return
    try:
        b.call("delete_objects", {"objects": list(names)})
    except Exception as exc:  # noqa: BLE001
        s.check("cleanup: delete %s" % ", ".join(names), False, exc)


def _created_name(result, fallback):
    """Primitive/spline creators answer {"object": {...node info...}}."""
    if isinstance(result, dict):
        obj = result.get("object")
        if isinstance(obj, dict) and obj.get("name"):
            return obj["name"]
        if result.get("name"):
            return result["name"]
        created = result.get("created")
        if isinstance(created, list) and created:
            return created[0]
    return fallback


def _catalog_collapse_alias():
    """Static (no Max) check of the D4 alias wiring.

    The Python layer is what rejects collapse_stack without confirm
    ("missing required parameter"), and the bridge never knew the name, so
    this import-based check is the only way to cover that half of the gate.
    Returns (ok, detail); ok is None when the package cannot be imported.
    """
    root = os.path.abspath(os.path.join(HERE, "..", "..", "src", "python"))
    if os.path.isdir(root) and root not in sys.path:
        sys.path.insert(0, root)
    try:
        from maxmcp.catalog import build_catalog
    except Exception as exc:  # noqa: BLE001
        return None, "cannot import maxmcp.catalog (%s); run from the repo" % exc
    try:
        cat = build_catalog()
        entry = cat.get("collapse_stack")
        main = cat.get("mod_collapse")
    except Exception as exc:  # noqa: BLE001
        return False, "catalog build/lookup failed: %s" % exc
    problems = []
    if entry is None:
        problems.append("collapse_stack missing from catalog")
    else:
        bridge = getattr(entry, "bridge_method", None)
        if bridge != "mod_collapse":
            problems.append("bridge_method=%r (want 'mod_collapse')" % (bridge,))
        required = (getattr(entry, "schema", None) or {}).get("required") or []
        if "confirm" not in required:
            problems.append("required=%r (want 'confirm')" % (required,))
    if main is None:
        problems.append("mod_collapse missing from catalog")
    elif "confirm" not in ((getattr(main, "schema", None) or {}).get("required") or []):
        problems.append("mod_collapse no longer requires confirm")
    return (not problems), "; ".join(problems) or "collapse_stack -> mod_collapse, required=[confirm]"


def t_lights_reg(s, b):
    print("\n== 7. regression: light_create spot / directional class names ==")
    created = []
    try:
        for typ, want in LIGHT_CASES:
            nm = REG_PREFIX + "light_" + typ
            try:
                r = b.call("light_create", {"type": typ, "name": nm})
            except BridgeCommandError as exc:
                s.case("light_create type=%s" % typ, "created, classof == %s" % want,
                       "error: %s" % exc, ok=False)
                continue
            got_name = r.get("name") or nm
            got_cls = str(r.get("class") or "")
            created.append(got_name)
            # classof casing is not contractual in MAXScript; compare folded.
            s.case("light_create type=%s -> class %s" % (typ, want),
                   want, got_cls, ok=(got_cls.lower() == want.lower()))
    finally:
        _cleanup(s, b, created)


def t_splines_reg(s, b):
    print("\n== 8. regression: all 8 spline creators succeed ==")
    created = []
    try:
        for tool, params, want in SPLINE_CASES:
            nm = REG_PREFIX + tool
            call = dict(params)
            call["name"] = nm
            call["class"] = want
            try:
                r = b.call(tool, call)
            except BridgeCommandError as exc:
                s.case("%s creates a %s" % (tool, want),
                       "created (old failure: err.missing_param: class)",
                       "error: %s" % exc, ok=False)
                continue
            got = _created_name(r, nm)
            created.append(got)
            info = r.get("object") or {}
            got_cls = str(info.get("class") or "")
            s.case("%s creates a %s" % (tool, want),
                   "name=%s, class=%s" % (nm, want),
                   "name=%s, class=%s" % (got, got_cls),
                   ok=(got == nm and got_cls.lower() == want.lower()))
    finally:
        _cleanup(s, b, created)


def t_teapot_smooth_reg(s, b):
    print("\n== 9. regression: create_teapot smooth=true ==")
    nm = REG_PREFIX + "teapot"
    try:
        r = b.call("create_teapot", {"name": nm, "class": "Teapot", "smooth": True})
        got = _created_name(r, nm)
        s.case("create_teapot smooth=true creates the teapot",
               "created: %s" % nm, "created: %s" % got, ok=(got == nm))
        pv = b.call("get_property_value", {"object": got, "property": "smooth"})
        val = pv.get("value") if pv.get("ok") else None
        s.case("teapot smooth reads back true", True, val,
               ok=(pv.get("ok") is True and val is True))
    except BridgeCommandError as exc:
        s.case("create_teapot smooth=true", "created", "error: %s" % exc, ok=False)
    finally:
        _cleanup(s, b, [nm])


def t_pyramid_reg(s, b):
    print("\n== 10. regression: create_pyramid depth=50 ==")
    nm = REG_PREFIX + "pyramid"
    try:
        r = b.call("create_pyramid", {"name": nm, "class": "Pyramid", "width": 20, "depth": 50, "height": 30})
        got = _created_name(r, nm)
        s.case("create_pyramid depth=50 creates the pyramid",
               "created: %s" % nm, "created: %s" % got, ok=(got == nm))
        pv = b.call("get_property_value", {"object": got, "property": "depth"})
        val = pv.get("value") if pv.get("ok") else None
        s.case("pyramid depth reads back 50", 50, val,
               ok=(pv.get("ok") is True and val is not None and float(val) == 50.0))
    except BridgeCommandError as exc:
        s.case("create_pyramid depth=50", "created", "error: %s" % exc, ok=False)
    finally:
        _cleanup(s, b, [nm])


def t_collapse_gate_reg(s, b):
    print("\n== 11. regression: confirm gate on the shared collapse path ==")
    nm = REG_PREFIX + "gatebox"
    try:
        b.call("create_box", {"name": nm, "class": "Box", "length": 10, "width": 10, "height": 10})
        b.call("mod_add", {"objects": [nm], "modifier": "Bend", "name": "bend"})
        stack = b.call("mod_list", {"objects": [nm]})
        s.case("gate object carries one modifier", 1, len(stack.get("modifiers", [])),
               ok=len(stack.get("modifiers", [])) == 1)
        # The confirm gate lives on the shared protected path that the
        # collapse_stack alias bridges to; a bridge-direct call reaches the
        # Max-side err.confirm_required.
        try:
            b.call("mod_collapse", {"objects": [nm]})
            s.case("mod_collapse without confirm", "rejected (err.confirm_required)",
                   "no error raised", ok=False)
        except BridgeCommandError as exc:
            s.case("mod_collapse without confirm", "rejected (err.confirm_required)",
                   "rejected: %s" % str(exc)[:120], ok=("confirm" in str(exc)))
        res = b.call("mod_collapse", {"objects": [nm], "confirm": True})
        rec = (res.get("results") or [{}])[0]
        s.case("mod_collapse with confirm=true collapses", True, rec.get("collapsed"),
               ok=(rec.get("collapsed") is True and rec.get("modifiersAfter") == 0))
    except BridgeCommandError as exc:
        s.case("collapse gate sequence", "completed without bridge errors",
               "error: %s" % exc, ok=False)
    finally:
        _cleanup(s, b, [nm])
    ok, detail = _catalog_collapse_alias()
    if ok is None:
        s.skip("catalog alias wiring (static)", detail)
    else:
        s.case("catalog alias wiring (static)",
               "collapse_stack -> mod_collapse, required=[confirm]", detail, ok=ok)


def t_mod_collapse_reg(s, b):
    print("\n== 12. regression: mod_collapse behaviour unchanged ==")
    nm = REG_PREFIX + "mcollbox"
    nm2 = REG_PREFIX + "mcollbox2"
    try:
        b.call("create_box", {"name": nm, "class": "Box", "length": 10, "width": 10, "height": 10})
        b.call("mod_add", {"objects": [nm], "modifier": "TurboSmooth", "name": "ts"})
        res = b.call("mod_collapse", {"objects": [nm], "confirm": True})
        rec = (res.get("results") or [{}])[0]
        s.case("mod_collapse with confirm=true collapses", True, rec.get("collapsed"),
               ok=(rec.get("collapsed") is True and rec.get("modifiersAfter") == 0))
        # filter: an object without the named modifier must be rejected and
        # must keep its stack.
        b.call("create_box", {"name": nm2, "class": "Box"})
        b.call("mod_add", {"objects": [nm2], "modifier": "Bend", "name": "bend"})
        # bridge convention: no top-level raise -- the missing modifier shows
        # up in the per-object `failures` list and the object keeps its stack
        try:
            filt = b.call("mod_collapse", {"objects": [nm2], "modifier": "TurboSmooth",
                                           "confirm": True})
            skipped = (len(filt.get("results") or []) == 0
                       and len(filt.get("failures") or []) == 1)
            s.case("mod_collapse filter reports missing modifier", "reported+skipped",
                   json.dumps({"results": filt.get("results"), "failures": filt.get("failures")})[:120],
                   ok=skipped)
        except BridgeCommandError as exc:
            s.case("mod_collapse filter reports missing modifier", "reported+skipped",
                   "rejected: %s" % str(exc)[:120], ok=False)
        stack = b.call("mod_list", {"objects": [nm2]})
        s.case("filtered object untouched", 1, len(stack.get("modifiers", [])),
               ok=len(stack.get("modifiers", [])) == 1)
    except BridgeCommandError as exc:
        s.case("mod_collapse sequence", "completed without bridge errors",
               "error: %s" % exc, ok=False)
    finally:
        _cleanup(s, b, [nm, nm2])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--list", action="store_true", dest="list_cases",
                    help="only print the regression case list; never connects to Max "
                         "(CI / static self-check)")
    args = ap.parse_args()

    if args.list_cases:
        print("=== modeling extension regression case list (no Max connection) ===")
        total = 0
        for group, cases in CASE_INDEX:
            print(group)
            for name, expect in cases:
                total += 1
                print("  - %s" % name)
                print("      expect: %s" % expect)
        print("=== %d regression cases in %d groups ===" % (total, len(CASE_INDEX)))
        return 0

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

    # The regression groups create and delete only their own __mcp_reg_*
    # objects, so the scene must be empty before the run starts; anything else
    # means this test could touch content it does not own.
    try:
        scene = bridge.call("scene_info")
    except BridgeCommandError as exc:
        print("CANNOT READ SCENE: %s" % exc)
        bridge.close()
        return 2
    obj_count = int(scene.get("objectCount", 0) or 0)
    if obj_count != 0:
        print("SCENE NOT EMPTY: scene_info.objectCount=%d." % obj_count)
        print("This test only creates/deletes its own __mcp_reg_* objects and must not")
        print("touch existing content. Save your work, empty the scene, then retry.")
        bridge.close()
        return 3

    suite = Suite()
    groups = (
        ("bridge health", t_bridge),
        ("modifiers", t_modifiers),
        ("edit poly", t_poly),
        ("error paths", t_errors),
        ("script tree sync", t_script_sync),
        ("light class regression", t_lights_reg),
        ("spline creators regression", t_splines_reg),
        ("teapot smooth regression", t_teapot_smooth_reg),
        ("pyramid depth regression", t_pyramid_reg),
        ("collapse confirm gate", t_collapse_gate_reg),
        ("mod_collapse behaviour", t_mod_collapse_reg),
    )
    try:
        for label, fn in groups:
            try:
                fn(suite, bridge)
            except BridgeCommandError as exc:
                # A bridge-level failure (e.g. a module that failed to load
                # and left its commands unregistered) must not abort the
                # whole suite: record it as a failed check and continue.
                suite.check("group '%s' ran without a bridge error" % label,
                            False, str(exc))
            except Exception as exc:  # noqa: BLE001
                suite.check("group '%s' ran without an error" % label,
                            False, "{0}: {1}".format(type(exc).__name__, exc))
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
            extra = r.get("detail") or ""
            if not extra and "expect" in r:
                extra = "expect=%s | actual=%s" % (r.get("expect"), r.get("actual"))
            fh.write("%-4s %s%s\n" % ("PASS" if r["ok"] else ("SKIP" if r["ok"] is None else "FAIL"),
                                      r["check"], "" if r["ok"] else "  -- " + extra))
        fh.write("\n%d passed, %d failed, %d skipped\n" % (suite.passed, suite.failed, suite.skipped))
    with open(js, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
    print("report: %s" % txt)
    return 1 if suite.failed else 0


if __name__ == "__main__":
    sys.exit(main())
