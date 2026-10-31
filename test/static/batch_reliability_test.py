"""Offline tests for per-object batch execution and reconciliation.

Every case runs against ``fake_scene.FakeScene``, which speaks the same commands
as the MAXScript handlers and mutates real state, so the assertions below are
about *behaviour* (did Box002 move? was a missing name reported per object?)
rather than about the shape of a hard-coded mock.
"""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp.batch import BatchExecutor, PER_OBJECT_TOOLS, RECONCILE_TOOLS  # noqa: E402
from maxmcp.bridge import BridgeNotRunning, BridgeTimeout  # noqa: E402
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

from fake_scene import FakeScene  # noqa: E402


def rows_by_name(payload):
    return {row["name"]: row for row in payload["objects"]}


def check_transform_partial():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    executor = BatchExecutor(scene.call)
    payload = executor.run(
        "transform_object", "transform_object",
        {"objects": ["Box001", "Box002", "Ghost"], "operation": "move",
         "value": [0, 0, 10], "mode": "relative"},
    )
    assert payload["success"] is False, payload
    assert payload["summary"] == {"total": 3, "succeeded": 2, "failed": 1,
                                 "skipped": 0, "verified": 2}, payload["summary"]
    assert [row["name"] for row in payload["objects"]] == ["Box001", "Box002", "Ghost"]
    rows = rows_by_name(payload)
    assert rows["Box001"]["success"] is True and rows["Box001"]["changed"] is True
    assert rows["Box001"]["verified"] is True
    assert rows["Box001"]["object_ref"]["handle"] == scene.node("Box001")["handle"]
    assert rows["Ghost"]["success"] is False
    assert rows["Ghost"]["error"]["kind"] == "object_not_found"
    # the two existing objects really moved, the missing one never ran
    assert scene.node("Box001")["position"][2] == 10.0
    assert scene.node("Box002")["position"][2] == 10.0
    # overall verdict must not claim verification passed for the whole batch
    assert payload["verification"]["performed"] is True
    assert payload["verification"]["passed"] is None
    assert any(item["kind"] == "partial_success" for item in payload["failures"])


def check_transform_single_and_stats():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [1, 2, 3], "mode": "relative"},
    )
    assert payload["success"] is True
    assert payload["summary"]["total"] == 1 and payload["summary"]["succeeded"] == 1
    assert payload["verification"] == {
        "performed": True, "passed": True,
        "detail": {"verified": 1, "unverified": 0, "scope": "objects", "mode": "per_object"},
    }, payload["verification"]
    assert payload["changed"] is True


def check_all_failed():
    scene = FakeScene()
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Ghost1", "Ghost2"], "operation": "move", "value": [0, 0, 1]},
    )
    assert payload["success"] is False
    assert payload["summary"]["succeeded"] == 0 and payload["summary"]["failed"] == 2
    assert [item["kind"] for item in payload["failures"]] == ["batch_failed"]
    assert all(row["error"]["kind"] == "object_not_found" for row in payload["objects"])
    assert payload["verification"]["performed"] is False
    assert payload["verification"]["passed"] is None


def check_empty_objects_scope():
    scene = FakeScene()
    scene.add("Box001")
    scene.selection = ["Box001"]
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": [], "operation": "move", "value": [0, 0, 5]},
    )
    assert payload["scope"] == "selection"
    assert payload["objects"] == []
    assert payload["success"] is True
    assert payload["verification"]["performed"] is False
    assert payload["warnings"][0]["kind"] == "selection_scope"
    # the legacy selection semantics are untouched: the box still moved
    assert scene.node("Box001")["position"][2] == 5.0


def check_duplicate_request():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001", "Box001"], "operation": "move", "value": [0, 0, 1],
         "mode": "relative"},
    )
    assert payload["success"] is True
    assert payload["summary"]["total"] == 1
    assert payload["warnings"][0]["kind"] == "duplicate_object_in_request"
    # executed once, so the box moved exactly one unit
    assert scene.node("Box001")["position"][2] == 1.0


