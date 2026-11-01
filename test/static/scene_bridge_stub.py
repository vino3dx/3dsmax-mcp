"""A real TCP bridge in front of :class:`FakeScene`.

The workflow tests need the *real* chain - newline-framed JSON, the real
``MaxBridge`` parser, the real server dispatch, the real runtime/batch layers -
with only 3ds Max itself missing.  ``SceneBridgeStub`` is that missing piece: it
listens on an ephemeral port, forwards every request to a ``FakeScene`` instance
and replies in the envelope the bridge speaks.

Two failure modes are deliberately faithful:

* a MAXScript-style error (``BridgeCommandError`` with a ``kind``) is returned as
  ``{"ok": false, "error": {...}}`` so it travels through the real error
  classification path;
* a transport failure closes the socket without an answer, which is what Max
  dying mid-request looks like to the client (``BridgeDisconnected``).

Nothing here pretends to be 3ds Max: the scene is in memory and every handler is
a documented stand-in for one MAXScript command.
"""

from __future__ import annotations

import json
from pathlib import Path
import socket
import sys
import threading
from typing import Any, Dict, Optional

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "src" / "python"))

from fake_scene import FakeScene  # noqa: E402
from maxmcp.bridge import BridgeCommandError  # noqa: E402


class SceneBridgeStub:
    """Serve one ``FakeScene`` over the real bridge protocol."""

    def __init__(self, scene: Optional[FakeScene] = None) -> None:
        self.scene = scene if scene is not None else FakeScene()
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(8)
        self.port = self._server.getsockname()[1]
        self._stop = False
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    # ---------------------------------------------------------------- serving
    def _accept_loop(self) -> None:
        while not self._stop:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            buffer = b""
            while not self._stop:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        request = json.loads(line.decode("ascii"))
                    except ValueError:
                        return
                    reply = self._reply(request)
                    if reply is None:
                        # Transport failure: drop the connection, like Max quitting.
                        conn.close()
                        return
                    try:
                        conn.sendall(reply)
                    except OSError:
                        return

    def _reply(self, request: Dict[str, Any]) -> Optional[bytes]:
        request_id = request.get("id")
        method = str(request.get("method") or "")
        params = request.get("params") or {}
        try:
            result = self.scene.call(method, params)
        except BridgeCommandError as exc:
            detail = getattr(exc, "detail", None) or {}
            kind = detail.get("kind") or getattr(exc, "kind", None) or "error"
            body = json.dumps({"kind": kind, "message": str(exc)}, ensure_ascii=True)
            return ('{"id":%s,"ok":false,"error":%s}\n' % (json.dumps(request_id), body)).encode("ascii")
        except Exception as exc:  # noqa: BLE001 - a transport failure closes the socket
            if getattr(self.scene, "transport_failure", None) is not None:
                return None
            body = json.dumps({"kind": "runtime_error", "message": str(exc)}, ensure_ascii=True)
            return ('{"id":%s,"ok":false,"error":%s}\n' % (json.dumps(request_id), body)).encode("ascii")
        payload = json.dumps({"id": request_id, "ok": True, "result": result},
                             ensure_ascii=True, default=str)
        return (payload + "\n").encode("ascii")

    # ------------------------------------------------------------------ close
    def close(self) -> None:
        self._stop = True
        try:
            self._server.close()
        except OSError:
            pass


__all__ = ["SceneBridgeStub"]
