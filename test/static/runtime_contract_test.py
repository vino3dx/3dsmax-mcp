"""Offline tests for legacy payload, batch, and object reference adapters."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.runtime import build_batch_result, normalize_payload, resolve_object_refs


def main() -> None:
    legacy = normalize_payload({"created": True}, "create_box")
    assert legacy["success"] is False
    assert legacy["failures"][0]["kind"] == "missing_success"

    explicit = normalize_payload({"success": True, "result": {"name": "Box001"}}, "create_box")
    assert explicit["success"] is True
    assert explicit["data"] == {"name": "Box001"}
    assert explicit["failures"] == []

    batch = build_batch_result("batch_transform", [
        {"name": "Box001", "success": True, "verified": True},
        {"name": "Missing", "success": False},
    ])
    assert batch["success"] is False
    assert batch["summary"] == {"total": 2, "succeeded": 1, "failed": 1}
    assert batch["objects"][1]["error"]["kind"] == "item_failed"
    # one verified row out of two: the batch verdict must stay "not proven"
    assert batch["verification"]["performed"] is True
    assert batch["verification"]["passed"] is None

    unverified = build_batch_result("batch_transform", [
        {"name": "Box001", "success": True},
    ])
    assert unverified["verification"] == {"performed": False, "passed": None, "detail": None}

    available = [{"name": "Box001", "class": "Box"}, {"name": "Box001", "class": "Sphere"}]
    ambiguous = resolve_object_refs(["Box001"], available)[0]
    assert ambiguous["error"]["kind"] == "ambiguous_object"
    stale = resolve_object_refs([{"name": "Deleted", "object_ref": "future"}], available)[0]
    assert stale["error"]["kind"] == "stale_object_reference"
    invalid = resolve_object_refs([{"name": ""}, {"handle": 12}], available)
    assert [row["error"]["kind"] for row in invalid] == ["invalid_object_reference"] * 2
    resolved = resolve_object_refs(["Other"], [{"name": "Other", "class": "Box", "handle": 7}])[0]
    assert resolved["success"] is True
    assert resolved["object_ref"] == {"name": "Other", "handle": 7}
    print("runtime contract adapters: all checks passed")


if __name__ == "__main__":
    main()
