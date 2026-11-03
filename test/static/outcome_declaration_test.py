"""Static tests for reading a handler's own outcome declaration.

The reliability layer has one rule: an operation is not successful unless the
handler said what it did.  These checks pin down *how* that sentence is read, so
that neither of the two historical mistakes comes back:

* reading only ``success``/``ok``, which reports a working ``{applied, failures}``
  handler as a failure (Stage 3);
* reading anything present, which turns ``{message: "Operation failed"}`` into a
  success (the mistake this file exists to prevent).

Everything here is pure Python - no bridge, no Max.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.runtime import declared_outcome, normalize_payload  # noqa: E402


def verdict(payload):
    """``(success, via)`` or ``None`` when the payload declares nothing."""
    return declared_outcome(payload)


def check_explicit_flags_win():
    assert verdict({"success": True, "failures": ["ignored"]}) == (True, "success")
    assert verdict({"success": False}) == (False, "success")
    assert verdict({"ok": True}) == (True, "ok")
    assert verdict({"ok": False, "objects": ["Box001"]}) == (False, "ok")


def check_failure_list_is_read_first():
    assert verdict({"failures": [], "applied": ["Box001"]}) == (True, "failures")
    assert verdict({"failures": ["Box001: boom"], "applied": []}) == (False, "failures")
    # A per-object failure list may hold plain strings rather than error objects;
    # it still decides the outcome.
    assert verdict({"failures": ["Box001: boom"]}) == (False, "failures")


def check_enumeration_decides():
    for key in ("applied", "deleted", "created", "objects", "results"):
        assert verdict({key: ["Box001"]}) == (True, key), key
        assert verdict({key: []}) == (False, key), key
        # The same key is a boolean in some handlers (scene_new: created,
        # delete_file: deleted).  Reading only the list form made those answer
        # missing_success after doing the work.
        assert verdict({key: True}) == (True, key), key
        assert verdict({key: False}) == (False, key), key


def check_receipt_fields_decide():
    # A path / name receipt: present and non-empty means it happened.
    assert verdict({"saved": "C:/work/a.max"}) == (True, "saved")
    assert verdict({"opened": "C:/work/a.max"}) == (True, "opened")
    assert verdict({"merged": "C:/work/b.max"}) == (True, "merged")
    assert verdict({"group": "Group001"}) == (True, "group")
    assert verdict({"layer": "Layer01"}) == (True, "layer")
    # A boolean receipt is the claim itself.
    assert verdict({"written": True}) == (True, "written")
    assert verdict({"written": False}) == (False, "written")
    assert verdict({"reset": True}) == (True, "reset")
    assert verdict({"copied": True}) == (True, "copied")
    assert verdict({"renamed": False}) == (False, "renamed")
    # A list receipt: something was acted on, or nothing was.
    assert verdict({"moved": ["Box001"]}) == (True, "moved")
    assert verdict({"moved": []}) == (False, "moved")
    assert verdict({"ungrouped": ["Group001"]}) == (True, "ungrouped")
    assert verdict({"ungrouped": []}) == (False, "ungrouped")
    assert verdict({"children": ["Box001", "Box002"]}) == (True, "children")


def check_empty_receipts_are_failures():
    assert verdict({"saved": ""}) == (False, "saved")
    assert verdict({"saved": "   "}) == (False, "saved")
    assert verdict({"group": ""}) == (False, "group")


def check_message_is_never_evidence():
    assert verdict({"message": "OK"}) is None
    assert verdict({"message": "Operation failed"}) is None
    assert verdict({"message": "OK", "path": "C:/work/a.max"}) is None
    assert verdict({"result": 42, "resultText": "42", "count": 1, "items": []}) is None
    assert verdict({}) is None


def check_missing_success_envelope():
    payload = normalize_payload({"message": "OK"}, "transform_object")
    assert payload["success"] is False
    assert [item["kind"] for item in payload["failures"]] == ["missing_success"]
    assert payload["verification"]["performed"] is False
    assert payload["verification"]["passed"] is None

    payload = normalize_payload({"saved": "C:/work/a.max"}, "scene_save")
    assert payload["success"] is True
    assert payload["failures"] == []

    payload = normalize_payload({"saved": ""}, "scene_save")
    assert payload["success"] is False
    assert payload["failures"], "an empty receipt must not be reported as success"


def check_specific_handlers():
    # Shapes copied from src/ms, so a change there shows up as a failure here.
    assert verdict({"layer": "L1", "message": "Layer created"}) == (True, "layer")
    assert verdict({"layer": "L1", "moved": ["Box001"], "failures": []}) == (True, "failures")
    assert verdict({"group": "Group001", "message": "OK"}) == (True, "group")
    assert verdict({"saved": "C:/a.max", "pathKept": False, "message": "Saved"}) == (True, "saved")
    assert verdict({"path": "C:/a.fbx", "preset": "unity", "written": True}) == (True, "written")
    assert verdict({"path": "C:/a.fbx", "written": False}) == (False, "written")
    assert verdict({"opened": "C:/a.max", "objectCount": 3}) == (True, "opened")
    assert verdict({"reset": True, "message": "OK"}) == (True, "reset")
    assert verdict({"oldName": "Box001", "newName": "Box002", "renamed": True}) == (True, "renamed")
    assert verdict({"oldName": "Box001", "newName": "Box002", "renamed": False}) == (False, "renamed")
    # execute_maxscript declares success explicitly because MAXScript has no
    # verdict of its own for a finished script.
    assert verdict({"success": True, "result": None, "resultText": ""}) == (True, "success")


def check_state_readback_shapes():
    """Shapes produced by the Stage 5 read-back handlers in src/ms."""
    # hide / freeze report the objects the scene now agrees about, and name the
    # ones that still disagree.  The failure list decides.
    assert verdict({"hidden": ["Box001", "Box002"], "failures": []}) == (True, "failures")
    assert verdict({"hidden": [], "failures": ["Box002"]}) == (False, "failures")
    assert verdict({"thawed": ["Box001"], "failures": []}) == (True, "failures")
    assert verdict({"shown": [], "failures": []}) == (True, "failures")
    # reset_transform / snap / mirror / set_pivot: applied + failures.
    assert verdict({"applied": ["Box001"], "failures": []}) == (True, "failures")
    assert verdict({"applied": [], "failures": ["Box001"]}) == (False, "failures")
    # light_set / cam_set: applied + skipped, and no failures key at all.
    assert verdict({"applied": ["color"], "skipped": ["iso"], "name": "Light01"}) == (True, "applied")
    # A call where every property was skipped mcpFails upstream, so the shape
    # never reaches the runtime - an empty applied with skipped is still a
    # "nothing was done" answer and must not read as success.
    assert verdict({"applied": [], "skipped": ["iso"]}) == (False, "applied")
    # render_set_resolution / frame range / set_units: settings echo + failures.
    assert verdict({"width": 1920, "height": 1080, "failures": []}) == (True, "failures")
    assert verdict({"systemType": "Meters", "failures": ["systemScale=2.5"]}) == (False, "failures")
    # mat_set_pbr / mat_set_emission: whatever landed, plus what did not.
    assert verdict({"applied": ["baseColor"], "skipped": ["metallic"]}) == (True, "applied")
    # mat_delete: still referenced anywhere is a failure.
    assert verdict({"usedBy": [], "inSlots": [], "failures": []}) == (True, "failures")
    assert verdict({"usedBy": ["Box001"], "failures": ["Box001"]}) == (False, "failures")


def check_audit_agrees_with_runtime():
    """The audit decides by key name; it must use exactly the runtime's keys."""
    sys.path.insert(0, str(ROOT / "test" / "static"))
    import outcome_audit

    from maxmcp.runtime import _OUTCOME_KEYS, _RECEIPT_KEYS

    expected = {"success", "ok", "failures"} | set(_OUTCOME_KEYS) | set(_RECEIPT_KEYS)
    assert outcome_audit.DECISIVE == expected
    assert "message" not in outcome_audit.DECISIVE


def main():
    check_explicit_flags_win()
    check_failure_list_is_read_first()
    check_enumeration_decides()
    check_receipt_fields_decide()
    check_empty_receipts_are_failures()
    check_message_is_never_evidence()
    check_missing_success_envelope()
    check_specific_handlers()
    check_state_readback_shapes()
    check_audit_agrees_with_runtime()
    print("outcome declaration: all checks passed")


if __name__ == "__main__":
    main()
