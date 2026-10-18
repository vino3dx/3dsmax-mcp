"""Mock 3ds Max bridge: speaks the same newline-delimited JSON protocol.

Used only to test whether the MCP server child process can reach loopback.
"""
import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
LOG = r"D:\Workspace\Dev\3dsmax-mcp\test\logs\mock_bridge.log"


def log(msg):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


def serve(conn):
    buf = b""
    with conn:
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    req = json.loads(line.decode("ascii"))
                except ValueError:
                    continue
                log("REQ " + json.dumps(req, ensure_ascii=True))
                rid = req.get("id", 0)
                method = req.get("method", "")
                if method == "bridge_status":
                    result = {
                        "running": True, "host": "127.0.0.1", "port": PORT,
                        "clients": 1, "timerActive": True, "language": "en",
                        "handlerCount": 375, "maxYear": 2020,
                        "message": "MOCK BRIDGE - not a real 3ds Max",
                    }
                else:
                    result = {"mock": True, "method": method}
                resp = json.dumps({"id": rid, "ok": True, "result": result},
                                  ensure_ascii=True, separators=(",", ":")) + "\n"
                conn.sendall(resp.encode("ascii"))


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(8)
    log(f"mock bridge listening on 127.0.0.1:{PORT}")
    print(f"mock bridge listening on 127.0.0.1:{PORT}", flush=True)
    while True:
        conn, addr = srv.accept()
        log(f"ACCEPT {addr}")
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
