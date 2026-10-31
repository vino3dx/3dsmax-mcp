"""Offline tests for the image (visual feedback) pipeline.

Every case here is about the bytes that would reach an MCP client: does a valid
PNG survive as an ``image`` block, and does a broken/oversized/out-of-bounds
image fail loudly instead of shipping garbage or a bare file path?

No real 3ds Max screenshot is involved - these fixtures are synthetic headers,
which is exactly why the assertions check *handling*, not "the viewport looked
correct".
"""

import base64
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp import server as server_module  # noqa: E402
from maxmcp.protocol import image_content, make_result  # noqa: E402
from maxmcp.server import _allowed_image_roots, _split_images  # noqa: E402

PNG_HEADER = b"\x89PNG\r\n\x1a\n"
JPEG_HEADER = b"\xff\xd8\xff\xe0"
PNG_BYTES = PNG_HEADER + b"0" * 64
JPEG_BYTES = JPEG_HEADER + b"\x00" * 64


def png_data() -> str:
    return base64.b64encode(PNG_BYTES).decode("ascii")


def jpeg_data() -> str:
    return base64.b64encode(JPEG_BYTES).decode("ascii")


def check_png_file():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "view.png"
        path.write_bytes(PNG_BYTES)
        blocks, summary = _split_images(
            {"_images": [{"label": "view", "path": str(path)}]}, "op-1")
        assert len(blocks) == 1
        assert blocks[0]["type"] == "image"
        assert blocks[0]["mimeType"] == "image/png"
        assert base64.b64decode(blocks[0]["data"]) == PNG_BYTES
        assert "image_errors" not in summary
        assert summary["images"][0]["label"] == "view"
        assert summary["operation_id"] == "op-1"


def check_jpeg_file():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "shot.jpeg"
        path.write_bytes(JPEG_BYTES)
        blocks, _ = _split_images({"_images": [{"path": str(path)}]})
        assert blocks[0]["mimeType"] == "image/jpeg"
        assert base64.b64decode(blocks[0]["data"]) == JPEG_BYTES


def check_missing_file():
    with tempfile.TemporaryDirectory() as directory:
        missing = Path(directory) / "nope.png"
        _, summary = _split_images({"_images": [{"label": "missing", "path": str(missing)}]})
        assert summary["image_errors"][0]["error"].startswith("image file unavailable")


def check_empty_file():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "empty.png"
        path.write_bytes(b"")
        blocks, summary = _split_images({"_images": [{"path": str(path)}]})
        assert blocks == []
        assert summary["image_errors"][0]["error"] == "empty image payload"


def check_wrong_mime_is_corrected_from_bytes():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "actually_png.png"
        path.write_bytes(PNG_BYTES)
        blocks, summary = _split_images(
            {"_images": [{"path": str(path), "mime": "text/plain"}]})
        # the declared type is a claim; the bytes win
        assert blocks[0]["mimeType"] == "image/png"
        assert "image_errors" not in summary

        mismatch = Path(directory) / "declared_jpeg.png"
        mismatch.write_bytes(JPEG_BYTES)
        blocks, _ = _split_images({"_images": [{"path": str(mismatch), "mime": "image/png"}]})
        assert blocks[0]["mimeType"] == "image/jpeg"


def check_corrupt_image():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "corrupt.png"
        path.write_bytes(b"this is not an image")
        blocks, summary = _split_images({"_images": [{"path": str(path)}]})
        assert blocks == []
        assert "not a recognized" in summary["image_errors"][0]["error"]


def check_oversized_file():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "huge.png"
        with path.open("wb") as stream:
            stream.write(PNG_HEADER)
            stream.write(b"0" * (server_module._IMAGE_MAX_BYTES + 1))
        blocks, summary = _split_images({"_images": [{"path": str(path)}]})
        assert blocks == []
        assert "8 MiB" in summary["image_errors"][0]["error"]


def check_path_outside_roots():
    target = ROOT / "src" / "ms" / "mcp_core.ms"
    assert target.is_file()
    blocks, summary = _split_images({"_images": [{"path": str(target)}]})
    assert blocks == []
    assert "outside the allowed screenshot roots" in summary["image_errors"][0]["error"]


