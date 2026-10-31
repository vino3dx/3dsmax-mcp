"""Focused tests for the transport-independent Scene Runtime envelope."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.runtime import SceneRuntime


def main() -> None:
    calls = []
    state = [{"objectCount": 0}, {"objectCount": 1}]

    def bridge(method, params):
        calls.append((method, params))
        if method == "scene_info":
            return state.pop(0)
        return {"created": True}

    runtime = SceneRuntime(bridge)
    record = runtime.execute(
        "create_box", "create_box", {"class": "Box"},
    )
    assert record.success is True
    assert record.operation_id.startswith("op-")
    assert record.changed is True
    assert record.verification.passed is True
    assert record.verification.performed is True
    assert record.verification.detail["kind"] == "object_count"
    assert [item[0] for item in calls] == ["scene_info", "create_box", "scene_info"]

    reported_failure = SceneRuntime(lambda method, params: (
        {"objectCount": 0} if method == "scene_info" else {"success": False, "message": "rejected"}
    )).execute("create_box", "create_box")
    assert reported_failure.success is False
    assert reported_failure.failures[0]["kind"] == "operation_failed"

    verification_failure = SceneRuntime(lambda method, params: {"objectCount": 1}).execute(
        "create_box", "create_box", verify=lambda result, before, after: False
    )
    assert verification_failure.success is False
    assert verification_failure.failures[0]["kind"] == "verification_failed"

    material = SceneRuntime(lambda method, params: {"objectCount": 1}).execute(
        "create_material", "create_material"
    )
    assert material.success is True
    assert material.verification.performed is False

    unchanged = SceneRuntime(lambda method, params: {"objectCount": 1})
    same = unchanged.execute("noop", "noop")
    assert same.success is True
    assert same.changed is False

    failed = SceneRuntime(lambda method, params: (_ for _ in ()).throw(RuntimeError("offline")))
    error = failed.execute("create_box", "create_box")
    assert error.success is False
    assert error.failures[0]["kind"] == "bridge_error"

    recovery_ids = []
    recovery_calls = {"count": 0}
    def partial(method, params):
        if method == "scene_info":
            return {"objectCount": 0}
        recovery_calls["count"] += 1
        raise RuntimeError("operation failed")
    recovered = SceneRuntime(partial).execute(
        "create_box", "create_box", recover=recovery_ids.append
    )
    assert recovered.success is False
    assert recovered.recovery["attempted"] is True
    assert recovered.recovery["passed"] is True
    assert recovery_ids == [recovered.operation_id]
    print("scene runtime: all checks passed")


if __name__ == "__main__":
    main()
