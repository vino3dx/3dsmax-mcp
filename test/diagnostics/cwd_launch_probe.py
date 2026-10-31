#!/usr/bin/env python3
"""Minimal controlled launch probe: does the process CWD change the P0 crash?

Hypothesis (untested in docs/P0_ENV.md): every automated launch so far used
subprocess.Popen with CWD inherited from the repo directory, while every
surviving launch was started by hand from a shell whose CWD was the 3ds Max
install directory.  Relative plugin/resource resolution inside 3ds Max is
CWD sensitive, so this is a plausible -- and cheap to falsify -- difference.

This script starts 3ds Max EXACTLY ONCE with CWD = the install directory,
then polls the bridge port.  It never kills any process.

    python test/diagnostics/cwd_launch_probe.py [--seconds 150]
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=150.0)
    args = ap.parse_args()

    if ping() is not None:
        print("bridge already answering; nothing to do")
        return 0

    # Environment mirroring a desktop double-click as closely as possible.
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env.pop("VIRTUAL_ENV", None)

    started = time.time()
    proc = subprocess.Popen([MAX_EXE], cwd=MAX_DIR, env=env,
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    print("pid={0} cwd={1}".format(proc.pid, MAX_DIR), flush=True)

    bridge_at = None
    while time.time() - started < args.seconds:
        time.sleep(2.0)
        if proc.poll() is not None:
            print("EXITED after {0:.1f}s code={1}".format(
                time.time() - started, proc.poll()), flush=True)
            return 1
        if bridge_at is None:
            res = ping()
            if res and res.get("ok"):
                bridge_at = time.time() - started
                print("BRIDGE OK after {0:.1f}s".format(bridge_at), flush=True)
                print(json.dumps(res.get("result"), ensure_ascii=False)[:600], flush=True)
                return 0
    print("ALIVE {0:.1f}s, bridge never came up".format(time.time() - started), flush=True)
    return 2


if __name__ == "__main__":
    sys.exit(main())
