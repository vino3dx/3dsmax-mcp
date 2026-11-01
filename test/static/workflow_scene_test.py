"""Offline integration tests for agent scene workflows.

Evidence level: **Offline**.  The chain under test is the real one:

    tools/call -> MaxMcpServer -> MaxBridge (real TCP socket)
               -> SceneBridgeStub -> FakeScene (mirrors MAXScript handlers)

Only 3ds Max itself is absent.  Framing, error classification, the reliability
mode (``--profile core``), batch reconciliation, the scene runtime, image
splitting and the Python-side workflow tools all execute for real, and every
scene mutation happens in the fake scene so read-back verification has something
to read.

What this proves and what it does not:

  provable here   tool ordering, per-step verification, skip/abort policy,
                  snapshot + diff shape, rename and identity handling, retry
                  refusal, interrupt handling, error codes, MCP content shape;
  NOT provable    that 3ds Max really creates/moves/assigns anything.  Those
                  claims stay in docs/OVERNIGHT_ACCEPTANCE.md (level M).

Groups:
  W1-W3  the three standard workflows end to end
  SNAP   scene_snapshot: baseline diff, truncation, rename, duplicate, identity
  FAIL   mid-run bridge death, visual feedback missing, retry refusal
  META   listing, dry run, unknown/nested workflow, custom steps, tolerance
"""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp.bridge import BridgeDisconnected  # noqa: E402
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402
from maxmcp.workflow import STANDARD_WORKFLOWS  # noqa: E402

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


def workflow(h, name, **extra):
    return h.call("workflow_run", dict({"workflow": name}, **extra))


# ------------------------------------------------------- W: standard workflows
def check_workflow_basic_scene():
    h = Harness()
    try:
        is_error, record = workflow(h, "basic_scene")
        assert not is_error, record
        assert record["status"] == "success", record["summary"]
        assert record["summary"]["total"] == 10
        assert record["summary"]["succeeded"] == 10
        assert record["summary"]["verified"] == 10, record["summary"]

        # the objects really exist in the scene afterwards, with the transforms
        assert sorted(h.scene.nodes) == ["Ball", "Cube", "Ground", "Wall"]
        assert h.scene.node("Cube")["position"] == [-50, 0, 20]
        assert h.scene.node("Ball")["position"] == [50, 0, 20]

        diff = record["diff"]
        assert sorted(diff["added"]) == ["Ball", "Cube", "Ground", "Wall"]
        assert diff["removed"] == []
        assert diff["counts"]["before"] == 0 and diff["counts"]["after"] == 4
        assert record["expectation"]["passed"] is True
        kinds = {check["check"] for check in record["expectation"]["checks"]}
        assert kinds == {"added_includes", "count_delta"}
    finally:
        h.close()


def check_workflow_model_processing():
    h = Harness()
    h.scene.add("Cube")
    try:
        is_error, record = workflow(h, "model_processing")
        assert not is_error, record
        assert record["status"] == "success", record["summary"]
        node = h.scene.node("Cube")
        assert node["class"] == "Editable_Poly"
        assert node["modifiers"] == ["TurboSmooth"]
        assert node["faceCount"] > 6, "the extrude really added faces in the fake scene"
        assert record["expectation"]["passed"] is True
        # only the modifiers/faces changed: the diff must not invent additions
        assert record["diff"]["added"] == []
        assert [item["name"] for item in record["diff"]["modified"]] == ["Cube"]
        assert "modifiers" in record["diff"]["modified"][0]["fields"]
    finally:
        h.close()


def check_workflow_material_look():
    h = Harness()
    h.scene.add("Ground", "Plane")
    h.scene.add("Ball", "Sphere")
    try:
        is_error, record = workflow(h, "material_look")
        assert not is_error, record
        assert record["status"] == "success", record["summary"]
        assert h.scene.node("Ground")["material"] == "MatteRed"
        assert h.scene.node("Ball")["material"] == "MatteBlue"
        assert sorted(h.scene.materials) == ["MatteBlue", "MatteRed"]
        diff = record["diff"]
        assert sorted(item["name"] for item in diff["modified"]) == ["Ball", "Ground"]
        for item in diff["modified"]:
            assert "material" in item["fields"], item
        assert record["expectation"]["passed"] is True
    finally:
        h.close()


