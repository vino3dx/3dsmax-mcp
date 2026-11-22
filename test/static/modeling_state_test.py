"""Offline integration tests for modelling / modifier result integrity.

Evidence level: **Offline**.  The chain under test is the real one:

    tools/call -> MaxMcpServer -> MaxBridge (real TCP socket)
               -> SceneBridgeStub -> FakeScene (mirrors MAXScript handlers)

Only 3ds Max itself is absent.  Every scene change happens in the fake scene, so
the read-backs added in Stage 10 have something to read, and every reply is
parsed by the real reliability layer (``--profile core``).

What this proves and what it does not:

  provable here   a created object is reported by the name the scene kept, a
                  rejected dimension is a failure rather than a cheerful
                  "Created", a modifier that never entered the stack is a
                  failure, a clamped modifier property is caught by the
                  read-back, a topology op that changed nothing says so without
                  pretending to be a failure, align/attach/parent name what the
                  scene actually did, and a boolean that consumed nothing is
                  reported;
  NOT provable    that 3ds Max itself behaves this way.  Every claim here is
                  Static or Offline; the live checks are R15-R20 in
                  docs/WORKFLOW_ACCEPTANCE.md.

Groups:
  CREATE   primitive/spline/line creation verdicts
  MOD      modifier add / set_param / remove read-backs
  POLY     topology no-op vs failure
  OBJ      align / attach / parent / boolean / clone / array
"""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

from fake_scene import FakeScene  # noqa: E402
from scene_bridge_stub import SceneBridgeStub  # noqa: E402


class Harness:
    """A server talking to a stubbed bridge over a real socket."""

    def __init__(self, scene=None, profile="core"):
        self.scene = scene if scene is not None else FakeScene()
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


def _failures(payload):
    """Kinds from the runtime envelope (normalised codes)."""
    return [f.get("kind") for f in payload.get("failures") or []]


def _r(payload):
    """The handler's own reply, which the runtime nests under ``result``."""
    inner = payload.get("result")
    return inner if isinstance(inner, dict) else {}


def _texts(payload):
    """The handler's own failure strings, not the normalised codes."""
    return [f for f in _r(payload).get("failures") or [] if isinstance(f, str)]


# ---------------------------------------------------------------- CREATE group
def check_primitive_creation_reports_the_real_node():
    h = Harness()
    try:
        is_error, payload = h.call("create_box", {"length": 10, "width": 20,
                                                  "height": 30, "name": "Crate"})
        assert not is_error, payload
        assert _r(payload)["success"] is True
        assert _r(payload)["object"]["name"] == "Crate"
        assert _r(payload)["object"]["length"] == 10.0
        assert h.scene.node("Crate") is not None, "the object must exist, not just be reported"
    finally:
        h.close()


def check_name_collision_is_a_warning_not_a_failure():
    """Max keeps a unique variant.  That is information, not a failed creation:
    treating it as a failure would make the agent retry and leave a duplicate."""
    h = Harness()
    try:
        h.call("create_box", {"name": "Crate"})
        is_error, payload = h.call("create_box", {"name": "Crate"})
        assert not is_error, payload
        assert _r(payload)["success"] is True
        assert _r(payload)["object"]["name"] != "Crate"
        assert any("name: scene kept" in w for w in _r(payload)["warnings"]), payload
        assert not _texts(payload)
        assert len([k for k in h.scene.nodes if k.startswith("Crate")]) == 2
    finally:
        h.close()


def check_rejected_dimension_is_a_failure():
    h = Harness()
    h.scene.clamp_props["radius"] = 50.0
    try:
        is_error, payload = h.call("create_sphere", {"radius": 5, "name": "Ball"})
        assert is_error, "the radius never took effect, so this is not a success"
        assert _r(payload)["success"] is False
        assert any("radius: kept" in f for f in _texts(payload)), payload
        # the object still exists; the failure is about the dimension only
        assert h.scene.node("Ball")["radius"] == 50.0
    finally:
        h.close()


