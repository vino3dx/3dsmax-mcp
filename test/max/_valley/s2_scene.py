import json
import sys

sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge

MATS = [
    ("M_Grass",      [127, 181,  60], 0.85),
    ("M_GrassDark",  [ 96, 148,  48], 0.88),
    ("M_Rock",       [139, 142, 147], 0.90),
    ("M_Sand",       [199, 177, 132], 0.95),
    ("M_Scree",      [110, 114, 120], 0.95),
    ("M_Water",      [ 47, 166, 198], 0.04),
    ("M_Trunk",      [106,  74,  46], 0.85),
    ("M_Conifer",    [ 46, 107,  57], 0.80),
    ("M_ConiferB",   [ 59, 125,  69], 0.80),
    ("M_Broadleaf",  [ 95, 168,  60], 0.78),
    ("M_BroadleafB", [116, 188,  74], 0.78),
    ("M_Wood",       [138,  90,  52], 0.82),
    ("M_Roof",       [184,  85,  60], 0.80),
    ("M_Stone",      [168, 163, 153], 0.88),
    ("M_Road",       [185, 154, 107], 0.95),
    ("M_Foam",       [234, 246, 248], 0.30),
]


def ok(r, label):
    good = r.get("ok")
    msg = "" if good else "  ERR: " + str((r.get("error") or {}).get("message"))[:300]
    print(("[ok] " if good else "[FAIL] ") + label + msg)
    return good


b = Bridge()

print("--- scene reset ---")
ok(b.soft("scene_new", keepScene=False), "scene_new")
ok(b.soft("set_units", systemType="meters", displayType="metric", scale=1.0), "set_units metres")

print("--- layers ---")
for nm in ["RV_Terrain", "RV_Water", "RV_Road", "RV_Bridge", "RV_Vegetation",
           "RV_Rocks", "RV_Landmarks", "RV_Lights"]:
    ok(b.soft("create_layer", name=nm), "layer " + nm)

print("--- materials ---")
for name, rgb, rough in MATS:
    ok(b.soft("mat_create_physical", name=name, baseColor=rgb, metallic=0.0, roughness=rough), name)

# water: transparency on Physical Material
r = b.soft("execute_maxscript",
           code='(local m = sceneMaterials["M_Water"]; if m != undefined then (m.transparency = 0.18; m.transparency_map = undefined); "ok")')
ok(r, "water transparency")

print("--- terrain multi-sub material ---")
ok(b.soft("mat_create_multi_sub", name="M_Terrain", count=4), "M_Terrain")
for idx, src in [(1, "M_Grass"), (2, "M_Rock"), (3, "M_Sand"), (4, "M_Scree")]:
    ok(b.soft("mat_set_sub_material", material="M_Terrain", index=idx, sourceMaterial=src), "slot %d <- %s" % (idx, src))

print("--- terrain build ---")
r = b.soft("execute_maxscript", code='fileIn @"D:\\Workspace\\Dev\\3dsmax-mcp\\test\\max\\_valley\\build_terrain.ms"')
if not r.get("ok"):
    print("FAILED:", json.dumps(r, ensure_ascii=False)[:3000])
    b.close()
    sys.exit(1)
print(r["result"].get("result", "")[:2000])

print("--- camera / light / env ---")
ok(b.soft("cam_create", type="target", name="CAM_Main",
          position=[-70.0, -560.0, 175.0], target=[10.0, 80.0, 35.0], fov=48.0), "camera")
ok(b.soft("light_create", type="directional", name="SUN", position=[300.0, -500.0, 650.0],
          color=[255, 244, 224], multiplier=1.0, castShadows=True), "sun")
ok(b.soft("execute_maxscript",
          code='(local l = getNodeByName "SUN"; if l != undefined and l.target != undefined do l.target.position = [0.0, 150.0, 0.0]; "ok")'),
   "sun target")
ok(b.soft("light_create", type="omni", name="FILL", position=[-260.0, -260.0, 220.0],
          color=[176, 202, 235], multiplier=0.22, castShadows=False, decay="none"), "fill")
ok(b.soft("env_set_background_color", color=[186, 220, 240]), "sky background")

r = b.soft("scene_statistics")
print(json.dumps(r.get("result", r), ensure_ascii=False)[:800])
b.close()
