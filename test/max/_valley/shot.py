import json
import sys

sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge

out = sys.argv[1] if len(sys.argv) > 1 else r"D:\Workspace\MCP\3dsmax-mcp\test\max\_valley\preview_terrain.png"

b = Bridge()
print("look_through:", b.soft("cam_look_through", camera="CAM_Main").get("ok"))
print("shading:", b.soft("viewport_set_shading", mode="realistic").get("ok"))
code = 'fileIn @"D:\\Workspace\\Dev\\3dsmax-mcp\\test\\max\\_valley\\preview.ms"'
r = b.soft("execute_maxscript", code=code)
print(json.dumps(r, ensure_ascii=False)[:500])
print("stats:", json.dumps(b.soft("viewport_stats").get("result", {}), ensure_ascii=False)[:400])
b.close()
