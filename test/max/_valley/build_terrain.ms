fileIn @"D:\Workspace\MCP\3dsmax-mcp\test\max\_valley\lib.ms"

(
    local t0 = timestamp()
    local report = ""

    local cols = (((mcpRV_X1 - mcpRV_X0) / mcpRV_CELL) as integer) + 1
    local rows = (((mcpRV_Y1 - mcpRV_Y0) / mcpRV_CELL) as integer) + 1
    local nv = cols * rows
    local nf = (cols - 1) * (rows - 1) * 2

    local verts = #()
    verts[nv] = [0.0, 0.0, 0.0]
    for r = 0 to (rows - 1) do
    (
        local y = mcpRV_Y0 + (r as float) * mcpRV_CELL
        local base = r * cols
        for c = 0 to (cols - 1) do
        (
            local x = mcpRV_X0 + (c as float) * mcpRV_CELL
            verts[base + c + 1] = [x, y, (mcpRV_terrainH x y)]
        )
    )

    local faces = #()
    faces[nf] = [1, 2, 3]
    local iGrass = #()
    local iRock = #()
    local iSand = #()
    local iScree = #()
    local f = 1
    local halfCell = mcpRV_CELL * 0.5

    for r = 0 to (rows - 2) do
    (
        local y = mcpRV_Y0 + (r as float) * mcpRV_CELL
        local yc = y + halfCell
        local xcR = mcpRV_riverX yc
        local wz = mcpRV_waterZ yc
        for c = 0 to (cols - 2) do
        (
            local i1 = r * cols + c + 1
            local i2 = i1 + 1
            local i4 = i1 + cols
            local i3 = i4 + 1
            faces[f] = [i1, i2, i3]
            faces[f + 1] = [i1, i3, i4]

            local h00 = (verts[i1]).z
            local h10 = (verts[i2]).z
            local h01 = (verts[i4]).z
            local h11 = (verts[i3]).z
            local gx = ((h10 + h11) - (h00 + h01)) / (2.0 * mcpRV_CELL)
            local gy = ((h01 + h11) - (h00 + h10)) / (2.0 * mcpRV_CELL)
            local sl = sqrt (gx * gx + gy * gy)
            local hAvg = (h00 + h01 + h10 + h11) * 0.25
            local xc = mcpRV_X0 + (c as float) * mcpRV_CELL + halfCell
            local aC = abs (xc - xcR)

            local id = 1
            if (aC < 50.0) and (hAvg < (wz + 3.5)) then
                id = 3
            else if sl > 0.85 then
                id = 2
            else if hAvg > 150.0 then
                id = 4
            else if sl > 0.42 then
                id = 2

            if id == 1 then ( append iGrass f; append iGrass (f + 1) )
            else if id == 2 then ( append iRock f; append iRock (f + 1) )
            else if id == 3 then ( append iSand f; append iSand (f + 1) )
            else ( append iScree f; append iScree (f + 1) )

            f += 2
        )
    )

    local tm = mesh vertices:verts faces:faces
    tm.name = "TERRAIN"
    update tm
    convertToPoly tm

    local bG = #{}
    local bR = #{}
    local bS = #{}
    local bC = #{}
    for i in iGrass do bG[i] = true
    for i in iRock do bR[i] = true
    for i in iSand do bS[i] = true
    for i in iScree do bC[i] = true
    if bG.numberset > 0 do polyop.setFaceMatID tm bG 1
    if bR.numberset > 0 do polyop.setFaceMatID tm bR 2
    if bS.numberset > 0 do polyop.setFaceMatID tm bS 3
    if bC.numberset > 0 do polyop.setFaceMatID tm bC 4

    report += "terrain verts=" + (nv as string) + " faces=" + (nf as string) + "\n"
    report += "matID grass=" + (bG.numberset as string) + " rock=" + (bR.numberset as string) + " sand=" + (bS.numberset as string) + " scree=" + (bC.numberset as string) + "\n"

    -- ------------------------------------------------------------- water
    local yA = mcpRV_FY + 6.0
    local yB = mcpRV_FY - 6.0

    fn waterStrip yStart yStop stp nm =
    (
        local ys = #()
        local yy = yStart
        while yy < (yStop - 0.001) do ( append ys yy; yy += stp )
        append ys yStop
        local n = ys.count
        local vs = #()
        vs[n * 2] = [0.0, 0.0, 0.0]
        for i = 1 to n do
        (
            local y = ys[i]
            local cx = mcpRV_riverX y
            local tx = (mcpRV_riverX (y + 2.0)) - (mcpRV_riverX (y - 2.0))
            local ty = 4.0
            local ln = sqrt (tx * tx + ty * ty)
            local nx = ty / ln
            local ny = (-tx) / ln
            local hw = 18.0 + 3.0 * sin (y / 140.0 + 0.4)
            local z = mcpRV_waterZ y
            vs[(i - 1) * 2 + 1] = [(cx - nx * hw), (y - ny * hw), z]
            vs[(i - 1) * 2 + 2] = [(cx + nx * hw), (y + ny * hw), z]
        )
        local fs = #()
        fs[(n - 1) * 2] = [1, 2, 3]
        for i = 1 to (n - 1) do
        (
            local a1 = (i - 1) * 2 + 1
            local a2 = a1 + 1
            local b1 = a1 + 2
            local b2 = a1 + 3
            fs[(i - 1) * 2 + 1] = [a1, a2, b2]
            fs[(i - 1) * 2 + 2] = [a1, b2, b1]
        )
        local m = mesh vertices:vs faces:fs
        m.name = nm
        update m
        m
    )

    local wUp = waterStrip yA 596.0 8.0 "WATER_UP"
    local wDn = waterStrip (-720.0) yB 8.0 "WATER_DN"

    -- waterfall curtain (3 rows)
    local cv = #()
    local rowY = #(yA, ((yA + yB) * 0.5 - 1.5), yB)
    for k = 1 to 3 do
    (
        local y = rowY[k]
        local cx = mcpRV_riverX y
        local tx = (mcpRV_riverX (y + 2.0)) - (mcpRV_riverX (y - 2.0))
        local ty = 4.0
        local ln = sqrt (tx * tx + ty * ty)
        local nx = ty / ln
        local ny = (-tx) / ln
        local hw = 18.0 + 3.0 * sin (y / 140.0 + 0.4)
        local z = mcpRV_waterZ y
        if k == 2 do z = z + 0.8
        cv[(k - 1) * 2 + 1] = [(cx - nx * hw), (y - ny * hw), z]
        cv[(k - 1) * 2 + 2] = [(cx + nx * hw), (y + ny * hw), z]
    )
    local cf = #()
    for k = 1 to 2 do
    (
        local a1 = (k - 1) * 2 + 1
        local a2 = a1 + 1
        local b1 = a1 + 2
        local b2 = a1 + 3
        append cf [a1, b1, b2]
        append cf [a1, b2, a2]
    )
    local wCf = mesh vertices:cv faces:cf
    wCf.name = "WATER_FALL"
    update wCf

    report += "water up=" + (wUp.numfaces as string) + " dn=" + (wDn.numfaces as string) + " fall=" + (wCf.numfaces as string) + "\n"
    report += "elapsed " + (((timestamp() - t0) / 1000.0) as string) + " s\n"

    -- assign materials
    local mT = sceneMaterials["M_Terrain"]
    if mT != undefined then tm.material = mT
    local mW = sceneMaterials["M_Water"]
    if mW != undefined then
    (
        wUp.material = mW
        wDn.material = mW
        wCf.material = mW
    )

    select tm
    report
)
