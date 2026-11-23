"""Static contract & server integration tests for asset placement tools."""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.catalog import build_catalog
from maxmcp.config import Config
from maxmcp.server import MaxMcpServer
from fake_scene import FakeScene


class NullTransport:
    def read(self):
        return None

    def write(self, msg):
        pass


class RecordingBridge:
    def __init__(self):
        self.calls = []

    def call(self, method, params=None):
        self.calls.append((method, params))
        if method == "check_overlaps":
            return {"checkedObjects": 2, "overlapCount": 0, "overlaps": [], "message": "ok"}
        if method == "distribute_along_spline":
            return {"success": True, "created": ["Tree_01", "Tree_02"], "count": 2, "failures": [], "message": "ok"}
        return {"success": True, "applied": ["Box001"], "placed": [{"name": "Box001"}], "failures": [], "message": "ok"}

    def status(self):
        return {"connected": True, "info": {"language": "en", "maxLanguage": "ENU"}}


FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print("  ok   " + name)
    else:
        print("  FAIL " + name + ("  " + detail if detail else ""))
        FAILURES.append(name)


def main() -> int:
    catalog = build_catalog()

    print("1. catalog & domain declarations")
    expected = {
        "place_on_surface": (True, ("objects", "selection")),
        "place_relative": (True, ("objects", "selection")),
        "distribute_along_spline": (True, ("scene", "objects", "selection")),
        "check_overlaps": (False, ()),
    }
    for name, (mutating, domains) in expected.items():
        entry = catalog.get(name)
        check(name + " registered in catalog", entry is not None)
        if entry is not None:
            check(name + " mutating=" + str(mutating), entry.mutating is mutating)
            check(name + " mutates=" + str(domains), entry.mutates == domains, repr(entry.mutates))

    print("2. MAXScript handlers & scene_merge enhancement")
    ms_objects = (ROOT / "src" / "ms" / "mcp_objects.ms").read_text(encoding="utf-8", errors="replace")
    for name in expected:
        check("mcpH_" + name + " defined", ("fn mcpH_" + name) in ms_objects)
        check('mcpRegister "' + name + '"' , ('mcpRegister "' + name + '"') in ms_objects)
    check("place_on_surface has read-back", "actualZ" in ms_objects and "expectedZ" in ms_objects)
    check("place_relative has read-back", "distance n.position expectedPos" in ms_objects)

    ms_scene = (ROOT / "src" / "ms" / "mcp_system.ms").read_text(encoding="utf-8", errors="replace")
    check("scene_merge returns addedObjects", "addedObjects" in ms_scene and "addedCount" in ms_scene)

    print("3. server validation & bridge payload")
    server = MaxMcpServer(Config(tool_profile="full", language="en"), NullTransport())
    bridge = RecordingBridge()
    server.bridge = bridge

    res = server.on_tools_call({"name": "place_relative", "arguments": {"side": "top"}})
    check("place_relative requires target", res.get("isError") is True)

    res = server.on_tools_call({"name": "place_relative", "arguments": {"target": "Table", "side": "diagonal"}})
    check("place_relative rejects invalid side", res.get("isError") is True)

    res = server.on_tools_call({"name": "distribute_along_spline", "arguments": {"count": 5}})
    check("distribute_along_spline requires spline", res.get("isError") is True)

    res = server.on_tools_call({"name": "place_on_surface", "arguments": {"objects": ["Box001"], "surface": "Ground", "offset": -0.5}})
    check("place_on_surface succeeds", res.get("isError") is not True)
    check("place_on_surface forwarded payload", bridge.calls[-1][0] == "place_on_surface" and bridge.calls[-1][1]["offset"] == -0.5)

    res = server.on_tools_call({"name": "check_overlaps", "arguments": {"ignore": ["Ground"], "tolerance": 0.02}})
    check("check_overlaps succeeds", res.get("isError") is not True)
    check("check_overlaps forwarded payload", bridge.calls[-1][0] == "check_overlaps" and bridge.calls[-1][1]["tolerance"] == 0.02)

    print("4. FakeScene 3D bounding-box simulation & overlap detection")
    scene = FakeScene()
    scene.call("create_plane", {"name": "Ground", "width": 200, "length": 200, "position": [0, 0, 0]})
    scene.call("create_box", {"name": "Table", "width": 80, "length": 60, "height": 40, "position": [0, 0, 30]})
    drop_res = scene.call("place_on_surface", {"objects": ["Table"], "surface": "Ground"})
    check("FakeScene place_on_surface drops table to z=0",
          drop_res["success"] is True and abs(scene.node("Table")["boundingBox"]["min"][2]) < 0.01)

    scene.call("create_box", {"name": "Vase", "width": 10, "length": 10, "height": 20, "position": [50, 50, 0]})
    rel_res = scene.call("place_relative", {"objects": ["Vase"], "target": "Table", "side": "top"})
    check("FakeScene place_relative puts vase on table top (z=40)",
          rel_res["success"] is True and abs(scene.node("Vase")["boundingBox"]["min"][2] - 40.0) < 0.01)

    ov_clean = scene.call("check_overlaps", {"objects": ["Table", "Vase"], "ignore": ["Ground"]})
    check("flush contact on table top reports 0 overlaps", ov_clean["overlapCount"] == 0)

    scene.call("place_relative", {"objects": ["Vase"], "target": "Table", "side": "top", "gap": -5.0})
    ov_hit = scene.call("check_overlaps", {"objects": ["Table", "Vase"], "ignore": ["Ground"]})
    check("negative gap penetration is detected by check_overlaps", ov_hit["overlapCount"] == 1)

    scene.call("create_line", {"name": "Path01", "points": [[0, 0, 0], [100, 0, 0]]})
    dist_res = scene.call("distribute_along_spline", {"objects": ["Vase"], "spline": "Path01", "count": 4, "surface": "Ground"})
    check("FakeScene distribute_along_spline clones 4 instances",
          dist_res["success"] is True and dist_res["count"] == 4)

    if FAILURES:
        print("\nFAILED: " + ", ".join(FAILURES))
        return 1
    print("\nasset placement: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
