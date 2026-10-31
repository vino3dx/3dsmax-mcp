-- Read-only: count the source mecha scene, then restore the canyon scene.
(
    local src  = @"D:\Workspace\MCP\3dsmax-mcp\test\max\gundam_mecha_apose.max"
    local back = @"D:\Workspace\MCP\3dsmax-mcp\test\max\gundam_canyon_battlefield.max"
    local out  = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\stage0_mecha.tsv"

    loadMaxFile src useFileUnits:true quiet:true
    local objs = objects as array
    local f = createFile out
    format "TOTAL\t%\n" objs.count to:f
    for o in objs do (
        local sc = "other"; try ( sc = (superClassOf o) as string ) catch()
        local cls = "-";   try ( cls = (classOf o) as string ) catch()
        local lay = "-";   try ( lay = o.layer.name ) catch()
        format "OBJ\t%\t%\t%\t%\n" o.name sc cls lay to:f
    )
    close f

    loadMaxFile back useFileUnits:true quiet:true
    format "mecha objects: %, restored: %\n" objs.count (maxFileName)
)
