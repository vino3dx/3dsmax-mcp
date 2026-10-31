#!/usr/bin/env python3
"""Working helper for the art-direction pass.

Every scene write goes through `save_verified()`, which saves and then reloads
the file to prove the object count survived.  A corrupt save is caught
immediately instead of being discovered three iterations later.

    python test/diagnostics/art.py status
    python test/diagnostics/art.py ms test/diagnostics/ms/foo.ms
    python test/diagnostics/art.py save test/max/gundam_canyon_battlefield_v2.max
    python test/diagnostics/art.py preview test/max/renders/_prev/p01.png --seconds 10
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_cli import Bridge  # noqa: E402


def run(b, code, timeout=900):
    return b.call("execute_maxscript", {"code": code}, timeout=timeout)


def count(b):
    r = run(b, "objects.count")
    return int(float(r.get("result")))


def save_verified(b, path, expect=None):
    """Save, then reopen the file and count. Returns (ok, count)."""
    if expect is None:
        expect = count(b)
    p = path.replace("\\", "/")
    run(b, 'saveMaxFile @"%s"\nobjects.count' % p)
    r = run(b, 'loadMaxFile @"%s" useFileUnits:true quiet:true\nobjects.count' % p)
    got = int(float(r.get("result")))
    return got == expect, got, expect


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["status", "ms", "save", "preview", "count"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--w", type=int, default=480)
    ap.add_argument("--h", type=int, default=600)
    ap.add_argument("--expect", type=int, default=None)
    args = ap.parse_args()

    b = Bridge(timeout=900)
    try:
        if args.cmd == "status":
            print(json.dumps(b.call("bridge_status"), ensure_ascii=False, indent=1))
        elif args.cmd == "count":
            print(count(b))
        elif args.cmd == "ms":
            code = open(args.arg, encoding="utf-8").read()
            print(json.dumps(run(b, code), ensure_ascii=False)[:4000])
        elif args.cmd == "save":
            ok, got, exp = save_verified(b, args.arg, args.expect)
            print("save {0}: expect={1} got={2} {3}".format(
                args.arg, exp, got, "OK" if ok else "MISMATCH"))
            return 0 if ok else 1
        elif args.cmd == "preview":
            out = os.path.abspath(args.arg)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            # ART cost is driven by its time budget, so shrink both knobs.
            run(b, 'renderWidth=%d\nrenderHeight=%d\n'
                   'renderers.current.enable_time=true\n'
                   'renderers.current.time_in_seconds=%d' % (args.w, args.h, args.seconds))
            t0 = time.time()
            res = b.call("render_still", {"path": out, "frame": 0}, timeout=1800)
            print("rendered in {0:.1f}s -> {1}".format(time.time() - t0, res.get("path")))
            run(b, 'renderWidth=1280\nrenderHeight=1600\n'
                   'renderers.current.time_in_seconds=55')
            return 0 if res.get("written") else 1
    finally:
        b.close()


if __name__ == "__main__":
    sys.exit(main())