def check_spline_creation_has_a_verdict():
    """create_circle used to answer missing_success under the core profile: the
    reply carried only a nested node payload, which the runtime cannot read."""
    h = Harness()
    try:
        is_error, payload = h.call("create_circle", {"radius": 25, "name": "Ring"})
        assert not is_error, payload
        assert _r(payload)["success"] is True
        assert _r(payload)["object"]["radius"] == 25.0
        assert "failures" in payload
        assert h.scene.calls.count("create_circle") == 1
    finally:
        h.close()


def check_line_knots_are_counted():
    h = Harness()
    try:
        points = [[0, 0, 0], [10, 0, 0], [10, 10, 0]]
        is_error, payload = h.call("create_line", {"points": points, "name": "Path"})
        assert not is_error, payload
        assert _r(payload)["object"]["knots"] == 3

        # A line whose knots did not land is not a created line.
        h.scene.reject_ops.add("Path2")
        is_error, payload = h.call("create_line", {"points": points, "name": "Path2"})
        assert is_error
        assert any("knots" in f for f in _texts(payload)), payload
    finally:
        h.close()


# ------------------------------------------------------------------- MOD group
def check_mod_add_verifies_the_stack():
    # mod_add is reconciled per object, so the verdict is in `objects[].success`.
    h = Harness()
    h.scene.add("Box001")
    try:
        is_error, payload = h.call("mod_add", {"objects": ["Box001"],
                                              "modifier": "TurboSmooth"})
        assert not is_error, payload
        assert payload["objects"][0]["success"] is True
        assert payload["summary"]["succeeded"] == 1
        assert "TurboSmooth" in h.scene.node("Box001")["modifiers"]
    finally:
        h.close()


def check_mod_add_refused_param_is_a_failure():
    h = Harness()
    h.scene.add("Box001")
    h.scene.clamp_mod_props["angle"] = 30.0
    try:
        # mod_bend is a preset wrapper over mod_add: `angle` arrives as a
        # top-level key, which mod_add treats as a modifier property.
        is_error, payload = h.call("mod_bend", {"objects": ["Box001"], "angle": 90})
        assert is_error, "the parameter was rejected, so the call did not do what was asked"
        assert payload["success"] is False
        assert _r(payload)["applied"] == [], payload
        assert any("rejected" in f for f in _texts(payload)), payload
        # the modifier itself did attach; the failure is about the parameter
        assert "Bend" in h.scene.node("Box001")["modifiers"]
    finally:
        h.close()


def check_mod_set_param_reads_the_value_back():
    h = Harness()
    h.scene.add("Box001")
    h.call("mod_add", {"objects": ["Box001"], "modifier": "Bend"})
    try:
        is_error, payload = h.call("mod_set_param", {"objects": ["Box001"],
                                                     "modifier": "Bend",
                                                     "param": "angle", "value": 45})
        assert not is_error, payload
        assert _r(payload)["applied"] == ["Box001"]
        assert h.scene.node("Box001")["modParams"]["angle"] == 45

        h.scene.clamp_mod_props["angle"] = 30.0
        is_error, payload = h.call("mod_set_param", {"objects": ["Box001"],
                                                     "modifier": "Bend",
                                                     "param": "angle", "value": 90})
        assert is_error, "the value was clamped; reporting success would be a lie"
        assert any("angle: kept" in f for f in _texts(payload)), payload
    finally:
        h.close()


def check_mod_remove_confirms_the_stack_shrank():
    h = Harness()
    h.scene.add("Box001")
    h.call("mod_add", {"objects": ["Box001"], "modifier": "Bend"})
    try:
        is_error, payload = h.call("mod_remove", {"objects": ["Box001"],
                                                  "modifier": "Bend"})
        assert not is_error, payload
        assert _r(payload)["removed"] == ["Box001"]
        assert "Bend" not in h.scene.node("Box001")["modifiers"]

        is_error, payload = h.call("mod_remove", {"objects": ["Box001"],
                                                  "modifier": "Bend"})
        assert is_error, "removing a modifier that is not there is not a success"
        assert any("no modifier" in f for f in _texts(payload)), payload
    finally:
        h.close()


