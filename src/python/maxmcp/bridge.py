"""Transport between the MCP server (this process) and 3ds Max.

The in-Max bridge is a plain TCP server speaking newline-delimited JSON. The
wire format is **ASCII only** (every payload is JSON-escaped with
``ensure_ascii=True``), because the MAXScript side decodes each read chunk with a
single-byte ASCII codec and therefore needs one byte per character.

    -> {"id":1,"method":"create_box","params":{"length":10}}\n
    <- {"id":1,"ok":true,"result":{"name":"Box001"}}\n
"""

from __future__ import annotations

import itertools
import json
import socket
import threading
import time
from typing import Any, Dict, Optional

from .config import Config
from . import i18n, wire


def _dismiss_blocking_dialogs() -> list:
    """Close known modal dialogs that are blocking 3ds Max's UI thread.

    Never raises: this runs on an error path, and a missing window or a
    platform without the helper must not mask the original timeout.
    """
    try:
        from . import dialogs
    except Exception:  # pragma: no cover - import guard only
        return []
    try:
        return dialogs.dismiss(aggressive=True)
    except Exception:  # pragma: no cover - defensive
        return []


class BridgeError(RuntimeError):
    """Base class for bridge failures."""

    kind = "bridge_error"


class BridgeNotRunning(BridgeError):
    kind = "not_running"


class BridgeTimeout(BridgeError):
    kind = "timeout"


class BridgeProtocolError(BridgeError):
    kind = "protocol_error"


