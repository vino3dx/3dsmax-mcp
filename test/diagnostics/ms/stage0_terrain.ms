-- Stage 0c / read-only: terrain + rock material internals.
(
    local out = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\stage0_terrain.tsv"
    local f = createFile out

    local t = getNodeByName "CNY_Terrain"
    if t == undefined then ( format "NO_TERRAIN\n" to:f ) else (
        format "TERRAIN\t%\t%\t%\n" t.name (classOf t) (classOf t.baseObject) to:f
        format "BBOX\t%\t%\t%\t%\t%\t%\n" t.min.x t.min.y t.min.z t.max.x t.max.y t.max.z to:f
        format "MODCOUNT\t%\n" t.modifiers.count to:f
        for i = 1 to t.modifiers.count do (
            local m = t.modifiers[i]
            format "MOD\t%\t%\t%\n" i (classOf m) m.name to:f
        )
        -- smoothing / display
        format "PIVOT\t%\t%\t%\n" t.pos.x t.pos.y t.pos.z to:f
        local sc = "-"; try ( sc = (classOf t.material) as string ) catch()
        format "MAT\t%\n" sc to:f
    )

    -- rock multimaterial structure
    local rm = undefined
    try ( rm = sceneMaterials["CNY_Rock_MatSet"] ) catch()
    if rm != undefined do (
        format "ROCKMAT\t%\t%\n" rm.name (classOf rm) to:f
        format "SUBCOUNT\t%\n" rm.numsubs to:f
        for i = 1 to rm.numsubs do (
            local s = rm[i]
            if s == undefined then ( format "SUB\t%\tundefined\n" i to:f ) else (
                local nm = s.name
                local cl = (classOf s) as string
                local bc = "-"; try ( bc = (s.basecolor as string) ) catch()
                local ro = -1; try ( ro = s.roughness ) catch()
                local mt = -1; try ( mt = s.metalness ) catch()
                format "SUB\t%\t%\t%\tbase:%\trough:%\tmetal:%\n" i nm cl bc ro mt to:f
            )
        )
    )

    -- other key materials
    for nm in #("CNY_Sky", "CNY_Haze_A", "CNY_Haze_B", "CNY_Haze_C", "CNY_Rock_Boulder", "CNY_Metal_Dark", "CNY_Steel", "CNY_Metal_Deck", "CNY_Warn_Yellow", "CNY_Emissive_Cyan", "CNY_Emissive_Red", "CNY_Road", "CNY_Metal_Rust", "PhysicalMaterial") do (
        local m = undefined
        try ( m = sceneMaterials[nm] ) catch()
        if m != undefined do (
            local bc = "-"; try ( bc = (m.basecolor as string) ) catch()
            local ro = -1; try ( ro = m.roughness ) catch()
            local mt = -1; try ( mt = m.metalness ) catch()
            local em = -1; try ( em = m.emission ) catch()
            local eic = "-"; try ( eic = (m.emission_color as string) ) catch()
            format "MATX\t%\t%\tbase:%\trough:%\tmetal:%\temis:%\temisCol:%\n" nm (classOf m) bc ro mt em eic to:f
        )
    )
    close f
    "terrain detail written"
)
