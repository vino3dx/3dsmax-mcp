"""Audit the boundary between the candidate core profile and live evidence."""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.catalog import build_catalog
from maxmcp.catalog.schema import CORE_TOOLS


def main() -> None:
    catalog = build_catalog()
    names = set(catalog.names())
    assert CORE_TOOLS <= names, "core contains undeclared tools"
    assert "poly_triangulate" not in CORE_TOOLS, "unsupported triangulate leaked into core"

    live = set()
    for path in sorted((ROOT / "test" / "live" / "live_cases").glob("*.json")):
        entries = json.loads(path.read_text(encoding="utf-8"))
        live.update(item["tool"] for item in entries if isinstance(item, dict) and "tool" in item)

    covered = CORE_TOOLS & live
    uncovered = sorted(CORE_TOOLS - live)
    print("core evidence audit: core=%d live_tools=%d covered=%d uncovered=%d" % (
        len(CORE_TOOLS), len(live), len(covered), len(uncovered)
    ))
    if uncovered:
        print("core tools without live cases: " + ", ".join(uncovered))


if __name__ == "__main__":
    main()
