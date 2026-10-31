"""Offline tests for object identity: ambiguity, staleness, renames, deletes.

The rules under test (stage D):

* a name is resolved against a real scene read before anything is executed;
* two objects with the same name produce ``ambiguous_object``, never "first match";
* an object deleted or renamed between two operations produces a stale-reference
  style error instead of silently editing a different node;
* numeric handles are refused rather than trusted as durable ids.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp.batch import BatchExecutor  # noqa: E402
from maxmcp.runtime import resolve_object_refs  # noqa: E402

from fake_scene import FakeScene  # noqa: E402


def run(scene, tool, params, method=None):
    return BatchExecutor(scene.call).run(tool, method or tool, params)


def check_duplicate_names_are_ambiguous():
    scene = FakeScene()
    scene.add("Dup")
    scene.add("Dup")
    payload = run(scene, "delete_objects", {"objects": ["Dup"]})
    row = payload["objects"][0]
    assert row["error"]["kind"] == "ambiguous_object"
    assert len(scene.nodes["Dup"]) == 2, "neither duplicate may be touched"
    assert row["success"] is False


def check_deleted_object_between_operations():
    scene = FakeScene()
    scene.add("Box001")
    first = run(scene, "delete_objects", {"objects": ["Box001"]})
    assert first["success"] is True
    second = run(scene, "transform_object",
                 {"objects": ["Box001"], "operation": "move", "value": [0, 0, 1]})
    row = second["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "object_not_found"
    # nothing was created/edited by the failed second call
    assert scene.nodes == {}


def check_rename_invalidates_reference():
    scene = FakeScene()
    scene.add("Box001")
    original = scene.call

    def call(method, params=None):
        result = original(method, params)
        if method == "find_objects":
            # simulate a rename happening right after the resolution read
            entries = scene.nodes.pop("Box001", [])
            for entry in entries:
                entry["name"] = "Box001_renamed"
                scene.nodes.setdefault("Box001_renamed", []).append(entry)
        return result

    payload = BatchExecutor(call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001"], "operation": "move", "value": [0, 0, 1]})
    row = payload["objects"][0]
    assert row["success"] is False
    # the name resolved one statement earlier, so the failure is a stale
    # reference rather than a typo in the request
    assert row["error"]["kind"] == "stale_object_reference", row
    assert scene.node("Box001_renamed") is not None
    assert scene.node("Box001_renamed")["position"] == [0.0, 0.0, 0.0], \
        "the renamed object must not be edited through the stale name"


def check_handle_only_reference_rejected():
    scene = FakeScene()
    scene.add("Box001")
    handle = scene.node("Box001")["handle"]
    payload = run(scene, "transform_object",
                  {"objects": [handle], "operation": "move", "value": [0, 0, 1]})
    row = payload["objects"][0]
    assert row["success"] is False
    assert row["error"]["kind"] == "invalid_object_reference"
    assert scene.node("Box001")["position"] == [0.0, 0.0, 0.0]


def check_dict_reference_without_name():
    scene = FakeScene()
    scene.add("Box001")
    payload = run(scene, "transform_object",
                  {"objects": [{"object_ref": {"handle": 7}}],
                   "operation": "move", "value": [0, 0, 1]})
    row = payload["objects"][0]
    assert row["error"]["kind"] == "invalid_object_reference"
    assert "handle" in row["error"]["message"]


def check_resolver_contract():
    available = [
        {"name": "Box001", "handle": 1},
        {"name": "Dup", "handle": 2},
        {"name": "Dup", "handle": 3},
    ]
    rows = resolve_object_refs(["Box001", "Dup", "Gone", "", {"name": "Box001"}], available)
    assert [row["success"] for row in rows] == [True, False, False, False, True]
    assert rows[1]["error"]["kind"] == "ambiguous_object"
    assert rows[1]["error"]["candidates"] == 2
    assert rows[2]["error"]["kind"] == "stale_object_reference"
    assert rows[3]["error"]["kind"] == "invalid_object_reference"
    assert rows[4]["object_ref"] == {"name": "Box001", "handle": 1}


def check_selection_is_not_a_fallback_for_named_requests():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    scene.selection = ["Box002"]
    payload = run(scene, "transform_object",
                  {"objects": ["Box001"], "operation": "move", "value": [0, 0, 1]})
    assert payload["success"] is True
    assert scene.node("Box001")["position"][2] == 1.0
    assert scene.node("Box002")["position"] == [0.0, 0.0, 0.0], \
        "only the named object may move, never the selection"


def main():
    check_duplicate_names_are_ambiguous()
    check_deleted_object_between_operations()
    check_rename_invalidates_reference()
    check_handle_only_reference_rejected()
    check_dict_reference_without_name()
    check_resolver_contract()
    check_selection_is_not_a_fallback_for_named_requests()
    print("object reference: all checks passed")


if __name__ == "__main__":
    main()