# ------------------------------------------------------------- SNAP: snapshots
def check_snapshot_and_baseline_diff():
    h = Harness()
    h.scene.add("Box001")
    try:
        is_error, first = h.call("scene_snapshot")
        assert not is_error, first
        assert first["snapshot_id"].startswith("snap-")
        assert first["node_count"] == 1
        assert first["complete"] is True
        assert first["handles_unique"] is True

        h.call("create_box", {"name": "Box002"})
        h.call("transform_object", {"objects": ["Box001"], "operation": "move",
                                    "mode": "absolute", "value": [0, 0, 25]})
        h.call("select_objects", {"objects": ["Box002"]})
        is_error, second = h.call("scene_snapshot", {"baseline": first["snapshot_id"]})
        assert not is_error, second
        assert second["baseline"] == first["snapshot_id"]
        diff = second["diff"]
        assert diff["added"] == ["Box002"]
        assert [item["name"] for item in diff["modified"]] == ["Box001"]
        assert diff["selection"]["added"] == ["Box002"]
        assert diff["counts"]["after"] == 2
    finally:
        h.close()


def check_snapshot_truncation():
    h = Harness()
    for index in range(3):
        h.scene.add("Box{0:03d}".format(index + 1))
    try:
        is_error, payload = h.call("scene_snapshot", {"limit": 1})
        assert not is_error, payload
        assert payload["node_count"] == 1
        assert payload["truncated"] is True
        assert payload["complete"] is False
        kinds = [item["kind"] for item in payload["warnings"]]
        assert "snapshot_truncated" in kinds
    finally:
        h.close()


def check_rename_is_not_delete_plus_create():
    h = Harness()
    h.scene.add("Wall_Old")
    try:
        is_error, first = h.call("scene_snapshot")
        assert not is_error, first
        h.call("rename_object", {"name": "Wall_Old", "newName": "Wall_New"})
        is_error, second = h.call("scene_snapshot", {"baseline": first["snapshot_id"]})
        assert not is_error, second
        diff = second["diff"]
        assert diff["renamed"] == [{"from": "Wall_Old", "to": "Wall_New",
                                    "handle": second["nodes"]["Wall_New"]["handle"]}]
        assert diff["added"] == [], "a rename must not look like a new object"
        assert diff["removed"] == [], "a rename must not look like a deleted object"
        assert diff["identity_uncertain"] == []
    finally:
        h.close()


def check_rename_without_handle_is_uncertain():
    h = Harness()
    h.scene.add("Prop")
    h.scene.node("Prop")["handle"] = 0       # getHandleByAnim failed inside Max
    try:
        is_error, first = h.call("scene_snapshot")
        assert not is_error, first
        h.call("rename_object", {"name": "Prop", "newName": "Prop_Renamed"})
        is_error, second = h.call("scene_snapshot", {"baseline": first["snapshot_id"]})
        assert not is_error, second
        diff = second["diff"]
        assert diff["renamed"] == []
        assert diff["added"] == ["Prop_Renamed"] and diff["removed"] == ["Prop"]
        uncertain = diff["identity_uncertain"]
        assert len(uncertain) == 1
        assert uncertain[0]["name"] == "Prop_Renamed"
        assert uncertain[0]["reason"] == "handle_missing"
        assert uncertain[0]["candidates"] == ["Prop"]
        assert second["handles_unique"] is False
    finally:
        h.close()


def check_duplicate_names_mark_snapshot_partial():
    h = Harness()
    h.scene.add("Dup")
    h.scene.add("Dup")                       # Max really allows this after a merge
    try:
        is_error, payload = h.call("scene_snapshot")
        assert not is_error, payload
        assert payload["node_count"] == 1
        assert payload["reported_count"] == 2
        assert payload["truncated"] is True
        assert payload["complete"] is False
        assert payload["partial_nodes"] == ["Dup"]
    finally:
        h.close()


