"""Offline tests for per-object state operations and their receipts.

Evidence level: **Offline**.  The chain is the real one:

    tools/call -> MaxMcpServer -> MaxBridge (real TCP)
               -> SceneBridgeStub -> FakeScene

Why this file exists: a whole class of handlers used to answer "Done." after
wrapping the real call in ``try (...) catch()``, so an operation that changed
nothing looked exactly like one that worked.  The fix was to report the state
the scene is in afterwards (``isHidden`` / ``isFrozen`` read back) or to name the
objects that threw.  These checks pin that behaviour down, including the case
that matters most: some objects succeed and some do not, which must never be
reported as overall success.

What is proven: the reply shape, the partial-success rule, and that the scene
state really changed inside the stub.  What is not: that 3ds Max behaves the
same way - that stays with docs/OVERNIGHT_ACCEPTANCE.md (level M).
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import json  # noqa: E402

from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

from fake_scene import FakeScene  # noqa: E402
from scene_bridge_stub import SceneBridgeStub  # noqa: E402


class Harness:
    """A server talking to a stubbed bridge over a real socket."""

    def __init__(self, profile="core"):
        self.scene = FakeScene()
        self.stub = SceneBridgeStub(self.scene)
        self.server = MaxMcpServer(
            Config(port=self.stub.port, port_scan=1, connect_timeout_s=1.0,
                   timeout_s=3.0, tool_profile=profile, language="en"),
            NullTransport(),
        )

    def call(self, name, arguments=None):
        reply = self.server.on_tools_call({"name": name, "arguments": arguments or {}})
        text = reply["content"][0]["text"]
        payload = json.loads(text) if text.strip().startswith(("{", "[")) else text
        return reply.get("isError", False), payload

    def close(self):
        self.stub.close()


def data_of(payload):
    """The handler's own reply, unwrapped from the runtime envelope."""
    assert isinstance(payload, dict), payload
    body = payload.get("data")
    assert isinstance(body, dict), "expected the handler reply under data: {0}".format(payload)
    return body


# ------------------------------------------------------------------ visibility
def check_hide_reports_the_scene_state():
    h = Harness()
    h.scene.add("Box001")
    h.scene.add("Box002")
    try:
        is_error, payload = h.call("hide_objects", {"objects": ["Box001", "Box002"]})
        assert not is_error, payload.get("failures")
        body = data_of(payload)
        assert body["hidden"] == ["Box001", "Box002"]
        assert body["failures"] == []
        assert h.scene.node("Box001")["isHidden"] is True
        assert h.scene.node("Box002")["isHidden"] is True

        is_error, payload = h.call("unhide_objects", {"objects": ["Box001"]})
        assert not is_error, payload.get("failures")
        assert data_of(payload)["shown"] == ["Box001"]
        assert h.scene.node("Box001")["isHidden"] is False
        assert h.scene.node("Box002")["isHidden"] is True, "the other one stays hidden"
    finally:
        h.close()


def check_hide_partial_failure_is_not_success():
    """The case this whole refactor exists for."""
    h = Harness()
    h.scene.add("Box001")
    h.scene.add("Box002")
    h.scene.reject_ops.add("Box002")
    try:
        is_error, payload = h.call("hide_objects", {"objects": ["Box001", "Box002"]})
        assert is_error, "one object refused; the call must not claim success"
        assert payload["success"] is False
        body = data_of(payload)
        assert body["hidden"] == ["Box001"]
        assert body["failures"] == ["Box002"]
        assert h.scene.node("Box001")["isHidden"] is True
        assert h.scene.node("Box002")["isHidden"] is False, "the refused one did not change"
    finally:
        h.close()


def check_hide_reports_state_not_request():
    """Already hidden: the call runs, the report still says hidden."""
    h = Harness()
    h.scene.add("Box001")
    h.scene.node("Box001")["isHidden"] = True
    try:
        is_error, payload = h.call("hide_objects", {"objects": ["Box001"]})
        assert not is_error, payload.get("failures")
        assert data_of(payload)["hidden"] == ["Box001"]
    finally:
        h.close()


def check_unhide_all_covers_every_object():
    h = Harness()
    for name in ("Box001", "Box002", "Sphere001"):
        h.scene.add(name)
        h.scene.node(name)["isHidden"] = True
    try:
        is_error, payload = h.call("unhide_all")
        assert not is_error, payload.get("failures")
        body = data_of(payload)
        assert sorted(body["shown"]) == ["Box001", "Box002", "Sphere001"]
        assert body["failures"] == []
        for name in ("Box001", "Box002", "Sphere001"):
            assert h.scene.node(name)["isHidden"] is False
    finally:
        h.close()


def check_freeze_and_thaw():
    h = Harness()
    h.scene.add("Box001")
    h.scene.add("Box002")
    try:
        is_error, payload = h.call("freeze_objects", {"objects": ["Box001"]})
        assert not is_error, payload.get("failures")
        assert data_of(payload)["frozen"] == ["Box001"]
        assert h.scene.node("Box001")["isFrozen"] is True
        assert h.scene.node("Box002")["isFrozen"] is False

        is_error, payload = h.call("unfreeze_all")
        assert not is_error, payload.get("failures")
        assert data_of(payload)["thawed"] == ["Box001"]
        assert h.scene.node("Box001")["isFrozen"] is False
    finally:
        h.close()


