"""Raw TCP probe against the 3ds Max MCP bridge.

Sends newline-delimited JSON requests and prints exactly what comes back,
so failures can be attributed to the bridge (MAXScript) rather than the
MCP client layer.
"""
import json
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 8765


def send(payload, timeout=8.0, wait_after=1.0):
    line = json.dumps(payload, ensure_ascii=True) + "\n"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((HOST, PORT))
    except Exception as exc:  # noqa: BLE001
        print("CONNECT-FAIL %s: %s" % (type(exc).__name__, exc))
        s.close()
        return None
    print("CONNECT-OK")
    try:
        s.sendall(line.encode("ascii"))
        print("SENT %s" % line.strip())
    except Exception as exc:  # noqa: BLE001
        print("SEND-FAIL %s: %s" % (type(exc).__name__, exc))
        s.close()
        return None
    time.sleep(wait_after)
    buf = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                print("EOF (server closed)")
                break
            buf += chunk
            if b"\n" in chunk:
                break
    except socket.timeout:
        print("RECV-TIMEOUT after %.1fs" % timeout)
    except Exception as exc:  # noqa: BLE001
        print("RECV-FAIL %s: %s" % (type(exc).__name__, exc))
    s.close()
    text = buf.decode("utf-8", "replace").strip()
    print("RECV-RAW %r" % text[:2000])
    if text:
        try:
            obj = json.loads(text.splitlines()[0])
            print("RECV-JSON keys=%s ok=%s" % (sorted(obj.keys()), obj.get("ok")))
            return obj
        except Exception as exc:  # noqa: BLE001
            print("NOT-JSON %s" % exc)
    return None


if __name__ == "__main__":
    req = {"id": "probe-1", "cmd": "bridge_status", "params": {}}
    if len(sys.argv) > 1:
        req = json.loads(sys.argv[1])
    print("=== tcp probe %s:%d ===" % (HOST, PORT))
    send(req)
