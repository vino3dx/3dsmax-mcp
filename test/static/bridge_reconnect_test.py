"""Acceptance check: a bridge connection recovers after it drops.

No 3ds Max required.  This exercises the *client* half of "断线后能够恢复"
against a fake bridge that speaks the same newline-delimited JSON protocol.

Why this exists
---------------
The first attempt to verify recovery stopped the bridge from the Max side with
`mcpNetStop()`.  That also stops the 25 ms pump, which is the only code that
ever runs in Max, so nothing could bring the listener back -- the experiment
measured a one-way door, not a reconnect.  (See bridge_recovery_test.py for the
panel-side fix so that door can be reopened.)

Recovery has to be tested from the outside: the peer goes away, the peer comes
back, and the *same* MaxBridge object must work again without being rebuilt.

Checks:
  1. a healthy peer answers and the client stays on one connection;
  2. when the peer disappears, the call fails loudly instead of hanging or
     returning stale data, and the client notices it is disconnected;
  3. after the peer returns on the same port, the next call succeeds and opens
     exactly one new connection -- no restart of the process, no new client;
  4. a non-protocol reply (the HTML error page that a wrong port returns) is a
     protocol error, not a parse crash, and the client recovers from it too.

Usage:  python test/static/bridge_reconnect_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "src", "python"))

from maxmcp.bridge import BridgeNotRunning, BridgeProtocolError, MaxBridge  # noqa: E402
from maxmcp.config import Config  # noqa: E402

FAILURES = []
HTML_PAGE = "<!DOCTYPE HTML><html><body>405 Method Not Allowed</body></html>\n"


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


class FakeBridge:
    """Minimal stand-in for the in-Max bridge, reopenable on the same port."""

    def __init__(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        self.port = probe.getsockname()[1]
        probe.close()
        self.sock = None
        self.running = False
        self.accepted = 0
        self.mode = "ok"
        self._threads = []
        self._conns = []

    def open_listener(self):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", self.port))
        s.listen(8)
        self.sock = s
        self.running = True
        t = threading.Thread(target=self._accept_loop, daemon=True)
        t.start()
        self._threads.append(t)

    def _accept_loop(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            self._conns.append(conn)
            t = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            t.start()
            self._threads.append(t)

    def _serve(self, conn):
        buf = b""
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                except ValueError:
                    continue
                if self.mode == "html":
                    reply = HTML_PAGE
                else:
                    # Wire shape: {"id": n, "ok": true, "result": {...}}
                    reply = json.dumps(
                        {
                            "id": request.get("id"),
                            "ok": True,
                            "result": {"ok": True, "method": request.get("method")},
                        }
                    ) + "\n"
                try:
                    conn.sendall(reply.encode("ascii"))
                except OSError:
                    return

    def stop(self):
        """Disappear the way a killed bridge does: listener gone, sockets cut."""
        self.running = False
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        for conn in self._conns:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        self._conns = []
        time.sleep(0.05)


def main() -> int:
    fake = FakeBridge()
    bridge = MaxBridge(
        Config(port=fake.port, port_scan=0, timeout_s=5.0, connect_timeout_s=1.0, language="en")
    )

    print("1. healthy peer")
    fake.open_listener()
    try:
        result = bridge.call("bridge_ping")
        check("call returns the peer's payload", result.get("ok") is True, repr(result))
        check("one connection so far", fake.accepted == 1, "accepted=%d" % fake.accepted)
        check("client reports connected", bridge.connected is True)
    finally:
        pass

    print("2. peer disappears")
    fake.stop()
    raised = None
    try:
        bridge.call("bridge_ping")
    except BridgeNotRunning as exc:
        raised = exc
    except Exception as exc:  # noqa: BLE001 - any other type is a failure
        raised = exc
    check("call fails instead of hanging", raised is not None)
    check("failure is BridgeNotRunning, not a raw OSError",
          isinstance(raised, BridgeNotRunning),
          type(raised).__name__ if raised else "no exception")
    check("client notices it is disconnected", bridge.connected is False)

    print("3. peer comes back on the same port")
    fake.open_listener()
    try:
        result = bridge.call("bridge_ping")
        check("the same client object works again", result.get("ok") is True, repr(result))
        check("exactly one new connection was made", fake.accepted == 2,
              "accepted=%d" % fake.accepted)
        check("client reports connected again", bridge.connected is True)
    finally:
        fake.stop()
        bridge.close()

    print("4. a wrong port answers with HTML")
    fake2 = FakeBridge()
    fake2.mode = "html"
    fake2.open_listener()
    bridge2 = MaxBridge(
        Config(port=fake2.port, port_scan=0, timeout_s=5.0, connect_timeout_s=1.0, language="en")
    )
    raised = None
    try:
        bridge2.call("bridge_ping")
    except BridgeProtocolError as exc:
        raised = exc
    except Exception as exc:  # noqa: BLE001
        raised = exc
    check("HTML reply is a protocol error", isinstance(raised, BridgeProtocolError),
          type(raised).__name__ if raised else "no exception")
    check("the error quotes the offending line",
          raised is not None and "DOCTYPE" in str(raised),
          str(raised)[:120])
    fake2.mode = "ok"
    try:
        result = bridge2.call("bridge_ping")
        check("recovers once the peer speaks the protocol again",
              result.get("ok") is True, repr(result))
    finally:
        fake2.stop()
        bridge2.close()

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("bridge reconnect: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
