"""Wire-contract test for the 3ds Max MCP bridge.

One connection, several requests, one JSON line expected per request.
Proves that error paths answer with JSON instead of dropping the socket,
and that the connection keeps working afterwards.
"""
import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 8765


class Conn(object):
    def __init__(self, timeout=12.0):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect((HOST, PORT))
        self.buf = b""

    def send_raw(self, text):
        self.s.sendall((text + "\n").encode("ascii", "replace"))

    def read_line(self, timeout=12.0):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace")

    def close(self):
        try:
            self.s.close()
        except Exception:  # noqa: BLE001
            pass


CASES = [
    ("valid/status", json.dumps({"id": 1, "method": "bridge_status", "params": {}}),
     {"want_ok": True, "want_id": 1}),
    ("unknown/method", json.dumps({"id": 2, "method": "no_such_method_xyz", "params": {}}),
     {"want_ok": False, "want_id": 2, "want_err_key": True}),
    ("bad/param", json.dumps({"id": 3, "method": "create_box", "params": {"position": "not-a-vector"}}),
     {"want_ok": False, "want_id": 3, "want_err_key": True}),
    ("malformed/json", "this is plainly not json",
     {"want_ok": False, "want_id": 0, "want_err_key": True}),
    ("string/id", json.dumps({"id": "req-abc", "method": "bridge_status", "params": {}}),
     {"want_ok": True, "want_id": "req-abc"}),
    ("recover/after-errors", json.dumps({"id": 6, "method": "bridge_status", "params": {}}),
     {"want_ok": True, "want_id": 6}),
]


def main():
    results = []
    conn = Conn()
    for name, raw, want in CASES:
        conn.send_raw(raw)
        try:
            line = conn.read_line()
        except socket.timeout:
            results.append((name, False, "no response within timeout (socket alive but silent)"))
            continue
        except Exception as exc:  # noqa: BLE001
            results.append((name, False, "recv failed: %s: %s" % (type(exc).__name__, exc)))
            break
        if line is None:
            results.append((name, False, "server closed the connection"))
            break
        try:
            obj = json.loads(line)
        except Exception as exc:  # noqa: BLE001
            results.append((name, False, "response is not JSON (%s): %r" % (exc, line[:200])))
            continue
        ok = obj.get("ok")
        problems = []
        if ok is not want["want_ok"]:
            problems.append("ok=%r want %r" % (ok, want["want_ok"]))
        if want.get("want_id") is not None and obj.get("id") != want["want_id"]:
            problems.append("id=%r want %r" % (obj.get("id"), want["want_id"]))
        if want.get("want_err_key") and not obj.get("error"):
            problems.append("missing error object on failure")
        summary = "ok=%r id=%r keys=%s" % (ok, obj.get("id"), sorted(obj.keys()))
        if ok is False and obj.get("error"):
            summary += " kind=%r" % (obj["error"].get("kind"),)
        results.append((name, not problems, summary + ("" if not problems else "  <-- " + "; ".join(problems))))
    conn.close()

    print("=== bridge wire contract ===")
    bad = 0
    for name, passed, detail in results:
        print("%-22s %s  %s" % (name, "PASS" if passed else "FAIL", detail))
        if not passed:
            bad += 1
    print("--- %d/%d passed ---" % (len(results) - bad, len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
