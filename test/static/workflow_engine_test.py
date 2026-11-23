"""Static tests for the workflow execution model (no TCP, no 3ds Max).

Evidence level: **Static**.  The engine is driven directly with an injected
``invoke`` callable backed by :class:`fake_scene.FakeScene`, so read-back
verification really reads the scene the invoker mutated.  Nothing here is a
3ds Max integration test - the transport tests live in
``workflow_scene_test.py`` (Offline, real TCP).

Scenarios (mirroring the Stage 3 acceptance list):

 1  normal run: every step executes and verifies
 2  mid-step failure aborts the tail (on_failure=abort)
 3  on_failure=continue keeps going
 4  partial success is not success (optional step fails)
 5  a step whose dependency failed is skipped, not run
 6  verification_failed: the tool "succeeded" but the scene disagrees
 7  verification unavailable: unverified, never "passed"
 8  transport failure interrupts the run
 9  non-idempotent operations are never retried automatically
10  read-only operations may be retried on a transport failure
11  malformed definitions are refused before anything runs
12  summary counts are exact
13  a snapshot failure degrades the diff, not the run
14  visual verification distinguishes "no image" from "bad image"
15  recovery re-reads the scene after a failure
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp import workflow as wf  # noqa: E402
from fake_scene import FakeScene  # noqa: E402


# --------------------------------------------------------------------- harness
class Invoker:
    """Bridge FakeScene to the engine's ``invoke`` contract, with fault hooks."""

    def __init__(self, scene=None):
        self.scene = scene if scene is not None else FakeScene()
        self.calls = []
        #: operation -> list of queued outcomes; each is a dict the engine reads
        self.faults = {}
        self.always_fail = {}

    def fail(self, operation, error, times=1):
        queue = self.faults.setdefault(operation, [])
        for _ in range(times):
            queue.append(error)
        return self

    def __call__(self, operation, arguments):
        self.calls.append(operation)
        queue = self.faults.get(operation)
        if queue:
            return {"ok": False, "error": queue.pop(0)}
        if operation in self.always_fail:
            return {"ok": False, "error": self.always_fail[operation]}
        from maxmcp.bridge import BridgeCommandError

        try:
            payload = self.scene.call(operation, arguments or {})
        except BridgeCommandError as exc:
            detail = getattr(exc, "detail", None) or {}
            return {"ok": False, "error": {"kind": detail.get("kind") or "error",
                                           "code": detail.get("kind") or "error",
                                           "message": str(exc)}}
        return {"ok": True, "payload": payload}


TRANSPORT = {"kind": "bridge_disconnected", "code": "bridge_disconnected",
             "message": "connection closed", "retryable": True}


def capture(scene):
    """Minimal snapshot document over the fake scene (nodes only)."""
    return {
        "nodes": {
            name: {"name": name, "handle": node["handle"], "class": node["class"],
                   "position": list(node["position"]), "rotation": list(node["rotation"]),
                   "scale": list(node["scale"]), "material": node["material"],
                   "modifiers": list(node["modifiers"])}
            for name, node in ((key, entries[0]) for key, entries in scene.nodes.items())
        },
        "selection": list(scene.selection),
        "selection_read": True,
        "node_count": sum(len(entries) for entries in scene.nodes.values()),
    }


def step(step_id, operation, arguments=None, verification=None, **extra):
    return {"id": step_id, "operation": operation, "arguments": arguments or {},
            "verification": verification, **extra}


def run(steps, invoker, *, expect=None, capture_scene=True):
    engine = wf.WorkflowEngine(invoker, capture=(capture(invoker.scene) and (lambda: capture(invoker.scene)))
                               if capture_scene else None)
    spec = wf.Workflow.from_dict({"name": "test", "steps": steps, "expect": expect or {}})
    return engine.run(spec)


