"""Set the scene camera from Python and render quick ART previews."""
import json
import sys
import time

sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge


def cam_code(pos, tgt, fov):
    return (
        '(local c = getNodeByName "CAM_Main"; '
        'if c == undefined do ( c = Freecamera(); c.name = "CAM_Main" ); '
        'local dv = normalize ([%f,%f,%f] - [%f,%f,%f]); '
        'local zA = -dv; '
        'local xA = normalize (cross [0.0,0.0,1.0] zA); '
        'local yA = normalize (cross zA xA); '
        'c.transform = matrix3 xA yA zA [%f,%f,%f]; '
        'c.fov = %f; '
        '"dir=" + ((c.dir) as string))'
        % (tgt[0], tgt[1], tgt[2], pos[0], pos[1], pos[2],
           pos[0], pos[1], pos[2], fov)
    )


def setcam(b, pos, tgt, fov=48.0):
    r = b.soft("execute_maxscript", code=cam_code(pos, tgt, fov))
    if not r.get("ok"):
        print("cam fail", r)
    return r


def shot(b, path, w=640, h=360, it=4):
    b.soft("render_set_resolution", width=w, height=h)
    b.soft("execute_maxscript",
           code='(local r = renderers.production; r.enable_iterations = true; r.iterations = %d; "ok")' % it)
    t0 = time.time()
    r = b.soft("render_camera_view", camera="CAM_Main", path=path, frame=0)
    return r.get("ok"), time.time() - t0


if __name__ == "__main__":
    b = Bridge()
    b.soft("render_set_engine", engine="art")
    variants = [
        ("A", [-20.0, -560.0, 90.0], [25.0, 60.0, 30.0], 52.0),
        ("B", [-30.0, -520.0, 130.0], [20.0, 120.0, 30.0], 48.0),
        ("C", [-10.0, -580.0, 62.0], [30.0, 40.0, 28.0], 55.0),
    ]
    for tag, pos, tgt, fov in variants:
        setcam(b, pos, tgt, fov)
        ok, dt = shot(b, r"D:\Workspace\MCP\3dsmax-mcp\test\max\_valley\cam_%s.png" % tag)
        print(tag, ok, "%.1fs" % dt)
    b.close()
