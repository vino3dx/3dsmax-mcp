-- Stage 0d / read-only: gundam materials, light state, sky/haze objects, ART settings.
(
    local out = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\stage0_mat2.tsv"
    local f = createFile out

    for m in sceneMaterials where (substring m.name 1 3 == "MS_") do (
        local bc = "-"; try ( bc = (m.basecolor as string) ) catch()
        local ro = -1; try ( ro = m.roughness ) catch()
        local mt = -1; try ( mt = m.metalness ) catch()
        local em = -1; try ( em = m.emission ) catch()
        local refl = -1; try ( refl = m.reflection_weight ) catch()
        format "MSMAT\t%\t%\tbase:%\trough:%\tmetal:%\temis:%\trefl:%\n" m.name (classOf m) bc ro mt em refl to:f
    )

    for o in objects where (superClassOf o == Light) do (
        local en = "?"
        try ( en = if o.enabled then "ON" else "OFF" ) catch()
        local sh = "?"
        try ( sh = if o.castShadows then "SHADOW" else "noshadow" ) catch()
        local ar = -1; try ( ar = o.areaType ) catch()
        local ln = -1; try ( ln = o.length ) catch()
        local wd = -1; try ( wd = o.width ) catch()
        format "LIGHTX\t%\ten:%\t%\tarea:%\tlen:%\twid:%\n" o.name en sh ar ln wd to:f
    )

    -- sky / haze / backdrop objects
    for o in objects where (superClassOf o == GeometryClass) do (
        local mn = "-"
        try ( if o.material != undefined do mn = o.material.name ) catch()
        if mn == "CNY_Sky" or (substring mn 1 8 == "CNY_Haze") do (
            format "SKYOBJ\t%\t%\t%\t%\t%\t%\n" o.name (classOf o) mn o.pos.x o.pos.y o.pos.z to:f
        )
    )

    -- ART renderer settings
    local r = renderers.current
    format "ART\t%\n" (classOf r) to:f
    for p in (getPropNames r) do (
        local v = "-"
        try ( v = (getProperty r p) as string ) catch()
        format "ARTPROP\t%\t%\n" p v to:f
    )

    -- render globals
    format "RG\twidth:%\theight:%\tpixelAspect:%\n" renderWidth renderHeight renderPixelAspect to:f
    format "EXPOSURE\t%\n" (classOf sceneExposureControl) to:f
    try ( format "EXPVAL\t%\n" ((sceneExposureControl.exposureControl as string)) to:f ) catch()
    close f
    "mat2 written"
)
