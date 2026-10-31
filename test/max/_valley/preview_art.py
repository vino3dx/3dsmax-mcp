"""Fast ART preview render from the scene camera."""
import json
import sys
import time

sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge

out = sys.argv[1] if len(sys.argv) > 1 else r"D:/Workspace/MCP/3dsmax-mcp/test/max/_valley/preview_art.png"
w = int(sys.argv[2]) if len(sys.argv) > 2 else 640
h = int(sys.argv[3]) if len(sys.argv) > 3 else 360
it = int(sys.argv[4]) if len(sys.argv) > 4 else 4

b = Bridge()
b.soft("render_set_engine", engine="art")
b.soft("render_set_resolution", width=w, height=h)
b.soft("execute_maxscript",
       code='(local r = renderers.production; r.enable_iterations = true; r.iterations = %d; r.render_method = 1; "ok")' % it)
t0 = time.time()
r = b.soft("render_camera_view", camera="CAM_Main", path=out, frame=0)
print(json.dumps(r, ensure_ascii=False)[:600])
print("%.1fs" % (time.time() - t0))
b.close()
