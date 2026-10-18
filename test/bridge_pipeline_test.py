"""Pipelining test: several requests written in one TCP segment.

This is the case the default 1 KB StreamReader buffer broke -- the reader
swallowed every line after the first, DataAvailable reported zero bytes and
only one request was ever answered.
"""
import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 8765


def run():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(15.0)
    s.connect((HOST, PORT))

    ids = [21, 22, 23, 24]
    payload = "".join(
        json.dumps({"id": i, "method": "bridge_status", "params": {}}) + "\n" for i in ids
    )
    s.sendall(payload.encode("ascii"))

    buf = b""
    got = []
    while len(got) < len(ids):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                got.append(json.loads(line.decode("utf-8")))
    s.close()

    print("=== pipelining (4 requests, one segment) ===")
    print("sent ids      : %s" % ids)
    print("received ids  : %s" % [g.get("id") for g in got])
    print("all ok        : %s" % all(g.get("ok") for g in got))
    ok = [g.get("id") for g in got] == ids and all(g.get("ok") for g in got)
    print("%s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(run())
