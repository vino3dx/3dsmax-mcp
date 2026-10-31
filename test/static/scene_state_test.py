"""Offline tests for scene snapshots and before/after diffs (stage F)."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp import scene_state as state  # noqa: E402


def node(name="Box001", position=None, rotation=None, scale=None, material="", modifiers=None):
    return {
        "name": name,
        "handle": 42,
        "class": "Box",
        "position": position or [0.0, 0.0, 0.0],
        "rotation": rotation or [0.0, 0.0, 0.0],
        "scale": scale or [1.0, 1.0, 1.0],
        "material": material,
        "modifiers": modifiers or [],
    }


def check_snapshot_fields():
    snap = state.node_snapshot(node())
    assert snap["complete"] is True
    assert snap["missing"] == []
    assert snap["name"] == "Box001" and snap["handle"] == 42
    assert set(state.SNAPSHOT_FIELDS) <= set(snap)

    # A field the running Max did not report must be marked missing, never
    # interpreted as "the object does not have it".
    partial = dict(node())
    partial.pop("modifiers")
    snap = state.node_snapshot(partial)
    assert snap["complete"] is False
    assert snap["missing"] == ["modifiers"]
    assert "modifiers" not in snap

    assert state.node_snapshot(None) is None
    assert state.node_snapshot("Box001") is None


def check_snapshot_collection():
    payload = {"count": 2, "objects": [node("Box001"), node("Sphere001")]}
    snapshots = state.snapshot_nodes(payload)
    assert sorted(snapshots) == ["Box001", "Sphere001"]
    assert state.snapshot_nodes({"count": 0, "objects": []}) == {}
    assert state.snapshot_nodes(None) == {}


def check_diff():
    before = state.snapshot_nodes({"objects": [
        node("Box001", position=[0, 0, 0]),
        node("Box002", material="Red"),
        node("Gone"),
    ]})
    after = state.snapshot_nodes({"objects": [
        node("Box001", position=[0, 0, 10]),
        node("Box002", material="Blue"),
        node("New"),
    ]})
    diff = state.diff_snapshots(before, after)
    assert diff["added"] == ["New"]
    assert diff["removed"] == ["Gone"]
    assert [item["name"] for item in diff["modified"]] == ["Box001", "Box002"]
    box = diff["modified"][0]["fields"]
    assert box["position"] == {"before": [0, 0, 0], "after": [0, 0, 10]}
    assert diff["complete"] is True
    assert diff["unknown"] == []
    assert diff["counts"] == {"before": 3, "after": 3, "changed": 4}


def check_diff_marks_unreadable_fields():
    partial = dict(node("Box001"))
    partial.pop("modifiers")
    before = state.snapshot_nodes({"objects": [partial]})
    after = state.snapshot_nodes({"objects": [node("Box001")]})
    diff = state.diff_snapshots(before, after)
    assert diff["complete"] is False
    assert diff["unknown"] == [{"name": "Box001", "fields": ["modifiers"]}]
    # an unread field is not a change
    assert diff["modified"] == []


def check_transform_delta_and_tolerance():
    before = state.node_snapshot(node(position=[0, 0, 0]))
    after = state.node_snapshot(node(position=[0.00001, 0, 0]))
    assert state.transform_delta(before, after) == {}
    moved = state.node_snapshot(node(position=[1, 0, 0]))
    delta = state.transform_delta(before, moved)
    assert list(delta) == ["position"]


def check_absolute_comparison():
    assert state.compare_absolute("position", [1, 2, 3], [1, 2, 3]) is True
    assert state.compare_absolute("position", [1, 2, 3], [1, 2, 3.01]) is False
    # euler wrap-around: 359 and -1 are the same orientation
    assert state.compare_absolute("rotation", [0, 0, 359], [0, 0, -1]) is True
    assert state.compare_absolute("scale", [1, 1, 1], [1, 1, 2]) is False
    # incomparable input stays "unknown" instead of guessing
    assert state.compare_absolute("position", None, [1, 2, 3]) is None
    assert state.compare_absolute("position", [1, 2], [1, 2, 3]) is None


def check_summary():
    snapshots = [state.node_snapshot(node("Box001")), state.node_snapshot(node("Sphere001", ))]
    summary = state.summarize(snapshots)
    assert summary["count"] == 2
    assert summary["names"] == ["Box001", "Sphere001"]
    assert summary["complete"] is True


def main():
    check_snapshot_fields()
    check_snapshot_collection()
    check_diff()
    check_diff_marks_unreadable_fields()
    check_transform_delta_and_tolerance()
    check_absolute_comparison()
    check_summary()
    print("scene state: all checks passed")


if __name__ == "__main__":
    main()