# ------------------------------------------------------------------- transforms
def check_reset_transform_reports_each_object():
    h = Harness()
    h.scene.add("Box001")
    h.scene.add("Box002")
    h.scene.node("Box001")["rotation"] = [10.0, 0.0, 0.0]
    h.scene.node("Box001")["scale"] = [2.0, 2.0, 2.0]
    h.scene.node("Box002")["rotation"] = [0.0, 20.0, 0.0]
    h.scene.reject_ops.add("Box002")
    try:
        is_error, payload = h.call("reset_transform", {"objects": ["Box001", "Box002"]})
        assert is_error, "the second object refused"
        body = data_of(payload)
        assert body["applied"] == ["Box001"]
        assert body["failures"] == ["Box002"]
        assert h.scene.node("Box001")["rotation"] == [0.0, 0.0, 0.0]
        assert h.scene.node("Box001")["scale"] == [1.0, 1.0, 1.0]
        assert h.scene.node("Box002")["rotation"] == [0.0, 20.0, 0.0], "untouched"
    finally:
        h.close()


def check_reset_transform_can_skip_parts():
    h = Harness()
    h.scene.add("Box001")
    h.scene.node("Box001")["rotation"] = [10.0, 0.0, 0.0]
    h.scene.node("Box001")["scale"] = [2.0, 2.0, 2.0]
    h.scene.node("Box001")["position"] = [5.0, 5.0, 5.0]
    try:
        is_error, payload = h.call("reset_transform", {
            "objects": ["Box001"], "rotation": True, "scale": False, "position": False})
        assert not is_error, payload.get("failures")
        assert h.scene.node("Box001")["rotation"] == [0.0, 0.0, 0.0]
        assert h.scene.node("Box001")["scale"] == [2.0, 2.0, 2.0], "scale was not requested"
        assert h.scene.node("Box001")["position"] == [5.0, 5.0, 5.0]
    finally:
        h.close()


def check_snap_to_grid_moves_and_reports():
    h = Harness()
    h.scene.add("Box001", position=[3.0, 7.0, 0.0])
    h.scene.add("Box002", position=[12.0, 0.0, 4.0])
    h.scene.add("Box003", position=[5.0, 5.0, 5.0])
    h.scene.reject_ops.add("Box003")
    try:
        is_error, payload = h.call("snap_objects_to_grid",
                                   {"objects": ["Box001", "Box002", "Box003"], "spacing": 10})
        assert is_error, "Box003 refused"
        body = data_of(payload)
        assert body["applied"] == ["Box001", "Box002"]
        assert body["failures"] == ["Box003"]
        assert h.scene.node("Box001")["position"] == [0.0, 10.0, 0.0]
        assert h.scene.node("Box002")["position"] == [10.0, 0.0, 0.0]
        assert h.scene.node("Box003")["position"] == [5.0, 5.0, 5.0]
    finally:
        h.close()


# ----------------------------------------------------------------------- groups
def check_group_open_refuses_plain_meshes():
    h = Harness()
    h.scene.add("Box001")
    h.scene.add("Box002")
    try:
        is_error, payload = h.call("open_group", {"objects": ["Box001"]})
        assert is_error, "a plain mesh is not a group"
        assert data_of(payload)["failures"] == ["Box001"]
        assert data_of(payload)["applied"] == []

        h.call("group_objects", {"objects": ["Box001", "Box002"], "name": "G1"})
        is_error, payload = h.call("open_group", {"objects": ["G1"]})
        assert not is_error, payload.get("failures")
        assert data_of(payload)["applied"] == ["G1"]
        assert h.scene.node("G1")["groupOpen"] is True

        is_error, payload = h.call("close_group", {"objects": ["G1"]})
        assert not is_error, payload.get("failures")
        assert h.scene.node("G1")["groupOpen"] is False
    finally:
        h.close()


# ------------------------------------------------------- whole-batch behaviour
def check_scene_new_keeps_settings_only_when_asked():
    """`keepScene` used to be advertised but never read, so every call reset the
    units, frame rate and render size along with the objects."""
    h = Harness()
    h.scene.add("Box001")
    try:
        # Without the flag: everything goes, settings included.
        is_error, payload = h.call("scene_new", {})
        assert not is_error, payload.get("failures")
        body = data_of(payload)
        assert body["created"] is True
        assert body["kept"] == []
        assert h.scene.nodes == {}, "the scene is empty"
        assert h.scene.session == {}, "settings were reset too"

        # With the flag: objects go, settings stay.
        h.scene.add("Box001")
        h.scene.session = {"units": "m", "frameRate": 25, "resolution": [1920, 1080]}
        is_error, payload = h.call("scene_new", {"keepScene": True})
        assert not is_error, payload.get("failures")
        body = data_of(payload)
        assert body["kept"] == ["frameRate", "resolution", "units"]
        assert h.scene.nodes == {}, "objects are still cleared"
        assert h.scene.session["units"] == "m"
        assert h.scene.session["frameRate"] == 25
        assert h.scene.session["resolution"] == [1920, 1080]
        assert h.scene.layers == {"0": {"name": "0", "hidden": False,
                                        "frozen": False, "wireColor": None}}
    finally:
        h.close()


def check_empty_target_list_is_an_honest_no_op():
    """No objects and no selection: nothing to do, nothing claimed."""
    h = Harness()
    try:
        is_error, payload = h.call("hide_objects", {"objects": []})
        assert not is_error, payload.get("failures")
        body = data_of(payload)
        assert body["hidden"] == []
        assert body["failures"] == []
    finally:
        h.close()


def main():
    check_hide_reports_the_scene_state()
    check_hide_partial_failure_is_not_success()
    check_hide_reports_state_not_request()
    check_unhide_all_covers_every_object()
    check_freeze_and_thaw()
    check_reset_transform_reports_each_object()
    check_reset_transform_can_skip_parts()
    check_snap_to_grid_moves_and_reports()
    check_group_open_refuses_plain_meshes()
    check_scene_new_keeps_settings_only_when_asked()
    check_empty_target_list_is_an_honest_no_op()
    print("object state (offline): all checks passed")


if __name__ == "__main__":
    main()
