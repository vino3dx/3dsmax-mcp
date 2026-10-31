"""Offline contract checks for the Stage 1.5 core capability audit."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.catalog import build_catalog
from maxmcp.catalog.schema import CORE_TOOLS


def main() -> None:
    catalog = build_catalog()
    compatibility = {
        "create_object": "create_box",
        "duplicate_object": "clone_objects",
        "apply_modifier": "mod_add",
        "assign_material": "mat_assign",
    }
    for conceptual, current in compatibility.items():
        assert conceptual not in catalog.names(), conceptual
        assert catalog.get(current) is not None, current
        assert current in CORE_TOOLS, current

    batch_tools = (
        "transform_object", "clone_objects", "delete_objects", "select_objects",
        "mat_assign", "mod_add",
    )
    for name in batch_tools:
        entry = catalog.get(name)
        assert entry is not None
        props = entry.schema.get("properties", {})
        assert "objects" in props, "%s lacks objects batch parameter" % name
        assert props["objects"].get("type") == "array"

    for name in CORE_TOOLS:
        entry = catalog.get(name)
        assert entry is not None
        assert entry.schema.get("type") == "object"
        assert entry.description_en and entry.description_zh
    print("core contract: all offline checks passed")


if __name__ == "__main__":
    main()
