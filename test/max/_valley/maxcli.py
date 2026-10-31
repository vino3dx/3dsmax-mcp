"""Minimal client for the 3ds Max MCP bridge (newline-delimited JSON over TCP).

Used when the MCP tools are not registered in the agent session; the wire
contract is the same one test/live/bridge_contract_test.py exercises.
"""
import json
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 8765


class Bridge(object):
    def __init__(self, host=HOST, port=PORT, timeout=180.0):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect((host, port))
        self.buf = b""
        self.n = 0

    def raw(self, method, params=None, timeout=180.0):
        self.n += 1
        req = {"id": self.n, "method": method, "params": params or {}}
        self.s.sendall((json.dumps(req) + "\n").encode("utf-8"))
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise IOError("bridge closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode("utf-8", "replace"))

    def call(self, method, **params):
        r = self.raw(method, params)
        if not r.get("ok"):
            raise RuntimeError("%s failed: %s" % (method, json.dumps(r, ensure_ascii=False)[:2000]))
        return r.get("result", r)

    def soft(self, method, **params):
        """Return the raw envelope; never raises on ok=false."""
        return self.raw(method, params)

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def wait_for_bridge(seconds=300):
    t0 = time.time()
    while time.time() - t0 < seconds:
        try:
            b = Bridge(timeout=10.0)
            r = b.raw("bridge_status", {})
            b.close()
            if r.get("ok"):
                return time.time() - t0, r
        except Exception:
            time.sleep(3.0)
    return None, None


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--wait":
        dt, r = wait_for_bridge()
        print("ready after %.1fs" % dt if dt else "TIMEOUT")
        print(json.dumps(r, ensure_ascii=False, indent=2)[:3000])
    else:
        b = Bridge()
        print(json.dumps(b.raw(sys.argv[1] if len(sys.argv) > 1 else "bridge_status", {}),
                         ensure_ascii=False, indent=2)[:4000])
        b.close()
