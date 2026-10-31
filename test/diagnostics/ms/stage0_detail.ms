-- Stage 0b / read-only: detailed probe of camera, lights, hero geometry.
(
    local out = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\stage0_detail.tsv"
    local f = createFile out

    -- camera
    for o in (for x in objects where (superClassOf x == Camera) collect x) do (
        local tgt = point3 0 0 0
        local dist = 0
        try ( tgt = o.target.pos; dist = distance o.pos tgt ) catch()
        format "CAM\t%\t%\t%\t%\t%\t%\t%\t%\t%\n" o.name (classOf o) o.pos.x o.pos.y o.pos.z tgt.x tgt.y tgt.z o.fov dist to:f
    )

    -- lights with target + size
    for o in (for x in objects where (superClassOf x == Light) collect x) do (
        local tgt = point3 0 0 0; local hasT = 0
        try ( tgt = o.target.pos; hasT = 1 ) catch()
        local w = -1; local h = -1
        try ( w = o.width; h = o.height ) catch()
        local col = "-"; try ( col = (o.rgb as string) ) catch()
        local en = -1;  try ( en = o.enabled ) catch()
        format "LIGHT\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\t%\n" o.name (classOf o) o.pos.x o.pos.y o.pos.z tgt.x tgt.y tgt.z (try (o.multiplier) catch(-1)) w h col en to:f
    )

    -- hero: gundam bbox
    local ms = for o in objects where (substring o.name 1 3 == "MS_") collect o
    local mn = point3 1e9 1e9 1e9
    local mx = point3 -1e9 -1e9 -1e9
    for o in ms do (
        try (
            mn.x = amin mn.x o.min.x; mn.y = amin mn.y o.min.y; mn.z = amin mn.z o.min.z
            mx.x = amax mx.x o.max.x; mx.y = amax mx.y o.max.y; mx.z = amax mx.z o.max.z
        ) catch()
    )
    format "GUNDAM_BBOX\t%\t%\t%\t%\t%\t%\n" mn.x mn.y mn.z mx.x mx.y mx.z to:f

    -- big environment objects: bounding box + tri count
    for o in objects where (superClassOf o == GeometryClass and substring o.name 1 4 == "CNY_") do (
        local nv = 0; local nf = 0
        try ( local pc = getPolygonCount o; nv = pc[1]; nf = pc[2] ) catch()
        local mn2 = point3 0 0 0; local mx2 = point3 0 0 0
        try ( mn2 = o.min; mx2 = o.max ) catch()
        format "GEO\t%\t%\t%\t%\t%\t%\t%\t%\t%\n" o.name (classOf o) nv nf mn2.x mn2.y mn2.z mx2.x mx2.y mx2.z to:f
    )
    close f
    "detail written"
)