# ------------------------------------------------------------------- scenarios
def check_normal_run():
    invoker = Invoker()
    record = run([
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
        step("s2", "create_box", {"name": "Box001"},
             {"kind": "exists", "objects": ["Box001"]}, depends_on=["s1"]),
        step("s3", "transform_object",
             {"objects": ["Box001"], "operation": "move", "mode": "absolute", "value": [0, 0, 10]},
             {"kind": "transform", "object": "Box001", "position": [0, 0, 10]},
             depends_on=["s2"]),
    ], invoker)
    assert record["status"] == "success", record
    assert record["summary"] == {"total": 3, "succeeded": 3, "failed": 0, "skipped": 0,
                                 "verification_failed": 0, "interrupted": 0,
                                 "verified": 3, "unverified": 0}
    assert invoker.scene.node("Box001")["position"] == [0, 0, 10]
    assert [row["status"] for row in record["steps"]] == ["success"] * 3


def check_mid_step_failure_aborts_tail():
    invoker = Invoker()
    invoker.fail("create_box", {"kind": "object_not_found", "code": "object_not_found",
                                "message": "cannot create"})
    record = run([
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
        step("s2", "create_box", {"name": "Box001"}, {"kind": "exists", "objects": ["Box001"]},
             depends_on=["s1"]),
        step("s3", "create_box", {"name": "Box002"}, {"kind": "exists", "objects": ["Box002"]},
             depends_on=["s2"]),
    ], invoker)
    assert record["status"] == "failed"
    assert [row["status"] for row in record["steps"]] == ["success", "failed", "skipped"]
    assert record["steps"][2]["skip_reason"] == "aborted_after_failure"
    # the skipped step never reached the invoker
    assert invoker.calls.count("create_box") == 1
    kinds = [item.get("kind") for item in record["failures"]]
    assert "object_not_found" in kinds and "not_attempted" in kinds


