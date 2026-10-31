"""Regression tests for MCP image result normalization.

The fixtures use real image *headers* (a PNG signature, a JPEG SOI marker) because
the server now validates what the bytes actually are instead of trusting the
declared MIME type.  A three-character payload is not an image, so it must be
reported as an error rather than shipped to the client as ``image/png``.
"""

import base64
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.server import _split_images  # noqa: E402

JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 32).decode("ascii")
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32).decode("ascii")


def main() -> None:
    blocks, summary = _split_images(
        {
            "ok": True,
            "_images": [
                {"label": "front", "data": JPEG, "mime": "image/jpeg"},
                {"label": "bad", "data": PNG, "mime": "text/plain"},
                {"label": "empty", "data": ""},
            ],
        },
        "op-00000042",
    )
    assert len(blocks) == 2, blocks
    assert blocks[0]["type"] == "image"
    assert blocks[0]["mimeType"] == "image/jpeg"
    # declared text/plain over PNG bytes -> corrected from the payload itself
    assert blocks[1]["mimeType"] == "image/png"
    assert summary["ok"] is True
    assert "_images" not in summary
    assert summary["operation_id"] == "op-00000042"
    assert all(item["operation_id"] == "op-00000042" for item in summary["images"])
    assert summary["image_errors"][0]["label"] == "empty"

    untouched = {"ok": True}
    blocks, result = _split_images(untouched, "op-00000043")
    assert blocks == []
    assert result is untouched
    print("vision result normalization: all checks passed")


if __name__ == "__main__":
    main()
