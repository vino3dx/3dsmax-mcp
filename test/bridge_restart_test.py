"""Repeated-start test.

Asks the bridge to start again while it is already listening.  The in-flight
response is expected to be lost (mcpNetStart stops the listener and closes the
open sockets first), so the real question is whether the bridge comes back:
after the restart a fresh connection must answer bridge_status again and the
port must still be 8765.
"""
import json
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 8765


def request(payload, timeout=8.0, read=True):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    s.sendall((json.dumps(payload) + "\n").encode("ascii"))
    if not read:
        s.close()
        return None
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except Exception:  # noqa: BLE001
        pass
    s.close()
    text = buf.decode("utf-8", "replace").strip()
    if not text:
        return None
    try:
        return json.loads(text.splitlines()[0])
    except Exception:  # noqa: BLE001
        return {"raw": text}


def main():
    print("=== repeated start ===")
    print("1) first bridge_status")
    first = request({"id": 1, "method": "bridge_status", "params": {}})
    ok1 = bool(first and first.get("ok"))
    print("   ok=%s clients=%s" % (ok1, (first or {}).get("result", {}).get("clients")))

    print("2) ask for a second mcpNetStart() while already listening")
    second = request({"id": 2, "method": "execute_maxscript", "params": {"code": "mcpNetStart()"}}, timeout=6.0)
    print("   response: %s" % ("lost (expected)" if second is None else json.dumps(second)[:160]))

    time.sleep(4.0)

    print("3) reconnect and bridge_status again")
    last = None
    for attempt in range(6):
        try:
            last = request({"id": 3, "method": "bridge_status", "params": {}}, timeout=6.0)
            if last and last.get("ok"):
                break
        except Exception as exc:  # noqa: BLE001
            print("   attempt %d: %s: %s" % (attempt + 1, type(exc).__name__, exc))
        time.sleep(1.5)

    res = (last or {}).get("result", {}) or {}
    ok3 = bool(last and last.get("ok")) and res.get("port") == PORT and res.get("running") is True
    print("   ok=%s running=%s port=%s clients=%s"
          % (bool(last and last.get("ok")), res.get("running"), res.get("port"), res.get("clients")))

    passed = ok1 and ok3
    print("%s" % ("PASS" if passed else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
