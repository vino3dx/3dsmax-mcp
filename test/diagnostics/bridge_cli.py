#!/usr/bin/env python3
"""Thin CLI over the in-Max bridge for the art-direction pass.

The WorkBuddy session has no MCP connector registered, so this talks to the
same newline-delimited JSON TCP endpoint that maxmcp's Bridge would use --
identical wire format, identical commands, identical results.

    python test/diagnostics/bridge_cli.py --method scene_info
    python test/diagnostics/bridge_cli.py --method run_script --code-file x.ms
    echo '{"method":"scene_info"}' | python ... --stdin
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
import time

PORT = 8765
_counter = 0


class Bridge:
    def __init__(self, host: str = "127.0.0.1", port: int = PORT,
                 timeout: float = 600.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = socket.create_connection((host, port), timeout=10.0)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def call(self, method: str, params=None, timeout=None):
        global _counter
        _counter += 1
        payload = {"id": _counter, "method": method,
                   "params": params or {}, "lang": "en"}
        line = json.dumps(payload, ensure_ascii=True,
                          separators=(",", ":")) + "\n"
        self.sock.sendall(line.encode("ascii"))
        deadline = time.time() + (timeout or self.timeout)
        buf = bytearray()
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("bridge timeout on " + method)
            self.sock.settimeout(min(remaining, 5.0))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError("bridge closed")
            buf.extend(chunk)
            idx = buf.find(b"\n")
            if idx >= 0:
                data = json.loads(bytes(buf[:idx]).decode("ascii", "replace"))
                if data.get("ok"):
                    return data.get("result")
                raise RuntimeError(json.dumps(data.get("error"),
                                              ensure_ascii=False)[:2000])

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method")
    ap.add_argument("--params", default="{}")
    ap.add_argument("--code")
    ap.add_argument("--code-file")
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--stdin", action="store_true")
    args = ap.parse_args()

    b = Bridge(timeout=args.timeout)
    try:
        if args.stdin:
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                req = json.loads(line)
                print(json.dumps(b.call(req["method"], req.get("params", {})),
                                 ensure_ascii=False, indent=2))
            return 0
        if args.code_file:
            code = open(args.code_file, "r", encoding="utf-8").read()
            res = b.call("execute_maxscript", {"code": code},
                         timeout=args.timeout)
        elif args.code:
            res = b.call("execute_maxscript", {"code": args.code},
                         timeout=args.timeout)
        else:
            res = b.call(args.method, json.loads(args.params),
                         timeout=args.timeout)
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0
    finally:
        b.close()


if __name__ == "__main__":
    sys.exit(main())