def check_continue_policy():
    invoker = Invoker()
    invoker.fail("create_box", {"kind": "invalid_arguments", "code": "invalid_arguments",
                                "message": "bad size"})
    record = run([
        step("s1", "create_box", {"name": "Box001"}, {"kind": "exists", "objects": ["Box001"]},
             on_failure="continue"),
        step("s2", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
    ], invoker)
    assert [row["status"] for row in record["steps"]] == ["failed", "success"]
    assert record["status"] == "failed"


def check_partial_success_is_not_success():
    invoker = Invoker()
    record = run([
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
        # optional step whose goal is not met -> the run is partial, not failed
        step("s2", "find_objects", {"name": "Ghost", "exact": True},
             {"kind": "exists", "objects": ["Ghost"]},
             depends_on=["s1"], optional=True, on_failure="continue"),
    ], invoker)
    assert record["steps"][1]["status"] == "verification_failed"
    assert record["status"] == "partial"
    assert record["summary"]["verification_failed"] == 1
    assert record["summary"]["succeeded"] == 1
    # and it is not reported as a hard failure of the workflow
    assert all(item.get("kind") != "verification_failed" or item.get("step") == "s2"
               for item in record["failures"])


def check_dependency_failure_skips_dependent():
    invoker = Invoker()
    # find_objects answers "0 matches" without an error: the step itself executes,
    # only the goal ("Ghost exists") is unmet - exactly the case a dependency
    # check must catch, because there is no failure code to rely on.
    record = run([
        step("s1", "find_objects", {"name": "Ghost", "exact": True},
             {"kind": "exists", "objects": ["Ghost"]}, on_failure="continue"),
        step("s2", "transform_object",
             {"objects": ["Ghost"], "operation": "move", "value": [0, 0, 1]},
             {"kind": "transform", "object": "Ghost", "position": [0, 0, 1]},
             depends_on=["s1"], on_failure="continue"),
        step("s3", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
    ], invoker)
    assert record["steps"][0]["status"] == "verification_failed"
    assert record["steps"][1]["status"] == "skipped"
    assert record["steps"][1]["skip_reason"] == "dependency_failed"
    assert record["steps"][1]["unmet"] == ["s1"]
    # s3 does not depend on s1, so it still ran
    assert record["steps"][2]["status"] == "success"


def check_verification_failure_when_scene_disagrees():
    invoker = Invoker()
    invoker.scene.add("Box001")
    invoker.scene.ignore_transform = True     # handler answers success, does nothing
    record = run([
        step("s1", "transform_object",
             {"objects": ["Box001"], "operation": "move", "mode": "absolute", "value": [5, 0, 0]},
             {"kind": "transform", "object": "Box001", "position": [5, 0, 0]}),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "verification_failed"
    assert row["execution"] == "execution_success"
    assert row["verification"]["status"] == "verification_failed"
    assert row["verification"]["passed"] is False
    assert record["status"] == "failed"


def check_verification_unavailable_is_not_passed():
    invoker = Invoker()
    record = run([
        step("s1", "scene_info", {"x": 1}, None),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "success"
    assert row["verified"] is False
    assert row["verification"] == {"status": "verification_unavailable",
                                   "performed": False, "passed": None,
                                   "detail": None, "kind": "none", "spec": None}
    # an unverified run may not claim a full success
    assert record["status"] == "partial"
    assert record["summary"]["unverified"] == 1


def check_transport_failure_interrupts():
    invoker = Invoker()
    invoker.fail("create_box", TRANSPORT)
    record = run([
        step("s1", "create_box", {"name": "Box001"}, {"kind": "exists", "objects": ["Box001"]}),
        step("s2", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
        step("s3", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
    ], invoker)
    assert record["status"] == "interrupted"
    assert record["steps"][0]["status"] == "interrupted"
    assert record["steps"][0]["execution"] == "execution_interrupted"
    assert [row["status"] for row in record["steps"][1:]] == ["skipped", "skipped"]
    assert record["steps"][1]["skip_reason"] == "interrupted"
    kinds = [item.get("kind") for item in record["failures"]]
    assert "workflow_interrupted" in kinds


def check_non_idempotent_is_not_retried():
    invoker = Invoker()
    invoker.scene.add("Box001")
    invoker.fail("clone_objects", TRANSPORT)
    record = run([
        step("s1", "clone_objects", {"objects": ["Box001"], "count": 1},
             {"kind": "exists", "objects": ["Box001_clone1"]}, retry="transport"),
    ], invoker)
    row = record["steps"][0]
    assert row["attempts"] == 1, "a clone must never be retried automatically"
    assert row["retry_blocked"]["reason"] == "non_idempotent_operation"
    assert row["retry"][0]["retry"] is False
    assert record["status"] == "interrupted"


def check_read_only_retry_is_allowed():
    invoker = Invoker()
    invoker.fail("scene_info", TRANSPORT, times=1)
    record = run([
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]},
             retry="transport"),
    ], invoker)
    row = record["steps"][0]
    assert row["attempts"] == 2, row
    assert row["status"] == "success"
    assert record["status"] == "success"


def check_invalid_definitions_are_refused():
    invoker = Invoker()
    engine = wf.WorkflowEngine(invoker)

    duplicate = wf.Workflow.from_dict({"name": "d", "steps": [
        step("s1", "scene_info"), step("s1", "scene_info")]})
    record = engine.run(duplicate, known_operations={"scene_info"})
    assert record["status"] == "failed"
    assert record["failures"][0]["kind"] == "workflow_invalid"
    assert "duplicate step id" in record["failures"][0]["message"]

    unknown_op = wf.Workflow.from_dict({"name": "u", "steps": [step("s1", "no_such_tool")]})
    record = engine.run(unknown_op, known_operations={"scene_info"})
    assert "unknown operation" in record["failures"][0]["message"]

    nested = wf.Workflow.from_dict({"name": "n", "steps": [step("s1", "workflow_run")]})
    record = engine.run(nested, known_operations={"workflow_run"})
    assert "may not call workflow_run" in record["failures"][0]["message"]

    broken_verification = wf.Workflow.from_dict({"name": "v", "steps": [
        step("s1", "scene_info", {"k": 1}, {"kind": "telepathy"})]})
    record = engine.run(broken_verification, known_operations={"scene_info"})
    assert "unknown verification kind" in record["failures"][0]["message"]

    assert invoker.calls == [], "a refused definition must not touch the scene"


def check_summary_counts():
    invoker = Invoker()
    invoker.fail("create_box", {"kind": "invalid_arguments", "code": "invalid_arguments",
                                "message": "nope"}, times=2)
    record = run([
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
        step("s2", "scene_info", {"x": 1}, None),
        step("s3", "create_box", {"name": "A"}, {"kind": "exists", "objects": ["A"]},
             on_failure="continue"),
        step("s4", "create_box", {"name": "B"}, {"kind": "exists", "objects": ["B"]},
             on_failure="continue"),
        step("s5", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]}),
    ], invoker)
    summary = record["summary"]
    assert summary["total"] == 5
    assert summary["succeeded"] == 3
    assert summary["failed"] == 2
    assert summary["skipped"] == 0
    assert summary["verified"] == 2
    assert summary["unverified"] == 1


def check_snapshot_failure_degrades_diff_only():
    invoker = Invoker(  )
    invoker.scene.add("Box001")
    engine = wf.WorkflowEngine(invoker, capture=lambda: (_ for _ in ()).throw(RuntimeError("no scene")))
    spec = wf.Workflow.from_dict({"name": "t", "steps": [
        step("s1", "scene_info", verification={"kind": "read_ok", "fields": ["objectCount"]})]})
    record = engine.run(spec)
    assert record["status"] == "success", record
    assert record["diff"] is None
    assert [item["kind"] for item in record["warnings"]] == ["snapshot_unavailable",
                                                            "snapshot_unavailable"]


def check_image_verification_states():
    invoker = Invoker()

    def with_images(operation, arguments):
        payload = invoker.scene.call(operation, arguments)
        # Mirror the server's image split: descriptors exist only when the
        # bridge really produced image bytes.
        images = ([{"label": "perspective", "mimeType": "image/png", "base64Chars": 80}]
                  if isinstance(payload, dict) and payload.get("_images") else [])
        return {"ok": True, "payload": payload, "images": images}

    engine = wf.WorkflowEngine(with_images, capture=None)
    good = engine.run(wf.Workflow.from_dict({"name": "i", "steps": [
        step("s1", "vision_capture", {"max_edge": 320}, {"kind": "image"})]}))
    assert good["steps"][0]["status"] == "success"
    assert good["steps"][0]["verified"] is True

    invoker.scene.vision_without_image = True
    missing = engine.run(wf.Workflow.from_dict({"name": "i", "steps": [
        step("s1", "vision_capture", {"max_edge": 320}, {"kind": "image"})]}))
    row = missing["steps"][0]
    assert row["verification"]["performed"] is False
    assert row["verification"]["passed"] is None
    assert row["status"] == "success" and row["verified"] is False

    bad = wf.WorkflowEngine(
        lambda op, args: {"ok": True, "payload": {}, "images": [],
                          "image_errors": [{"label": "perspective", "error": "corrupt_image"}]},
        capture=None).run(wf.Workflow.from_dict({"name": "i", "steps": [
            step("s1", "vision_capture", {}, {"kind": "image"})]}))
    row = bad["steps"][0]
    assert row["verification"]["passed"] is False
    assert row["verification"]["detail"]["reason"] == "image_unusable"


def check_recovery_reads_the_scene():
    invoker = Invoker()
    invoker.scene.add("Box001")
    invoker.fail("delete_objects", {"kind": "max_runtime_error", "code": "max_runtime_error",
                                    "message": "locked node"})
    record = run([
        step("s1", "delete_objects", {"objects": ["Box001"]}, {"kind": "absent", "objects": ["Box001"]}),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "failed"
    recovery = row["recovery"]
    assert recovery["attempted"] is True
    assert recovery["scene_readable"] is True
    assert recovery["object_count"] == 1
    assert recovery["automatic_retry"] is False


def check_recovery_diagnosis():
    """A failure has to say *why* the scene could not be re-read.

    "The bridge vanished" is worth a reconnect; "the scene does not answer" is
    not.  Reporting both as a null object count left the caller guessing.
    """
    # 1. scene readable: the step ran, the goal was not met
    invoker = Invoker()
    record = run([
        step("s1", "create_box", {"name": "Box001"},
             {"kind": "exists", "objects": ["Ghost"]}),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "verification_failed"
    assert row["recovery"]["diagnosis"] == "scene_readable"
    assert row["recovery"]["scene_readable"] is True
    assert row["recovery"]["object_count"] == 1
    assert row["recovery"]["suggest_actions"] == ["get_object_info"]
    assert "read_error" not in row["recovery"]

    # 2. bridge unreachable: transport failure while reading back
    invoker = Invoker()
    invoker.scene.add("Box001")
    invoker.always_fail["transform_object"] = TRANSPORT
    invoker.always_fail["scene_info"] = TRANSPORT
    record = run([
        step("s1", "transform_object", {"objects": ["Box001"], "operation": "move",
                                        "mode": "relative", "value": [0, 0, 1]}),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "interrupted", row["status"]
    recovery = row["recovery"]
    assert recovery["diagnosis"] == "bridge_unreachable"
    assert recovery["scene_readable"] is False
    assert recovery["object_count"] is None
    assert recovery["suggest_actions"] == ["bridge_status", "bridge_selftest"]
    assert recovery["read_error"]["kind"] == "bridge_disconnected"
    assert recovery["automatic_retry"] is False

    # 3. bridge answers, the scene cannot be read: a different problem
    invoker = Invoker()
    invoker.always_fail["scene_info"] = {"kind": "err.unknown", "code": "err.unknown",
                                         "message": "scene_info broke"}
    record = run([
        step("s1", "create_box", {"name": "Box001"},
             {"kind": "exists", "objects": ["Ghost"]}),
    ], invoker)
    row = record["steps"][0]
    assert row["status"] == "verification_failed", row["status"]
    recovery = row["recovery"]
    assert recovery["diagnosis"] == "scene_unreadable"
    assert recovery["suggest_actions"] == ["bridge_selftest"]
    assert recovery["read_error"]["kind"] == "err.unknown"


def check_validation_rejects_bad_input():
    for raw in ({}, {"steps": []}, {"steps": [{"operation": ""}]},
                {"steps": [{"id": "s1", "operation": "scene_info", "arguments": 5}]},
                {"steps": [{"id": "s1", "operation": "scene_info", "on_failure": "explode"}]}):
        try:
            wf.Workflow.from_dict(raw)
        except ValueError:
            continue
        raise AssertionError("expected ValueError for {0!r}".format(raw))


def check_standard_workflow_definitions():
    names = sorted(wf.STANDARD_WORKFLOWS)
    assert names == ["asset_layout", "basic_scene", "material_look", "model_processing"]
    for name, spec in wf.STANDARD_WORKFLOWS.items():
        problems = wf.validate(spec, None)
        assert problems == [], (name, problems)
        # every step must declare a real verification: "it ran" is not a goal
        for item in spec.steps:
            assert item.verify and item.verify.get("kind"), (name, item.id)
        assert spec.expect, name


def main():
    check_normal_run()
    check_mid_step_failure_aborts_tail()
    check_continue_policy()
    check_partial_success_is_not_success()
    check_dependency_failure_skips_dependent()
    check_verification_failure_when_scene_disagrees()
    check_verification_unavailable_is_not_passed()
    check_transport_failure_interrupts()
    check_non_idempotent_is_not_retried()
    check_read_only_retry_is_allowed()
    check_invalid_definitions_are_refused()
    check_summary_counts()
    check_snapshot_failure_degrades_diff_only()
    check_image_verification_states()
    check_recovery_reads_the_scene()
    check_recovery_diagnosis()
    check_validation_rejects_bad_input()
    check_standard_workflow_definitions()
    print("workflow engine (static): all checks passed")


if __name__ == "__main__":
    main()
