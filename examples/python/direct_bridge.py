#!/usr/bin/env python
"""Talk to the 3ds Max bridge directly, without the MCP layer.

Useful for debugging, for scripting a batch job, or for checking the bridge
after a code change without wiring up an AI client.

The bridge speaks newline-delimited JSON over TCP. Non-ASCII text travels as
ANSI code-page bytes escaped as ``\\u00XX``, which is what maxmcp.wire handles.

Run from the repository root with 3ds Max open and the bridge started:

    PYTHONPATH=src python examples/python/direct_bridge.py

    # ...or against an installed copy:
    set PYTHONPATH=%LOCALAPPDATA%\\3dsmax-mcp
    python examples/python/direct_bridge.py --port 8765
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from typing import Any, Dict, Optional

try:
    from maxmcp.config import Config
    from maxmcp.wire import from_wire, to_wire
except ImportError:  # pragma: no cover - guidance for a missing PYTHONPATH
    sys.exit(
        "Could not import maxmcp. Run with PYTHONPATH pointing at src/ or the install dir:\n"
        "    set PYTHONPATH=%LOCALAPPDATA%\\3dsmax-mcp\n"
    )


class RawBridge:
    """A deliberately thin client - one call in, one result out."""

    def __init__(self, host: str, port: int, language: str = "zh", timeout: float = 120.0) -> None:
        self.host = host
        self.port = port
        self.language = language
        self.timeout = timeout
        self._id = 0
        self._sock: Optional[socket.socket] = None

    def __enter__(self) -> "RawBridge":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def connect(self) -> None:
        if self._sock is not None:
            return
        try:
            self._sock = socket.create_connection((self.host, self.port), timeout=2.0)
        except OSError as exc:
            raise SystemExit(
                "Nothing is listening on {0}:{1} ({2}).\n"
                "Is 3ds Max running, and was it restarted after installing?".format(
                    self.host, self.port, exc
                )
            )

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        self.connect()
        assert self._sock is not None

        self._id += 1
        request = {
            "id": self._id,
            "method": method,
            # Everything we send is translated into the wire's byte-escaped form.
            "params": to_wire(params or {}),
            "lang": self.language,
        }
        self._sock.sendall(
            (json.dumps(request, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
        )

        # A batch render can sit silent for minutes; wait in slices.
        buf = bytearray()
        self._sock.settimeout(self.timeout)
        while b"\n" not in buf:
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                raise SystemExit("Timed out after {0}s waiting for {1!r}.".format(self.timeout, method))
            if not chunk:
                self.close()
                raise SystemExit("The bridge closed the connection during {0!r}.".format(method))
            buf.extend(chunk)

        line = bytes(buf).split(b"\n", 1)[0].decode("ascii", "replace")
        reply = json.loads(line)
        if not reply.get("ok", False):
            # Error text comes back byte-escaped too - decode before showing it.
            raise SystemExit("bridge error: {0}".format(from_wire(reply.get("error"))))
        return from_wire(reply.get("result"))


def main(argv: Optional[list] = None) -> int:
    config = Config.load()
    parser = argparse.ArgumentParser(description="Call the 3ds Max bridge directly (no MCP layer).")
    parser.add_argument("--host", default=config.host)
    parser.add_argument("--port", type=int, default=config.port)
    parser.add_argument("--language", default=config.language, choices=("zh", "en"))
    parser.add_argument("--timeout", type=float, default=config.timeout_s)
    parser.add_argument(
        "method",
        nargs="?",
        default=None,
        help="bridge command to run; omit to run the built-in demo",
    )
    parser.add_argument(
        "params",
        nargs="?",
        default="{}",
        help="JSON object of parameters, e.g. '{\"name\":\"Box001\"}'",
    )
    args = parser.parse_args(argv)

    with RawBridge(args.host, args.port, args.language, args.timeout) as bridge:
        # ---------------------------------------------------------- one-shot mode
        if args.method:
            try:
                params = json.loads(args.params)
            except ValueError as exc:
                raise SystemExit("params is not valid JSON: {0}".format(exc))
            print(json.dumps(bridge.call(args.method, params), indent=2, ensure_ascii=False))
            return 0

        # ------------------------------------------------------------- demo mode
        print("== bridge_status ==")
        status = bridge.call("bridge_status")
        print(json.dumps(status, indent=2, ensure_ascii=False))

        print("\n== bridge_capabilities ==")
        caps = bridge.call("bridge_capabilities")
        print(json.dumps(caps, indent=2, ensure_ascii=False)[:1200])

        # Create something with a Chinese name and read it back. If this comes
        # out intact the ANSI round trip is healthy.
        print("\n== Chinese round trip ==")
        created = bridge.call(
            "create_sphere",
            {"name": "示例_球体", "radius": 12.0, "position": [0.0, 0.0, 0.0]},
        )
        print("created:", json.dumps(created, indent=2, ensure_ascii=False)[:600])

        info = bridge.call("get_object_info", {"name": "示例_球体"})
        print("read back:", json.dumps(info, indent=2, ensure_ascii=False)[:600])

        # The sphere was wrapped in theHold by the dispatcher, so one undo
        # removes it again. Nice demonstration of the undo contract.
        print("\n== undo (removing the demo sphere) ==")
        print(json.dumps(bridge.call("undo_last"), indent=2, ensure_ascii=False))

        print("\nAll good. Use this script as a template:")
        print("  bridge.call('list_objects', {'kind': 'geometry'})")
        print("  bridge.call('execute_maxscript', {'code': '$.count'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
