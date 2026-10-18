"""Minimal, dependency-free MCP (Model Context Protocol) plumbing.

Implements the stdio transport: newline-delimited JSON-RPC 2.0 messages on
stdin/stdout. Only the subset of MCP needed by this server is implemented, which
keeps the install footprint at "python + stdlib".
"""

from __future__ import annotations

import json
import sys
import threading
from typing import Any, Callable, Dict, Iterable, Optional

# --------------------------------------------------------------------- errors
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


class RpcError(Exception):
    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data

    def to_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"code": self.code, "message": self.message}
        if self.data is not None:
            payload["data"] = self.data
        return payload


class StdioTransport:
    """Newline-delimited JSON-RPC over stdin/stdout.

    stdout is reserved exclusively for protocol traffic; every diagnostic goes
    to stderr so that MCP clients do not choke on log noise.
    """

    def __init__(self, stdin=None, stdout=None) -> None:
        self._stdin = stdin if stdin is not None else sys.stdin.buffer
        self._stdout = stdout if stdout is not None else sys.stdout.buffer
        self._write_lock = threading.Lock()

    def read_message(self) -> Optional[Dict[str, Any]]:
        while True:
            line = self._stdin.readline()
            if not line:
                return None
            text = line.decode("utf-8", "replace").strip()
            if not text:
                continue
            try:
                message = json.loads(text)
            except ValueError:
                self.send_error(None, PARSE_ERROR, "Parse error: message is not valid JSON")
                continue
            if isinstance(message, dict):
                return message
            self.send_error(None, INVALID_REQUEST, "Invalid request: expected a JSON object")

    def send(self, message: Dict[str, Any]) -> None:
        data = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        with self._write_lock:
            self._stdout.write(data.encode("utf-8"))
            self._stdout.write(b"\n")
            self._stdout.flush()

    def send_result(self, request_id: Any, result: Any) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def send_error(self, request_id: Any, code: int, message: str, data: Any = None) -> None:
        error: Dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        self.send({"jsonrpc": "2.0", "id": request_id, "error": error})

    def log(self, text: str) -> None:
        print("[3dsmax-mcp] {0}".format(text), file=sys.stderr, flush=True)


class NullTransport:
    """Transport stand-in for non-stdio modes (HTTP/SSE).

    In those modes the process never speaks on stdin/stdout: replies travel back
    inside the HTTP response. The server still needs something to log through,
    so this keeps diagnostics on stderr and makes any accidental write a no-op
    rather than corrupting a stream.
    """

    def read_message(self) -> Optional[Dict[str, Any]]:
        return None

    def send(self, message: Dict[str, Any]) -> None:  # pragma: no cover - no-op
        pass

    def send_result(self, request_id: Any, result: Any) -> None:  # pragma: no cover - no-op
        pass

    def send_error(self, request_id: Any, code: int, message: str, data: Any = None) -> None:  # pragma: no cover
        pass

    def log(self, text: str) -> None:
        print("[3dsmax-mcp] {0}".format(text), file=sys.stderr, flush=True)


# ------------------------------------------------------------------ utilities
def text_content(text: str) -> Dict[str, Any]:
    return {"type": "text", "text": text}


def json_content(payload: Any) -> Dict[str, Any]:
    return {
        "type": "text",
        "text": json.dumps(payload, ensure_ascii=False, indent=2, default=_fallback),
    }


def image_content(data: str, mime_type: str = "image/png") -> Dict[str, Any]:
    """One MCP image content block.

    ``data`` is base64 of the raw image bytes.  The image is what makes a 3D
    bridge usable: a tool that reports ``{"ok": true}`` for "create a box" can
    be wrong in a hundred ways that only a picture reveals.  See
    ``max/mcp_vision.ms`` for the producing side.
    """
    return {"type": "image", "data": data, "mimeType": mime_type or "image/png"}


def make_result(content: Iterable[Dict[str, Any]], is_error: bool = False) -> Dict[str, Any]:
    result: Dict[str, Any] = {"content": list(content)}
    if is_error:
        result["isError"] = True
    return result


def _fallback(value: Any) -> str:
    try:
        return str(value)
    except Exception:  # pragma: no cover - defensive
        return "<unserializable>"


def clamp_text(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    head = text[:limit]
    return "{0}\n\n... [truncated, {1} of {2} characters shown]".format(head, limit, len(text))


RequestHandler = Callable[[Optional[Any], Dict[str, Any]], None]