# ------------------------------------------------------------------ POLY group
def check_topology_noop_is_reported_without_failing():
    """A weld of coincident vertices changes nothing and is still a valid call.
    The handler must say "unchanged" rather than pretend it changed the mesh."""
    h = Harness()
    h.scene.add("Plane001", klass="Editable_Poly")
    h.scene.node("Plane001")["isPoly"] = True
    h.scene.poly_noop = True
    try:
        is_error, payload = h.call("poly_weld_vertices", {"objects": ["Plane001"],
                                                          "vertices": [1, 2]})
        assert not is_error, payload
        assert _r(payload)["applied"] == ["Plane001"]
        assert _r(payload)["unchanged"] == ["Plane001"]
        assert not _texts(payload)
    finally:
        h.close()


def check_topology_change_is_not_reported_as_unchanged():
    h = Harness()
    h.scene.add("Plane001", klass="Editable_Poly")
    h.scene.node("Plane001")["isPoly"] = True
    try:
        is_error, payload = h.call("poly_extrude_faces", {"objects": ["Plane001"],
                                                          "faces": [1], "amount": 5})
        assert not is_error, payload
        assert _r(payload)["applied"] == ["Plane001"]
        assert _r(payload)["unchanged"] == []
    finally:
        h.close()


def check_poly_failure_names_the_object():
    h = Harness()
    h.scene.add("Box001")          # not a poly
    try:
        is_error, payload = h.call("poly_extrude_faces", {"objects": ["Box001"],
                                                          "faces": [1], "amount": 5})
        assert is_error
        assert _r(payload)["applied"] == []
        assert any("Editable Poly required" in f for f in _texts(payload)), payload
    finally:
        h.close()


# ------------------------------------------------------------------- OBJ group
def check_align_reports_only_what_the_scene_accepted():
    h = Harness()
    h.scene.add("Target", position=[10, 0, 0])
    h.scene.add("Free")
    h.scene.add("Locked")
    h.scene.reject_ops.add("Locked")
    try:
        is_error, payload = h.call("align_objects", {"objects": ["Free", "Locked"],
                                                     "target": "Target"})
        assert is_error, "one object refused, so the batch is not a clean success"
        assert _r(payload)["aligned"] == ["Free"], payload
        assert any("Locked" in f for f in _texts(payload)), payload
        assert h.scene.node("Free")["position"] == [10.0, 0.0, 0.0]
        assert h.scene.node("Locked")["position"] == [0.0, 0.0, 0.0]
    finally:
        h.close()


def check_attach_requires_a_shape_target():
    """The old handler swallowed convertToSplineShape's failure and listed every
    requested node as attached."""
    h = Harness()
    h.scene.add("Crate", klass="Box")
    h.scene.add("Ring", klass="Circle")
    try:
        is_error, payload = h.call("attach_objects", {"target": "Crate",
                                                      "objects": ["Ring"]})
        assert is_error
        assert _failures(payload) == ["invalid_arguments"], payload
        assert "not a shape" in payload["failures"][0]["message"]
        assert h.scene.node("Ring") is not None, "nothing may be consumed on a refused attach"
    finally:
        h.close()


def check_attach_counts_splines():
    h = Harness()
    h.scene.add("Base", klass="Circle")
    h.scene.add("Ring", klass="Circle")
    try:
        is_error, payload = h.call("attach_objects", {"target": "Base",
                                                      "objects": ["Ring"]})
        assert not is_error, payload
        assert _r(payload)["attached"] == ["Ring"]
        assert h.scene.node("Base")["splines"] == 2
        assert h.scene.node("Ring") is None, "attach consumes the source"
    finally:
        h.close()


