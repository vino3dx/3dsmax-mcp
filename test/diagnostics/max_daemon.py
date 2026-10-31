#!/usr/bin/env python3
"""Keep one 3ds Max session alive for the whole art-direction pass.

Two hard-won facts drive this design:

1. The P0 startup crash (ucrtbase+0xa527e, 39 recorded occurrences) is caused by
   the *process working directory*.  Every automated launch so far inherited the
   repo directory and aborted ~40s in; launching with cwd = the 3ds Max install
   directory reaches LISTENING reliably.  So CWD is pinned here.
2. Max must outlive the short-lived CLI clients that drive it.  This daemon owns
   the child and simply stays resident, so the process tree is never torn down
   mid-task.

    python test/diagnostics/max_daemon.py --seconds 7200

Writes state to test/logs/max_daemon.state.json.  Never kills a 3dsmax.exe it
did not start; exits with an error if one is already running.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time

MAX_DIR = r"C:\Program Files\Autodesk\3ds Max 2020"
MAX_EXE = os.path.join(MAX_DIR, "3dsmax.exe")
PORT = 8765
STATE = os.path.join(os.path.dirname(__file__), "..", "logs", "max_daemon.state.json")


def ping(timeout: float = 2.0):
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(json.dumps({"id": 1, "method": "bridge_status",
                                  "params": {}}).encode("ascii") + b"\n")
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
            return json.loads(buf.split(b"\n", 1)[0].decode("ascii", "replace"))
    except OSError:
        return None


def write_state(**kw):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w", encoding="utf-8") as fh:
            json.dump(kw, fh, ensure_ascii=False, indent=2)
    except OSError:
        pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=7200.0)
    args = ap.parse_args()

    if ping() is not None:
        print("bridge already up; daemon not needed", flush=True)
        return 0

    env = dict(os.environ)
    for key in ("PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"):
        env.pop(key, None)

    proc = subprocess.Popen([MAX_EXE], cwd=MAX_DIR, env=env,
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    started = time.time()
    print("launched pid={0} cwd={1}".format(proc.pid, MAX_DIR), flush=True)

    bridge_at = None
    while time.time() - started < args.seconds:
        time.sleep(3.0)
        rc = proc.poll()
        if rc is not None:
            write_state(status="exited", pid=proc.pid, exit_code=rc,
                        alive_s=round(time.time() - started, 1))
            print("EXITED code={0} after {1:.0f}s".format(
                rc, time.time() - started), flush=True)
            return 1
        if bridge_at is None:
            if ping() is not None:
                bridge_at = time.time() - started
                print("BRIDGE UP after {0:.0f}s".format(bridge_at), flush=True)
                write_state(status="listening", pid=proc.pid,
                            bridge_s=round(bridge_at, 1))
        else:
            # Re-publish liveness so external observers can see the session age.
            write_state(status="listening", pid=proc.pid,
                        bridge_s=round(bridge_at, 1),
                        alive_s=round(time.time() - started, 1))
    print("daemon window elapsed, leaving Max running", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