def check_ambiguous_names():
    scene = FakeScene()
    scene.add("Dup")
    scene.add("Dup")  # 3ds Max allows duplicate node names
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Dup"], "operation": "move", "value": [0, 0, 1]},
    )
    row = payload["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "ambiguous_object"
    assert "transform_object" not in scene.calls, scene.calls
    assert scene.node("Dup")["position"] == [0.0, 0.0, 0.0]


def check_stale_reference():
    scene = FakeScene()
    scene.add("Box001")

    original = scene.call

    def call(method, params=None):
        # the object disappears after the resolution read and before execution
        if method == "transform_object":
            scene.nodes.pop("Box001", None)
        return original(method, params)

    payload = BatchExecutor(call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [0, 0, 1]},
    )
    row = payload["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "stale_object_reference", row


def check_transport_abort():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    scene.add("Box003")

    original = scene.call
    executed = []

    def call(method, params=None):
        if method == "transform_object":
            executed.append(params["objects"][0])
            if len(executed) == 2:
                raise BridgeTimeout("no reply from Max")
        return original(method, params)

    payload = BatchExecutor(call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001", "Box002", "Box003"], "operation": "move", "value": [0, 0, 1]},
    )
    rows = rows_by_name(payload)
    assert rows["Box001"]["success"] is True
    assert rows["Box002"]["error"]["kind"] == "bridge_timeout"
    assert rows["Box003"]["skipped"] is True
    assert rows["Box003"]["error"]["kind"] == "not_attempted"
    assert executed == ["Box001", "Box002"], executed
    assert payload["summary"]["skipped"] == 1
    assert any(item["kind"] == "aborted" for item in payload["failures"])


def check_delete():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Locked")
    scene.undeletable = {"Locked"}
    payload = BatchExecutor(scene.call).run(
        "delete_objects", "delete_objects", {"objects": ["Box001", "Locked"]})
    rows = rows_by_name(payload)
    assert rows["Box001"]["success"] is True and rows["Box001"]["verified"] is True
    assert rows["Box001"]["readback"] == {"exists": False}
    assert rows["Locked"]["success"] is False
    assert rows["Locked"]["error"]["kind"] == "not_deleted"
    assert payload["success"] is False and payload["summary"]["failed"] == 1


def check_clone():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "clone_objects", "clone_objects", {"objects": ["Box001"], "count": 2})
    row = payload["objects"][0]
    assert row["success"] is True and row["verified"] is True
    assert row["readback"]["created_checked"] == 2
    assert row["readback"]["missing"] == []
    assert sorted(row["created"]) == ["Box001_clone1", "Box001_clone2"]


def check_clone_reported_but_missing():
    scene = FakeScene()
    scene.add("Box001")
    original = scene.call

    def call(method, params=None):
        if method == "clone_objects":
            return {"created": ["GhostClone"], "count": 1}
        return original(method, params)

    row = BatchExecutor(call).run(
        "clone_objects", "clone_objects", {"objects": ["Box001"]})["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "verification_failed"
    assert row["readback"]["missing"] == ["GhostClone"]


def check_transform_no_effect():
    scene = FakeScene()
    scene.add("Box001")
    scene.ignore_transform = True
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [0, 0, 4]},
    )
    row = payload["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "no_effect", row
    assert row["changed"] is False
    assert payload["verification"]["passed"] is False


def check_transform_absolute_mismatch():
    scene = FakeScene()
    scene.add("Box001")
    scene.ignore_transform = True
    row = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [5, 0, 0], "mode": "absolute"},
    )["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "no_effect"


def check_transform_absolute_ok():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [5, 6, 7], "mode": "absolute"},
    )
    assert payload["success"] is True and payload["verification"]["passed"] is True
    assert scene.node("Box001")["position"] == [5.0, 6.0, 7.0]


def check_relative_zero_is_not_a_failure():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [0, 0, 0]},
    )
    assert payload["success"] is True, payload
    assert payload["objects"][0]["changed"] is False


def check_mat_assign_reconcile():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    scene.skip_assign = {"Box002"}
    payload = BatchExecutor(scene.call).run(
        "mat_assign", "mat_assign", {"objects": ["Box001", "Box002"], "material": "Red"})
    rows = rows_by_name(payload)
    assert rows["Box001"]["success"] is True
    assert rows["Box002"]["success"] is False
    assert rows["Box002"]["error"]["kind"] == "not_applied"
    assert payload["success"] is False
    assert payload["changed"] is None  # nothing was read back to prove a change
    assert len([call for call in scene.calls if call == "mat_assign"]) == 1


def check_mod_add_reconcile_reports_max_failures():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    scene.skip_assign = {"Box002"}
    payload = BatchExecutor(scene.call).run(
        "mod_add", "mod_add", {"objects": ["Box001", "Box002"], "modifier": "Bend"})
    rows = rows_by_name(payload)
    assert rows["Box001"]["success"] is True and rows["Box001"]["changed"] is True
    assert rows["Box002"]["success"] is False
    assert rows["Box002"]["error"]["message"] == "modifier rejected"
    assert payload["summary"] == {"total": 2, "succeeded": 1, "failed": 1,
                                 "skipped": 0, "verified": 2}


def check_select_reconcile():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    payload = BatchExecutor(scene.call).run(
        "select_objects", "select_objects", {"objects": ["Box001", "Box002"], "mode": "replace"})
    assert payload["success"] is True
    assert payload["verification"] == {
        "performed": True, "passed": True,
        "detail": {"verified": 2, "unverified": 0, "scope": "objects", "mode": "reconcile"},
    }, payload["verification"]

    # Max silently drops the missing name: the batch must not report success for it
    partial = BatchExecutor(scene.call).run(
        "select_objects", "select_objects", {"objects": ["Box001", "Ghost"], "mode": "add"})
    rows = rows_by_name(partial)
    assert rows["Box001"]["success"] is True
    assert rows["Ghost"]["success"] is False
    assert rows["Ghost"]["error"]["kind"] == "not_applied"
    assert partial["success"] is False