def check_parent_reports_real_children():
    h = Harness()
    h.scene.add("Parent")
    h.scene.add("Child")
    h.scene.add("Stuck")
    h.scene.reject_ops.add("Stuck")
    try:
        is_error, payload = h.call("parent_objects", {"objects": ["Child", "Stuck"],
                                                      "parent": "Parent"})
        assert is_error
        assert _r(payload)["children"] == ["Child"], payload
        assert h.scene.node("Child")["parent"] == "Parent"
        assert h.scene.node("Stuck")["parent"] == ""
    finally:
        h.close()


def check_boolean_reports_a_consumed_nothing_operand():
    h = Harness()
    h.scene.add("A", klass="Editable_Poly")
    h.scene.add("B", klass="Editable_Poly")
    h.scene.boolean_noop = True
    try:
        is_error, payload = h.call("boolean_operation", {"objects": ["A", "B"],
                                                         "operation": "union"})
        assert is_error, "the operand was never consumed, so the boolean did not happen"
        assert _r(payload)["success"] is False
        assert payload["changed"] is False
        assert any("still in the scene" in f for f in _texts(payload)), payload
    finally:
        h.close()


def check_boolean_changes_the_result():
    h = Harness()
    h.scene.add("A", klass="Editable_Poly")
    h.scene.add("B", klass="Editable_Poly")
    try:
        is_error, payload = h.call("boolean_operation", {"objects": ["A", "B"],
                                                         "operation": "union"})
        assert not is_error, payload
        assert _r(payload)["success"] is True
        assert payload["changed"] is True
        assert _r(payload)["facesAfter"] > _r(payload)["facesBefore"]
    finally:
        h.close()


def check_clone_partial_failure_is_visible():
    h = Harness()
    h.scene.add("Crate")
    h.scene.reject_ops.add("Crate")
    try:
        is_error, payload = h.call("clone_objects", {"objects": ["Crate"],
                                                     "count": 2})
        assert is_error, "no copy was made, so nothing may be reported as created"
        row = payload["objects"][0]
        assert row["success"] is False
        assert row["created"] == []
        assert row["error"]["kind"] == "no_effect"
        assert not [k for k in h.scene.nodes if k.startswith("Crate_clone")]
    finally:
        h.close()


def check_array_separates_created_from_moved():
    """The grid array repositions the original as cell (1,1,1); calling that a
    created object made a move look like a copy."""
    h = Harness()
    h.scene.add("Crate")
    try:
        is_error, payload = h.call("array_objects", {"objects": ["Crate"],
                                                     "mode": "grid", "count1": 3})
        assert not is_error, payload
        assert len(_r(payload)["created"]) == 2, payload
        assert _r(payload)["moved"] == ["Crate"], payload
        assert _r(payload)["count"] == 2
    finally:
        h.close()


def main():
    check_primitive_creation_reports_the_real_node()
    check_name_collision_is_a_warning_not_a_failure()
    check_rejected_dimension_is_a_failure()
    check_spline_creation_has_a_verdict()
    check_line_knots_are_counted()
    check_mod_add_verifies_the_stack()
    check_mod_add_refused_param_is_a_failure()
    check_mod_set_param_reads_the_value_back()
    check_mod_remove_confirms_the_stack_shrank()
    check_topology_noop_is_reported_without_failing()
    check_topology_change_is_not_reported_as_unchanged()
    check_poly_failure_names_the_object()
    check_align_reports_only_what_the_scene_accepted()
    check_attach_requires_a_shape_target()
    check_attach_counts_splines()
    check_parent_reports_real_children()
    check_boolean_reports_a_consumed_nothing_operand()
    check_boolean_changes_the_result()
    check_clone_partial_failure_is_visible()
    check_array_separates_created_from_moved()
    print("modelling state (offline): all checks passed")


if __name__ == "__main__":
    main()
