-- Minimal probe: run under 3dsmaxbatch.exe to see if scripts execute at all.
local out = ""
try
(
    local b = Box length:10 width:10 height:10 name:"__batch_probe_box"
    out = "created box: " + b.name + " verts=" + ((getPolygonCount b)[2] as string) + " faces=" + ((getPolygonCount b)[1] as string)
    delete b
)
catch ( out = "ERROR: " + (getCurrentException()) )

local f = createFile @"D:\Workspace\Dev\3dsmax-mcp\test\logs\batch_probe_result.txt"
format "%" out to:f
close f
print out
