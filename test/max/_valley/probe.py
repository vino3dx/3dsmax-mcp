import json, sys
sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge

b = Bridge()
for m, p in [("list_render_engines", {}), ("get_units", {}), ("scene_info", {}),
             ("list_scene_classes", {}), ("get_max_version", {})]:
    r = b.soft(m, **p)
    print("==", m, "ok=", r.get("ok"))
    print(json.dumps(r.get("result", r), ensure_ascii=False)[:2500])
    print()
b.close()
