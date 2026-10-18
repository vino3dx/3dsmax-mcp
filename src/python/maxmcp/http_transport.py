"""HTTP transports for the MCP server.

Two flavours are served from one process, because different clients speak
different generations of the spec:

* **Streamable HTTP** (2025-03-26 and later) — a single ``POST /mcp`` endpoint
  that answers with plain JSON. This is what current clients and cloud agent
  platforms use.
* **Legacy HTTP + SSE** (2024-11-05) — ``GET /sse`` opens a server-sent event
  stream whose first event names a ``POST /messages`` endpoint. Older clients
  and several Chinese agent platforms still speak this.

Both are stateless apart from a per-stream queue, which keeps the server free of
session bookkeeping while still satisfying clients that expect a session id.

Everything here is stdlib. The interesting part is not the HTTP plumbing but the
shape of the replies: :meth:`MaxMcpServer.dispatch` returns a response object
rather than writing to a stream, so the same tool logic backs stdio, Streamable
HTTP and SSE unchanged.
"""

from __future__ import annotations

import json
import queue
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

DispatchFn = Callable[[Dict[str, Any]], Optional[Dict[str, Any]]]
LogFn = Callable[[str], None]

SSE_KEEPALIVE_SECONDS = 15.0
SESSION_TTL_SECONDS = 30 * 60.0
MAX_BODY_BYTES = 64 * 1024 * 1024


class _Session:
    __slots__ = ("id", "queue", "created")

    def __init__(self, session_id: str) -> None:
        self.id = session_id
        self.queue: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()
        self.created = time.time()


class McpHttpTransport:
    """A small HTTP server that forwards JSON-RPC to the MCP dispatcher."""

    def __init__(
        self,
        dispatch: DispatchFn,
        host: str = "127.0.0.1",
        port: int = 8770,
        token: Optional[str] = None,
        log: Optional[LogFn] = None,
        endpoint_path: str = "/mcp",
    ) -> None:
        self.dispatch = dispatch
        self.host = host
        self.port = port
        self.token = token
        self.endpoint_path = endpoint_path
        self._log = log or (lambda text: print("[3dsmax-mcp] {0}".format(text), file=sys.stderr, flush=True))

        self._sessions: Dict[str, _Session] = {}
        self._sessions_lock = threading.Lock()
        self._httpd: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self.requests_served = 0

    # ------------------------------------------------------------------ server
    def start(self) -> "McpHttpTransport":
        handler = _make_handler(self)
        httpd = ThreadingHTTPServer((self.host, self.port), handler)
        httpd.daemon_threads = True
        # The bound port matters when port 0 was requested (tests pick a free one).
        self.port = httpd.server_address[1]
        self._httpd = httpd
        self._thread = threading.Thread(target=httpd.serve_forever, name="mcp-http", daemon=True)
        self._thread.start()
        return self

    def serve_blocking(self) -> None:
        self.start()
        if self._thread is not None:
            self._thread.join()

    def stop(self) -> None:
        with self._sessions_lock:
            for session in self._sessions.values():
                session.queue.put(None)
            self._sessions.clear()
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None

    @property
    def url(self) -> str:
        return "http://{0}:{1}{2}".format(self.host, self.port, self.endpoint_path)

    # ----------------------------------------------------------------- logging
    def log(self, text: str) -> None:
        self._log(text)

    def note_request(self) -> None:
        self.requests_served += 1

    def warn_if_exposed(self) -> Optional[str]:
        """Return a loud message when the bind address is not loopback."""
        loopback = ("127.0.0.1", "localhost", "::1")
        if self.host in loopback:
            return None
        return (
            "--------------------------------------------------------------\n"
            " WARNING: the MCP HTTP endpoint is bound to {0}, not localhost.\n"
            " Anyone who can reach this port can run arbitrary MAXScript in your\n"
            " 3ds Max scene. Only do this on a trusted network, and set\n"
            " --http-token to require a bearer token.\n"
            "--------------------------------------------------------------".format(self.host)
        )

    # ---------------------------------------------------------------- sessions
    def new_session(self) -> _Session:
        session = _Session(secrets.token_hex(16))
        with self._sessions_lock:
            self._expire_locked()
            self._sessions[session.id] = session
        return session

    def get_session(self, session_id: str) -> Optional[_Session]:
        with self._sessions_lock:
            self._expire_locked()
            return self._sessions.get(session_id)

    def drop_session(self, session_id: str) -> None:
        with self._sessions_lock:
            self._sessions.pop(session_id, None)

    def _expire_locked(self) -> None:
        cutoff = time.time() - SESSION_TTL_SECONDS
        for key in [k for k, v in self._sessions.items() if v.created < cutoff]:
            stale = self._sessions.pop(key, None)
            if stale is not None:
                stale.queue.put(None)


