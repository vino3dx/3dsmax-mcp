import json, sys
sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge
b = Bridge()
code = '''(
local out = ""
local r = ART_Renderer()
out += "class: " + ((classof r) as string) + "\\n"
for p in (getPropNames r) do out += (p as string) + " = " + (try ((getProperty r p) as string) catch "?") + "\\n"
out
)'''
r = b.soft("execute_maxscript", code=code)
print(json.dumps(r, ensure_ascii=False)[:5000])
b.close()