def check_reconcile_unavailable_is_not_a_failure():
    """An unknown reply shape must not be reported as a per-object failure."""
    scene = FakeScene()
    scene.add("Box001")
    original = scene.call

    def call(method, params=None):
        if method in ("mat_assign", "select_objects"):
            return {"message": "Done."}  # no applied list / no selection list
        return original(method, params)

    executor = BatchExecutor(call)
    mat = executor.run("mat_assign", "mat_assign", {"objects": ["Box001"], "material": "Red"})
    row = mat["objects"][0]
    assert row["success"] is True and row["verified"] is False
    assert mat["warnings"][-1]["kind"] == "reconcile_unavailable"
    assert mat["verification"]["performed"] is False

    selection = executor.run("select_objects", "select_objects", {"objects": ["Box001"]})
    assert selection["objects"][0]["verified"] is False
    assert selection["warnings"][-1]["kind"] == "reconcile_unavailable"
    assert selection["success"] is True


def check_select_invert_not_verified():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "select_objects", "select_objects", {"objects": ["Box001"], "mode": "invert"})
    assert payload["verification"]["performed"] is False
    assert payload["verification"]["passed"] is None


def check_batch_call_failure_reconcile():
    scene = FakeScene()
    scene.add("Box001")
    scene.transport_failure = BridgeNotRunning("bridge unavailable")
    payload = BatchExecutor(scene.call).run(
        "mat_assign", "mat_assign", {"objects": ["Box001"], "material": "Red"})
    assert payload["success"] is False
    assert payload["objects"][0]["error"]["kind"] == "bridge_not_running"
    assert payload["objects"][0]["error"]["retryable"] is True


def check_invalid_references():
    scene = FakeScene()
    scene.add("Box001")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["", {"handle": 123}, 456, {"name": "Box001"}],
         "operation": "move", "value": [0, 0, 2]},
    )
    rows = payload["objects"]
    assert [row["success"] for row in rows] == [False, False, False, True]
    assert all(row["error"]["kind"] == "invalid_object_reference" for row in rows[:3])
    assert payload["summary"]["succeeded"] == 1


def check_tool_sets():
    assert "transform_object" in PER_OBJECT_TOOLS
    assert "clone_objects" in PER_OBJECT_TOOLS
    assert "delete_objects" in PER_OBJECT_TOOLS
    assert RECONCILE_TOOLS == {"select_objects", "mat_assign", "mod_add"}


def check_server_integration():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")

    server = MaxMcpServer(Config(tool_profile="core", language="en"), NullTransport())
    server.bridge = scene
    server.runtime = type(server.runtime)(scene.call)
    server.batch = BatchExecutor(scene.call)

    ok = server.on_tools_call({
        "name": "transform_object",
        "arguments": {"objects": ["Box001", "Box002"], "operation": "move", "value": [0, 0, 3]},
    })
    payload = json.loads(ok["content"][0]["text"])
    assert ok.get("isError", False) is False
    assert payload["success"] is True and payload["summary"]["succeeded"] == 2
    assert payload["verification"]["passed"] is True

    bad = server.on_tools_call({
        "name": "transform_object",
        "arguments": {"objects": ["Box001", "Ghost"], "operation": "move", "value": [0, 0, 3]},
    })
    assert bad["isError"] is True
    payload = json.loads(bad["content"][0]["text"])
    assert payload["success"] is False
    assert payload["summary"]["failed"] == 1

    # validation errors are distinguished from bridge errors
    invalid = server.on_tools_call({
        "name": "transform_object",
        "arguments": {"objects": ["Box001"], "operation": "fly", "value": [0, 0, 3]},
    })
    assert invalid["isError"] is True
    error = json.loads(invalid["content"][0]["text"])["error"]
    assert error["code"] == "invalid_arguments"
    assert "operation" in error["message"]


def main():
    check_transform_partial()
    check_transform_single_and_stats()
    check_all_failed()
    check_empty_objects_scope()
    check_duplicate_request()
    check_ambiguous_names()
    check_stale_reference()
    check_transport_abort()
    check_delete()
    check_clone()
    check_clone_reported_but_missing()
    check_transform_no_effect()
    check_transform_absolute_mismatch()
    check_transform_absolute_ok()
    check_relative_zero_is_not_a_failure()
    check_mat_assign_reconcile()
    check_mod_add_reconcile_reports_max_failures()
    check_select_reconcile()
    check_reconcile_unavailable_is_not_a_failure()
    check_select_invert_not_verified()
    check_batch_call_failure_reconcile()
    check_invalid_references()
    check_tool_sets()
    check_server_integration()
    print("batch reliability: all checks passed")


if __name__ == "__main__":
    main()
