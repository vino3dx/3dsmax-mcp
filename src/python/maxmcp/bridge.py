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


class MaxBridge:
    """Lazily-connected client for the in-Max bridge."""

    def __init__(self, config: Config) -> None:
        self.config = config
        self._sock: Optional[socket.socket] = None
        self._lock = threading.RLock()
        self._counter = itertools.count(1)
        self._negotiated_port: Optional[int] = None

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
                    raw = self._read_line(sock, method)
                    return self._parse(method, raw)
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

    def _read_line(self, sock: socket.socket, method: str) -> str:
        buf = bytearray()
        deadline = time.time() + self.config.timeout_s
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise BridgeTimeout(
                    i18n.t("bridge.timeout", self.config.language, timeout=int(self.config.timeout_s), method=method)
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
            buf.extend(chunk)
            idx = buf.find(b"\n")
            if idx >= 0:
                return bytes(buf[:idx]).decode("ascii", "replace")

    def _parse(self, method: str, raw: str) -> Any:
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
