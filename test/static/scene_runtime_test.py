"""Focused tests for the transport-independent Scene Runtime envelope."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.runtime import SceneRuntime


def main() -> None:
    calls = []
    state = [{"objects": 0}, {"objects": 1}]

    def bridge(method, params):
        calls.append((method, params))
        if method == "scene_info":
            return state.pop(0)
        return {"created": True}

    runtime = SceneRuntime(bridge)
    record = runtime.execute(
        "create_box", "create_box", {"class": "Box"},
        verify=lambda result, before, after: before["objects"] + 1 == after["objects"],
    )
    assert record.success is True
    assert record.operation_id.startswith("op-")
    assert record.changed is True
    assert record.verification.passed is True
    assert [item[0] for item in calls] == ["scene_info", "create_box", "scene_info"]

    unchanged = SceneRuntime(lambda method, params: {"objects": 1})
    same = unchanged.execute("noop", "noop")
    assert same.success is True
    assert same.changed is False

    failed = SceneRuntime(lambda method, params: (_ for _ in ()).throw(RuntimeError("offline")))
    error = failed.execute("create_box", "create_box")
    assert error.success is False
    assert error.failures[0]["kind"] == "bridge_error"
    print("scene runtime: all checks passed")


if __name__ == "__main__":
    main()
