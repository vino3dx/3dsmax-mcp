"""Offline tests for image payload and file-path handling."""

import base64
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.server import _split_images


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "view.png"
        path.write_bytes(b"PNG-test")
        blocks, summary = _split_images({"_images": [{"label": "view", "path": str(path)}]}, "op-1")
        assert len(blocks) == 1
        assert blocks[0]["type"] == "image"
        assert blocks[0]["mimeType"] == "image/png"
        assert base64.b64decode(blocks[0]["data"]) == b"PNG-test"
        assert "image_errors" not in summary

        _, missing = _split_images({"_images": [{"label": "missing", "path": str(path) + "-no.png"}]}, "op-2")
        assert missing["image_errors"][0]["error"].startswith("image file unavailable")
    print("image result handling: all checks passed")


if __name__ == "__main__":
    main()
