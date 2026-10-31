-- Stage 0 / read-only inventory.
-- Writes a tab-delimited report to disk so the Python side can parse freely;
-- the bridge response stays tiny and nothing in the scene is touched.
(
    local p  = @"D:\Workspace\MCP\3dsmax-mcp\test\max\gundam_canyon_battlefield.max"
    local out = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\stage0_inventory.tsv"
    loadMaxFile p useFileUnits:true quiet:true

    local f = createFile out
    format "SCENE\t%\n" (maxFileName) to:f
    local objs = objects as array
    format "TOTAL\t%\n" objs.count to:f

    for o in objs do (
        local sc = "other"
        try ( sc = (superClassOf o) as string ) catch()
        local cls = "-"; try ( cls = (classOf o) as string ) catch()
        local nv = 0; try ( nv = (getPolygonCount o)[1] ) catch()
        local nf = 0; try ( nf = (getPolygonCount o)[2] ) catch()
        local pos = point3 0 0 0; try ( pos = o.pos ) catch()
        local mi = -1
        try ( if o.material != undefined do mi = (findItem sceneMaterials o.material) ) catch()
        local mn = "-"; try ( if o.material != undefined do mn = o.material.name ) catch()
        local bb = "-"
        try ( bb = ((o.min - o.pos) as string) + "|" + ((o.max - o.pos) as string) ) catch()
        local par = "-"; try ( if o.parent != undefined do par = o.parent.name ) catch()
        format "OBJ\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\n" o.name sc cls nv nf pos.x pos.y pos.z mi mn bb par to:f
    )

    for m in sceneMaterials do (
        local cls = "-"; try ( cls = (classOf m) as string ) catch()
        local dif = "-"; try ( dif = (m.diffuse as string) ) catch()
        local spc = "-"; try ( spc = (m.specular as string) ) catch()
        local gl = -1; try ( gl = m.glossiness ) catch()
        local op = -1; try ( op = m.opacity ) catch()
        local em = "-"; try ( em = (m.selfIllumColor as string) ) catch()
        format "MAT\t%\t%\t%\t%\t%\t%\t%\n" m.name cls dif spc gl op em to:f
    )

    local lc = LayerManager.count
    for i = 0 to lc-1 do (
        local L = LayerManager.getLayer i
        local nn = 0; try ( nn = L.getNumNodes() ) catch()
        format "LAYER\t%\t%\n" L.name nn to:f
    )

    for o in (for x in objs where (superClassOf x == Light) collect x) do (
        local mp = -1; try ( mp = o.multiplier ) catch()
        local cl = "-"; try ( cl = (classOf o) as string ) catch()
        local sh = -1; try ( sh = o.baseObject.castShadows ) catch()
        format "LIGHT\t%\t%\t%\t%\t%\t%\t%\n" o.name cl o.pos.x o.pos.y o.pos.z mp sh to:f
    )

    for o in (for x in objs where (superClassOf x == Camera) collect x) do (
        local fv = -1; try ( fv = o.fov ) catch()
        local tg = point3 0 0 0; try ( tg = o.target.pos ) catch()
        format "CAM\t%\t%\t%\t%\t%\t%\t%\t%\n" o.name (classOf o) o.pos.x o.pos.y o.pos.z tg.x tg.y tg.z fv to:f
    )

    format "RENDER\t%\t%\t%\n" (classOf renderers.current) renderWidth renderHeight to:f
    format "WORLD\t%\t%\t%\n" (backgroundColor as string) (ambientColor as string) (units.SystemType as string) to:f
    close f
    "inventory written"
)