# ---------------------------------------------------------------- FAIL: policy
def check_bridge_death_mid_workflow():
    h = Harness()
    h.scene.transport_failure = BridgeDisconnected("bridge closed by test")
    h.scene.fail_after = 6                   # after the first couple of steps
    try:
        is_error, record = workflow(h, "basic_scene")
        assert is_error, "an interrupted workflow is not a success"
        assert record["status"] == "interrupted", record["summary"]
        statuses = [row["status"] for row in record["steps"]]
        assert "interrupted" in statuses
        assert statuses.count("skipped") >= 1
        interrupted = [row for row in record["steps"] if row["status"] == "interrupted"][0]
        # the recovery block was filled in even though the scene is now unreadable
        assert interrupted["recovery"]["attempted"] is True
        assert interrupted["recovery"]["scene_readable"] is False
        assert interrupted["recovery"]["automatic_retry"] is False
        kinds = [item.get("kind") for item in record["failures"]]
        assert "workflow_interrupted" in kinds
        # The step that ran just before the bridge died created its object, but
        # the read-back needed to prove it failed: success, unverified - and the
        # workflow says so instead of claiming the object is verified.
        created_before_death = [row for row in record["steps"]
                                if row["status"] == "success" and row["verified"] is False]
        assert created_before_death, [row["id"] for row in record["steps"]]
        assert created_before_death[0]["verification"]["status"] == "verification_unavailable"
        # The snapshot could not be taken after the failure: the diff is absent,
        # not an empty diff claiming "nothing changed".
        assert record["diff"] is None
        assert [item["kind"] for item in record["warnings"]] == ["snapshot_unavailable"]
    finally:
        h.close()


def check_visual_feedback_missing_is_partial():
    h = Harness()
    h.scene.vision_without_image = True
    try:
        is_error, record = workflow(h, "basic_scene")
        assert not is_error, "scene work succeeded; only the picture is missing"
        assert record["status"] == "partial", record["summary"]
        visual = record["steps"][-1]
        assert visual["id"] == "visual"
        assert visual["status"] == "success"
        assert visual["verified"] is False
        assert visual["verification"]["status"] == "verification_unavailable"
        # the other nine steps are fully verified
        assert record["summary"]["verified"] == 9
        assert record["summary"]["unverified"] == 1
    finally:
        h.close()


def check_non_idempotent_retry_is_refused_through_mcp():
    """A destructive step that dies in transport is never replayed on its own.

    The engine cannot tell whether the clone reached Max before the bridge went
    away, so ``retry: transport`` must not be honoured for it: one attempt, an
    explicit ``retry_blocked`` record, and the rest of the workflow skipped.
    """
    h = Harness()
    h.scene.add("Box001")
    h.scene.transport_failure = BridgeDisconnected("bridge closed by test")
    h.scene.fail_after = 0                   # the bridge is gone from the first call
    try:
        is_error, record = h.call("workflow_run", {
            "capture": False,
            "steps": [
                {"id": "s1", "operation": "clone_objects",
                 "arguments": {"objects": ["Box001"], "count": 1},
                 "verification": {"kind": "exists", "objects": ["Box001_clone1"]},
                 "retry": "transport"},
                {"id": "s2", "operation": "scene_info",
                 "verification": {"kind": "read_ok", "fields": ["objectCount"]}},
            ],
        })
        assert is_error
        row = record["steps"][0]
        assert row["status"] == "interrupted", row
        assert row["attempts"] == 1, "a clone must not be retried automatically"
        assert row["retry_blocked"]["reason"] == "non_idempotent_operation"
        assert row["recovery"]["automatic_retry"] is False
        # The clone was never replayed, so nothing was duplicated.  Here it also
        # never ran at all: the object lookup ahead of it lost the bridge first.
        assert h.scene.calls.count("clone_objects") <= 1
        assert len(h.scene.nodes["Box001"]) == 1, "nothing may be duplicated"
        assert record["steps"][1]["status"] == "skipped"
    finally:
        h.close()



# ----------------------------------------------------------------- META: tools
def check_workflow_listing_and_dry_run():
    h = Harness()
    try:
        is_error, listing = h.call("workflow_run", {})
        assert not is_error, listing
        names = [item["name"] for item in listing["workflows"]]
        assert names == ["basic_scene", "model_processing", "material_look"]

        is_error, plan = h.call("workflow_run", {"workflow": "basic_scene", "dry_run": True})
        assert not is_error, plan
        assert plan["dry_run"] is True
        assert plan["workflow"] == "basic_scene"
        assert plan["problems"] == []
        assert [item["operation"] for item in plan["steps"]][:2] == ["scene_info", "create_plane"]
        assert h.scene.calls == [], "a dry run must not touch the scene"
    finally:
        h.close()


