import json
import sys

sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge

MATS = [
    ("M_Grass",     [127, 181, 60],  0.0, 0.85),
    ("M_GrassDark", [ 96, 148, 48],  0.0, 0.88),
    ("M_Rock",      [139, 142, 147], 0.0, 0.90),
    ("M_Sand",      [199, 177, 132], 0.0, 0.95),
    ("M_Scree",     [110, 114, 120], 0.0, 0.95),
    ("M_Water",     [ 47, 166, 198], 0.0, 0.04),
    ("M_Trunk",     [106,  74,  46], 0.0, 0.85),
    ("M_Conifer",   [ 46, 107,  57], 0.0, 0.80),
    ("M_ConiferB",  [ 59, 125,  69], 0.0, 0.80),
    ("M_Broadleaf", [ 95, 168,  60], 0.0, 0.78),
    ("M_BroadleafB",[116, 188,  74], 0.0, 0.78),
    ("M_Wood",      [138,  90,  52], 0.0, 0.82),
    ("M_Roof",      [184,  85,  60], 0.0, 0.80),
    ("M_Stone",     [168, 163, 153], 0.0, 0.88),
    ("M_Road",      [185, 154, 107], 0.0, 0.95),
    ("M_Foam",      [234, 246, 248], 0.0, 0.30),
]

b = Bridge()
for name, rgb, metal, rough in MATS:
    r = b.soft("mat_create_physical", name=name, baseColor=rgb, metallic=metal, roughness=rough)
    print(name, "->", r.get("ok"), (r.get("error") or {}).get("message", "")[:120])

r = b.soft("mat_set_opacity", material="M_Water", opacity=0.86)
print("water opacity ->", r.get("ok"), (r.get("error") or {}).get("message", "")[:160])

r = b.soft("mat_list")
print(json.dumps(r, ensure_ascii=False)[:1500])
b.close()
