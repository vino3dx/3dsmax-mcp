"""Send two requests in a single segment, then report what comes back."""
import json
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 8765

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10.0)
s.connect((HOST, PORT))
payload = (
    json.dumps({"id": 31, "method": "bridge_status", "params": {}}) + "\n" +
    json.dumps({"id": 32, "method": "bridge_status", "params": {}}) + "\n"
)
s.sendall(payload.encode("ascii"))
print("SENT %d bytes (2 lines)" % len(payload), flush=True)
time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 6.0)
s.settimeout(2.0)
buf = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            print("EOF", flush=True)
            break
        buf += chunk
except Exception as exc:  # noqa: BLE001
    print("recv stopped: %s: %s" % (type(exc).__name__, exc), flush=True)
print("GOT %d bytes: %r" % (len(buf), buf[:300]), flush=True)
s.close()