def check_unknown_and_nested_workflow_are_refused():
    h = Harness()
    try:
        # The schema pins the built-in names, so a typo is rejected before any
        # execution and the message repeats the valid ones.
        is_error, payload = h.call("workflow_run", {"workflow": "does_not_exist"})
        assert is_error
        assert payload["error"]["code"] == "invalid_arguments", payload
        assert "basic_scene" in payload["error"]["message"]

        # The catalog enum and the registry must not drift apart, or a workflow
        # could exist and never be callable by name.
        properties = h.server.catalog.get("workflow_run").schema["properties"]
        assert sorted(properties["workflow"]["enum"]) == sorted(STANDARD_WORKFLOWS)

        # The handler keeps its own guard for a name the enum does not know yet.
        guard = h.server._tool_workflow_run({"workflow": "does_not_exist"})
        assert guard["failures"][0]["kind"] == "workflow_unknown"
        assert sorted(guard["failures"][0]["available"]) == [
            "basic_scene", "material_look", "model_processing"]

        is_error, payload = h.call("workflow_run", {"steps": [
            {"id": "s1", "operation": "workflow_run", "arguments": {}}]})
        assert is_error
        assert payload["failures"][0]["kind"] == "workflow_invalid"
        assert "workflow_run" in payload["failures"][0]["message"]

        is_error, payload = h.call("workflow_run", {"steps": [
            {"id": "s1", "operation": "no_such_tool", "arguments": {}}]})
        assert is_error
        assert "unknown operation" in payload["failures"][0]["message"]

        assert h.scene.calls == []
    finally:
        h.close()


def check_custom_steps_and_goal_failure():
    h = Harness()
    try:
        is_error, record = h.call("workflow_run", {
            "expect": {"added_includes": ["Missing"]},
            "steps": [
                {"id": "s1", "operation": "create_box", "arguments": {"name": "Made"},
                 "verification": {"kind": "exists", "objects": ["Made"]}},
            ],
        })
        # the step worked, the advertised goal did not: not a success
        assert is_error, record["status"]
        assert record["status"] == "partial"
        assert record["steps"][0]["status"] == "success"
        assert record["expectation"]["performed"] is True
        assert record["expectation"]["passed"] is False
        assert record["expectation"]["checks"][0]["value"] == "Missing"
    finally:
        h.close()


def check_tolerance_absorbs_float_noise():
    h = Harness()
    h.scene.add("Box001")
    try:
        is_error, first = h.call("scene_snapshot")
        assert not is_error, first
        h.call("transform_object", {"objects": ["Box001"], "operation": "move",
                                    "mode": "relative", "value": [0, 0, 0.000001]})
        is_error, strict = h.call("scene_snapshot", {"baseline": first["snapshot_id"],
                                                    "tolerance": 0.0000001})
        assert [item["name"] for item in strict["diff"]["modified"]] == ["Box001"]
        is_error, loose = h.call("scene_snapshot", {"baseline": first["snapshot_id"],
                                                   "tolerance": 0.001})
        assert loose["diff"]["modified"] == []
    finally:
        h.close()


def check_unknown_baseline_is_rejected():
    h = Harness()
    try:
        is_error, payload = h.call("scene_snapshot", {"baseline": "snap-9999"})
        assert is_error
        assert payload["failures"][0]["kind"] == "invalid_arguments"
        assert "snap-9999" in payload["failures"][0]["message"]
    finally:
        h.close()


def main():
    check_workflow_basic_scene()
    check_workflow_model_processing()
    check_workflow_material_look()
    check_snapshot_and_baseline_diff()
    check_snapshot_truncation()
    check_rename_is_not_delete_plus_create()
    check_rename_without_handle_is_uncertain()
    check_duplicate_names_mark_snapshot_partial()
    check_bridge_death_mid_workflow()
    check_visual_feedback_missing_is_partial()
    check_non_idempotent_retry_is_refused_through_mcp()
    check_workflow_listing_and_dry_run()
    check_unknown_and_nested_workflow_are_refused()
    check_custom_steps_and_goal_failure()
    check_tolerance_absorbs_float_noise()
    check_unknown_baseline_is_rejected()
    print("workflow scene (offline): all checks passed")


if __name__ == "__main__":
    main()