class BridgeCommandError(BridgeError):
    kind = "command_error"

    def __init__(self, message: str, detail: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.detail = detail or {}
        # MAXScript may provide a stable error code in the response.  Keep it
        # optional so older bridges remain compatible while newer clients can
        # branch without parsing localized text.
        self.code = self.detail.get("code") or "max_command_failed"


class MaxBridge:
    """Lazily-connected client for the in-Max bridge."""

    def __init__(self, config: Config) -> None:
        self.config = config
        self._sock: Optional[socket.socket] = None
        self._lock = threading.RLock()
        self._counter = itertools.count(1)
        self._negotiated_port: Optional[int] = None
        # Bytes already read from the socket but not yet consumed as lines.
        # Keeping this across calls matters: one recv() can legitimately hold
        # more than one reply, and throwing the tail away used to shift every
        # later reply by one.
        self._rx = bytearray()

    # ------------------------------------------------------------- lifecycle
    @property
    def connected(self) -> bool:
        with self._lock:
            return self._sock is not None

    def close(self) -> None:
        with self._lock:
            if self._sock is not None:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
            self._rx = bytearray()

    def _connect(self) -> socket.socket:
        errors = []
        for port in self.config.candidate_ports:
            try:
                sock = socket.create_connection(
                    (self.config.host, port), timeout=self.config.connect_timeout_s
                )
            except OSError as exc:
                errors.append("{0}:{1} -> {2}".format(self.config.host, port, exc))
                continue
            sock.settimeout(self.config.timeout_s)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._sock = sock
            self._negotiated_port = port
            return sock
        self._sock = None
        raise BridgeNotRunning(
            i18n.t(
                "bridge.not_running",
                self.config.language,
                host=self.config.host,
                port=self.config.port,
                bridge_script="mcp_bridge.ms",
            )
            + ("\n" + "\n".join(errors[:4]) if errors else "")
        )

    def _ensure_socket(self) -> socket.socket:
        if self._sock is None:
            return self._connect()
        return self._sock

    # ----------------------------------------------------------------- calls
    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        """Invoke one bridge command and return its ``result`` payload."""
        payload = {
            "id": next(self._counter),
            "method": method,
            "params": params or {},
            "lang": self.config.language,
        }
        line = json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n"

        with self._lock:
            last_error: Optional[Exception] = None
            for attempt in (1, 2):
                try:
                    sock = self._ensure_socket()
                    sock.sendall(line.encode("ascii"))
                    return self._read_reply(sock, method, payload["id"])
                except (BridgeNotRunning, BridgeTimeout, BridgeCommandError, BridgeProtocolError):
                    raise
                except (OSError, socket.timeout) as exc:
                    last_error = exc
                    self.close()
                    if attempt == 2:
                        break
                    time.sleep(0.15)
            self.close()
            raise BridgeNotRunning(
                i18n.t(
                    "bridge.not_running",
                    self.config.language,
                    host=self.config.host,
                    port=self.config.port,
                    bridge_script="mcp_bridge.ms",
                )
                + "\n{0}".format(last_error)
            )

    def _read_reply(self, sock: socket.socket, method: str, request_id: int) -> Any:
        """Read until the reply that belongs to ``request_id`` arrives.

        A handler that dies through a MAXScript *system* exception (for example
        the stack overflow ObjExp can raise) can leave one extra line queued in
        the socket.  Before this check every later call silently returned the
        previous call's payload - the worst possible failure mode, because the
        data looks valid.  Matching on the id turns that into either a clean
        answer or a loud protocol error.
        """
        for _ in range(8):
            data = self._decode(method, self._read_line(sock, method))
            rid = data.get("id")
            if rid is None or rid == request_id:
                return self._unpack(method, data)
        # The stream is out of step by more than a few lines: drop the socket so
        # the next call reconnects into a known-clean state.
        self.close()
        raise BridgeProtocolError(
            i18n.t("bridge.protocol_error", self.config.language, detail="out-of-order reply (id mismatch)")
        )

    def _read_line(self, sock: socket.socket, method: str) -> str:
        deadline = time.time() + self.config.timeout_s
        dismissed: list = []
        watchdog_used = False
        while True:
            # A previous recv() may already hold a complete line (or several).
            idx = self._rx.find(b"\n")
            if idx >= 0:
                line = bytes(self._rx[:idx]).decode("ascii", "replace")
                del self._rx[: idx + 1]
                return line
            remaining = deadline - time.time()
            if remaining <= 0:
                # A modal dialog (MAXScript error, FBX import, render report)
                # blocks the 3ds Max UI thread, and the bridge runs on that
                # thread -- so the request is never going to answer while the
                # box is up. Clear the known blockers and give the pending
                # command one short grace window before giving up.
                if not watchdog_used:
                    watchdog_used = True
                    dismissed = _dismiss_blocking_dialogs()
                    if dismissed:
                        deadline = time.time() + min(20.0, max(5.0, self.config.timeout_s / 3.0))
                        continue
                detail = ""
                if dismissed:
                    detail = " | " + i18n.t("bridge.dialogs_dismissed", self.config.language, titles="; ".join(dismissed))
                raise BridgeTimeout(
                    i18n.t("bridge.timeout", self.config.language, timeout=int(self.config.timeout_s), method=method)
                    + detail
                )
            sock.settimeout(min(remaining, 5.0))
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                # Long-running operations (render / bake) simply keep the
                # connection idle; keep waiting until the overall deadline.
                continue
            if not chunk:
                self.close()
                raise BridgeNotRunning(i18n.t("bridge.disconnected", self.config.language))
            self._rx.extend(chunk)

    def _decode(self, method: str, raw: str) -> Dict[str, Any]:
        """Turn one wire line into a response object, without interpreting it."""
        raw = raw.strip()
        if not raw:
            raise BridgeProtocolError(i18n.t("bridge.protocol_error", self.config.language, detail="<empty>"))
        try:
            data = json.loads(raw)
        except ValueError as exc:
            raise BridgeProtocolError(
                i18n.t("bridge.protocol_error", self.config.language, detail="{0}: {1}".format(exc, raw[:400]))
            )
        if not isinstance(data, dict):
            raise BridgeProtocolError(i18n.t("bridge.protocol_error", self.config.language, detail=raw[:400]))
        return data

    def _parse(self, method: str, raw: str) -> Any:
        return self._unpack(method, self._decode(method, raw))

    def _unpack(self, method: str, data: Dict[str, Any]) -> Any:
        if data.get("ok"):
            return data.get("result")
        err = data.get("error") or {}
        if isinstance(err, str):
            err = {"message": err}
        # The error text was produced inside 3ds Max, so it carries the same
        # ANSI byte escaping as any other payload.
        detail = wire.from_wire(err)
        raise BridgeCommandError(
            i18n.t("bridge.command_failed", self.config.language, detail=detail.get("message") or "unknown error"),
            detail=detail,
        )

    # ------------------------------------------------------------------ misc
    def status(self) -> Dict[str, Any]:
        """Light-weight connectivity probe that never raises."""
        try:
            result = self.call("bridge_status", {})
            return {"connected": True, "port": self._negotiated_port, "info": result}
        except BridgeError as exc:
            return {"connected": False, "kind": exc.kind, "message": str(exc)}
