import json, sys
sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge
b = Bridge()
code = r'''(
local out = ""
for o in objects do out += "  " + o.name + " class=" + ((classof o) as string) + " super=" + ((superclassof o) as string) + "\n"
out += "--- capture test ---\n"
local bmp = undefined
try ( bmp = gw.getViewportDib() ) catch ( out += "getViewportDib err: " + (getCurrentException()) + "\n" )
if bmp == undefined then out += "bmp undefined\n" else
(
  out += "bmp " + (bmp.width as string) + "x" + (bmp.height as string) + "\n"
  try ( save bmp "D://Workspace//Dev//3dsmax-mcp//test//max//_valley//_cap.png"; out += "saved, exists=" + ((doesFileExist "D://Workspace//Dev//3dsmax-mcp//test//max//_valley//_cap.png") as string) + "\n" ) catch ( out += "save err: " + (getCurrentException()) + "\n" )
)
out
)'''
print(json.dumps(b.soft("execute_maxscript", code=code), ensure_ascii=False)[:2000])
b.close()
