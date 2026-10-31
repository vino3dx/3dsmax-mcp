"""Regression tests for MCP image result normalization."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.server import _split_images


def main() -> None:
    blocks, summary = _split_images(
        {
            "ok": True,
            "_images": [
                {"label": "front", "data": "abc", "mime": "image/jpeg"},
                {"label": "bad", "data": "ignored", "mime": "text/plain"},
                {"label": "empty", "data": ""},
            ],
        },
        "op-00000042",
    )
    assert len(blocks) == 2
    assert blocks[0]["type"] == "image"
    assert blocks[0]["mimeType"] == "image/jpeg"
    assert blocks[1]["mimeType"] == "image/png"
    assert summary["ok"] is True
    assert "_images" not in summary
    assert summary["operation_id"] == "op-00000042"
    assert all(item["operation_id"] == "op-00000042" for item in summary["images"])

    untouched = {"ok": True}
    blocks, result = _split_images(untouched, "op-00000043")
    assert blocks == []
    assert result is untouched
    print("vision result normalization: all checks passed")


if __name__ == "__main__":
    main()
