#!/usr/bin/env python3
"""Low-cost preview renderer for the art-direction iterations.

ART's `enable_time` is on with a 55 s budget, so render cost is driven by the
time budget, not the pixel count.  Every preview therefore runs at a reduced
resolution AND a short time budget, and always restores the exact settings it
found -- so a preview never contaminates the scene's real render setup.

    python test/diagnostics/preview.py --out renders/_prev/p01.png
    python test/diagnostics/preview.py --out x.png --w 480 --h 600 --seconds 10
"""
from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_cli import Bridge  # noqa: E402

RENDERER = "ART_Renderer"

SET = """
(
    local r = renderers.current
    if (classOf r) as string != "%s" do ( format "WRONG_RENDERER:%%\\n" ((classOf r) as string) )
    renderWidth = %d
    renderHeight = %d
    try ( r.enable_time = true ) catch()
    try ( r.time_in_seconds = %d ) catch()
    try ( r.iterations = %d ) catch()
    "preview settings applied"
)
"""

RESTORE = """
(
    local r = renderers.current
    renderWidth = %d
    renderHeight = %d
    try ( r.enable_time = %s ) catch()
    try ( r.time_in_seconds = %d ) catch()
    try ( r.iterations = %d ) catch()
    "preview settings restored"
)
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--w", type=int, default=480)
    ap.add_argument("--h", type=int, default=600)
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--iterations", type=int, default=12)
    args = ap.parse_args()

    b = Bridge(timeout=900)
    try:
        # remember the authored settings
        orig = b.call("execute_maxscript", {"code":
            "( local r = renderers.current; "
            "local t = 55; local en = true; local it = 50; "
            "try ( t = r.time_in_seconds ) catch(); "
            "try ( en = r.enable_time ) catch(); "
            "try ( it = r.iterations ) catch(); "
            "format \"%%|%%|%%|%%|%%\\n\" renderWidth renderHeight en t it )"})
        raw = (orig.get("result") or "").strip()
        ow, oh, oen, ot, oit = raw.split("|")
        ow, oh, oit = int(float(ow)), int(float(oh)), int(float(oit))
        ot = int(float(ot))
        oen = oen.strip().lower() == "true"

        b.call("execute_maxscript", {"code": SET % (
            RENDERER, args.w, args.h, args.seconds, args.iterations)})

        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        t0 = time.time()
        res = b.call("render_still", {"path": out, "frame": 0}, timeout=900)
        dt = time.time() - t0
        print("rendered {0} in {1:.1f}s -> {2}".format(
            res.get("written"), dt, res.get("path")))

        b.call("execute_maxscript", {"code": RESTORE % (
            ow, oh, "true" if oen else "false", ot, oit)})
        return 0 if res.get("written") else 1
    finally:
        b.close()


if __name__ == "__main__":
    sys.exit(main())