def check_traversal_is_blocked():
    with tempfile.TemporaryDirectory() as directory:
        inside = Path(directory) / "ok.png"
        inside.write_bytes(PNG_BYTES)
        escape = Path(directory) / ".." / "escape.png"
        # .. still resolves inside/outside depending on the temp dir layout; the
        # point is that resolution happens before the check
        blocks, summary = _split_images(
            {"_images": [{"path": str(escape)}]}, roots=[Path(directory).resolve()])
        assert blocks == []
        assert summary["image_errors"]


def check_inline_base64():
    blocks, summary = _split_images(
        {"_images": [{"data": png_data(), "mime": "image/png", "label": "front"}]})
    assert len(blocks) == 1
    assert base64.b64decode(blocks[0]["data"]) == PNG_BYTES
    assert summary["images"][0]["base64Chars"] == len(png_data())


def check_invalid_base64():
    blocks, summary = _split_images({"_images": [{"data": "!!!not base64!!!"}]})
    assert blocks == []
    assert "valid base64" in summary["image_errors"][0]["error"]


def check_declared_mime_corrected_for_base64():
    blocks, _ = _split_images(
        {"_images": [{"data": jpeg_data(), "mime": "image/png"}]})
    assert blocks[0]["mimeType"] == "image/jpeg"


def check_mixed_text_and_images():
    payload = {
        "ok": True,
        "count": 2,
        "_images": [
            {"label": "persp", "data": png_data(), "mime": "image/png"},
            {"label": "broken", "data": "!!"},
        ],
    }
    blocks, summary = _split_images(payload, "op-9")
    assert len(blocks) == 1
    assert summary["ok"] is True and summary["count"] == 2
    assert "_images" not in summary
    assert [item["label"] for item in summary["images"]] == ["persp", "broken"]
    assert summary["image_errors"][0]["label"] == "broken"


def check_nested_runtime_envelope():
    payload = {
        "success": True,
        "operation": "vision_capture",
        "data": {"count": 1, "_images": [{"data": png_data()}]},
    }
    blocks, summary = _split_images(payload, "op-10")
    assert len(blocks) == 1
    assert "_images" not in summary["data"]
    assert summary["data"]["count"] == 1
    assert summary["images"][0]["operation_id"] == "op-10"


def check_response_budget():
    original = server_module._IMAGE_TOTAL_BYTES
    server_module._IMAGE_TOTAL_BYTES = len(png_data()) + 10
    try:
        blocks, summary = _split_images({"_images": [
            {"label": "a", "data": png_data()},
            {"label": "b", "data": png_data()},
        ]})
        assert len(blocks) == 1
        assert "budget" in summary["image_errors"][0]["error"]
    finally:
        server_module._IMAGE_TOTAL_BYTES = original


def check_image_content_block_serialization():
    block = image_content(png_data(), "image/png")
    assert block["type"] == "image"
    assert block["mimeType"] == "image/png"
    result = make_result([{"type": "text", "text": "{\"ok\": true}"}, block])
    wire = json.dumps(result)
    restored = json.loads(wire)
    assert restored["content"][1]["type"] == "image"
    assert base64.b64decode(restored["content"][1]["data"]) == PNG_BYTES
    # text and image blocks coexist in one tool result
    assert restored["content"][0]["type"] == "text"


def check_default_roots():
    roots = _allowed_image_roots()
    assert roots, "there must always be at least one allowed root"
    custom = _allowed_image_roots([str(ROOT)])
    assert any(str(ROOT) in str(root) for root in custom)


def main():
    check_png_file()
    check_jpeg_file()
    check_missing_file()
    check_empty_file()
    check_wrong_mime_is_corrected_from_bytes()
    check_corrupt_image()
    check_oversized_file()
    check_path_outside_roots()
    check_traversal_is_blocked()
    check_inline_base64()
    check_invalid_base64()
    check_declared_mime_corrected_for_base64()
    check_mixed_text_and_images()
    check_nested_runtime_envelope()
    check_response_budget()
    check_image_content_block_serialization()
    check_default_roots()
    print("image result handling: all checks passed")


if __name__ == "__main__":
    main()
