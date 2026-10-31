import json, sys
sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge
b = Bridge()
code = '''(
local out = ""
out += "setFaceMatID global: " + ((isKindOf setFaceMatID MAXScriptFunction) as string) + "\\n"
out += "objects: " + (objects.count as string) + "\\n"
for o in objects do out += "  " + o.name + " v=" + (try (o.numverts as string) catch "-") + " f=" + (try (o.numfaces as string) catch "-") + "\\n"
out
)'''
print(json.dumps(b.soft("execute_maxscript", code=code), ensure_ascii=False)[:1500])
b.close()