# --------------------------------------------------------------------- handler
def _make_handler(transport: McpHttpTransport) -> type:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "3dsmax-mcp"

        # ------------------------------------------------------------ plumbing
        def log_message(self, fmt: str, *args: Any) -> None:  # noqa: WPS125
            # Silences the default per-request stderr spam; we log deliberately.
            pass

        def _send_json(self, status: int, payload: Any, extra: Optional[Dict[str, str]] = None) -> None:
            body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def _cors(self) -> None:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers",
                "Content-Type, Authorization, Mcp-Session-Id, MCP-Protocol-Version, Accept, Last-Event-ID",
            )
            self.send_header("Access-Control-Expose-Headers", "Mcp-Session-Id")

        # ----------------------------------------------------------------- auth
        def _authorized(self, query: Dict[str, List[str]]) -> bool:
            if not transport.token:
                return True
            header = self.headers.get("Authorization", "")
            if header.startswith("Bearer ") and secrets.compare_digest(header[7:].strip(), transport.token):
                return True
            supplied = (query.get("token") or [""])[0]
            return bool(supplied) and secrets.compare_digest(supplied, transport.token)

        # ------------------------------------------------------------- reading
        def _read_body(self) -> Tuple[Optional[Any], Optional[str]]:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return None, "Content-Length is not a number"
            if length <= 0:
                return None, "empty request body"
            if length > MAX_BODY_BYTES:
                return None, "request body is too large"
            raw = self.rfile.read(length)
            try:
                return json.loads(raw.decode("utf-8")), None
            except (ValueError, UnicodeDecodeError) as exc:
                return None, "invalid JSON: {0}".format(exc)

        # -------------------------------------------------------------- routes
        def do_OPTIONS(self) -> None:  # noqa: N802
            self.send_response(204)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            if parsed.path in ("/health", "/healthz"):
                self._send_json(200, {
                    "status": "ok",
                    "server": "3dsmax-mcp",
                    "transport": "http",
                    "streamableHttp": transport.endpoint_path,
                    "legacySse": "/sse",
                    "requests": transport.requests_served,
                })
                return
            if parsed.path == "/sse":
                self._serve_legacy_sse(query)
                return
            if parsed.path == transport.endpoint_path:
                if "text/event-stream" in (self.headers.get("Accept") or ""):
                    # We do not push unsolicited server->client messages, so the
                    # spec lets us decline the standalone stream.
                    self._send_json(405, {
                        "error": "This server does not offer a standalone SSE stream. "
                                 "POST your JSON-RPC messages to {0} instead.".format(transport.endpoint_path)
                    })
                else:
                    self._send_json(200, {
                        "server": "3dsmax-mcp",
                        "endpoint": transport.endpoint_path,
                        "hint": "POST JSON-RPC 2.0 messages here. Legacy SSE clients use /sse.",
                    })
                return
            self._send_json(404, {"error": "not found", "paths": [transport.endpoint_path, "/sse", "/messages", "/health"]})

        def do_DELETE(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            session_id = self.headers.get("Mcp-Session-Id") or ""
            if parsed.path == transport.endpoint_path and session_id:
                transport.drop_session(session_id)
                self.send_response(204)
                self._cors()
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._send_json(405, {"error": "session termination is not supported"})

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)

            if not self._authorized(query):
                self._send_json(401, {"error": "unauthorized: supply Authorization: Bearer <token>"})
                return

            if parsed.path == transport.endpoint_path:
                self._streamable_post()
                return
            if parsed.path in ("/messages", "/message"):
                self._legacy_message(query)
                return
            self._send_json(404, {"error": "not found", "paths": [transport.endpoint_path, "/sse", "/messages", "/health"]})

        # ------------------------------------------------- streamable HTTP POST
        def _streamable_post(self) -> None:
            message, error = self._read_body()
            if error is not None:
                self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                      "error": {"code": -32700, "message": "Parse error: {0}".format(error)}})
                return

            transport.note_request()
            responses = self._dispatch_all(message)
            extra: Dict[str, str] = {}
            session_id = self.headers.get("Mcp-Session-Id")

            # The spec lets the server hand out a session id on initialize.
            if _contains_initialize(message) and not session_id:
                session = transport.new_session()
                session_id = session.id
            if session_id:
                extra["Mcp-Session-Id"] = session_id

            if not responses:
                # Notifications and responses get an empty 202.
                self.send_response(202)
                self._cors()
                for key, value in extra.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            payload: Any = responses[0] if isinstance(message, dict) else responses
            self._send_json(200, payload, extra)

        def _dispatch_all(self, message: Any) -> List[Dict[str, Any]]:
            """Expand a batch, drop notifications, keep request replies in order."""
            messages = message if isinstance(message, list) else [message]
            collected: List[Dict[str, Any]] = []
            for item in messages:
                if not isinstance(item, dict):
                    collected.append({
                        "jsonrpc": "2.0", "id": None,
                        "error": {"code": -32600, "message": "Invalid request: expected a JSON object"},
                    })
                    continue
                response = transport.dispatch(item)
                if response is not None:
                    collected.append(response)
            return collected

        # --------------------------------------------------- legacy SSE transport
        def _serve_legacy_sse(self, query: Dict[str, List[str]]) -> None:
            if not self._authorized(query):
                self._send_json(401, {"error": "unauthorized"})
                return

            session = transport.new_session()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("Connection", "close")
            self.send_header("X-Accel-Buffering", "no")
            self._cors()
            self.end_headers()
            self.close_connection = True

            token_suffix = "&token={0}".format(transport.token) if transport.token else ""
            endpoint = "/messages?sessionId={0}{1}".format(session.id, token_suffix)
            if not self._write_sse("endpoint", endpoint):
                transport.drop_session(session.id)
                return

            transport.log("legacy SSE client attached (session {0}...)".format(session.id[:8]))
            try:
                while True:
                    try:
                        item = session.queue.get(timeout=SSE_KEEPALIVE_SECONDS)
                    except queue.Empty:
                        if not self._write_raw(": keep-alive\n\n"):
                            break
                        continue
                    if item is None:
                        break
                    transport.note_request()
                    if not self._write_sse("message", json.dumps(item, ensure_ascii=False, separators=(",", ":"))):
                        break
            finally:
                transport.drop_session(session.id)
                transport.log("legacy SSE client detached (session {0}...)".format(session.id[:8]))

        def _legacy_message(self, query: Dict[str, List[str]]) -> None:
            session_id = (query.get("sessionId") or [""])[0] or self.headers.get("Mcp-Session-Id") or ""
            session = transport.get_session(session_id) if session_id else None
            if session is None:
                self._send_json(404, {"error": "unknown session; open GET /sse first"})
                return

            message, error = self._read_body()
            if error is not None:
                self._send_json(400, {"error": "Parse error: {0}".format(error)})
                return

            for response in self._dispatch_all(message):
                session.queue.put(response)

            # The reply travels over the SSE stream, not this response.
            self.send_response(202)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()

        # ------------------------------------------------------------------ SSE
        def _write_raw(self, text: str) -> bool:
            try:
                self.wfile.write(text.encode("utf-8"))
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                return False

        def _write_sse(self, event: str, data: str) -> bool:
            return self._write_raw("event: {0}\ndata: {1}\n\n".format(event, data))

    return Handler


def _contains_initialize(message: Any) -> bool:
    items = message if isinstance(message, list) else [message]
    return any(isinstance(item, dict) and item.get("method") == "initialize" for item in items)
