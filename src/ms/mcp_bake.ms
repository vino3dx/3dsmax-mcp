/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_bake.ms
   Texture baking: bake maps (diffuse, AO, normals, lighting) into image files.

   Category: pipeline (bake_)

   Two back ends, picked at run time:

     * "btt"    -- the Bake To Texture interface (3ds Max 2021+). This is the
                   modern path: maps are registered through BakeToTexture, then
                   a single bake() call renders them all.
     * "legacy" -- the classic Render To Texture path (3ds Max 2020 and older,
                   and still present in 2021+): bake elements are attached to
                   each node through iNodeBakeProperties and rendered with
                   "render rendertype:#bakeSelected".

   Hard-won constraints (all verified on 3ds Max 2022):

   1. The standard bake elements (CompleteMap / NormalsMap / AmbientOcclusion)
      belong to the Scanline renderer. Attaching them while Arnold is active
      makes the bake fail in a loop that spawns modal "MAXScript MacroScript
      Error Exception" dialogs, which wedges the bridge until Max is killed.
      We therefore switch to Scanline for the duration of the bake and restore
      the previous renderer afterwards, even on failure.

   2. An object with no UV channel cannot be baked; BakeToTexture.addMap raises
      "create at least one UV channel for the object". We add a box-projected
      UVW Map when channel 1 is missing.

   3. Registered bake maps must always be released. A map left pointing at a
      deleted node crashes 3ds Max on the next bake() call.

   4. Baking is slow and blocks 3ds Max, so nothing here is undoable and every
      result is verified against the files on disk. If no file was produced we
      raise an error -- reporting "bake finished" with an empty file list is
      worse than failing, because the caller then uses a texture that does not
      exist.

   No struct, no lambdas, no backslash line continuations.
-----------------------------------------------------------------------------*/

global mcpH_bake_texture, mcpH_bake_ao, mcpH_bake_normals, mcpH_bake_lighting
global mcpH_bake_set_output, mcpH_bake_objects, mcpH_bake_get_settings
global mcpBakeClassName, mcpBakeElementKeyword, mcpBakeElementKeywords, mcpBakeBaseName, mcpBakeRun
global mcpBakeFolder, mcpBakeSize, mcpBakeFormat, mcpBakePadding, mcpBakeTemplate, mcpBakeElements
global mcpBakeHasBTT, mcpBakeEnsureUV, mcpBakeRunBTT, mcpBakeRunLegacy

mcpBakeFolder = ""
mcpBakeSize = 512
mcpBakeFormat = "png"
mcpBakePadding = 4
mcpBakeTemplate = "%s_%e"
mcpBakeElements = #()


/*------------------------------------------------------ element name mapping */

-- Legacy path: the bake element class to instantiate.
fn mcpBakeClassName friendly =
(
    local f = toLower (friendly as string)
    if f == "diffuse" or f == "diffusemap" do return "DiffuseMap"
    if f == "normal" or f == "normals" or f == "normalsmap" do return "NormalsMap"
    if f == "lighting" or f == "lightingmap" do return "LightingMap"
    if f == "complete" or f == "completemap" do return "CompleteMap"
    if f == "ao" or f == "ambientocclusion" or f == "ambient_occlusion" do return "Ambient_Occlusion"
    if f == "shadows" or f == "shadow" or f == "shadowsmap" do return "ShadowsMap"
    if f == "specular" or f == "specularmap" do return "specularMap"
    if f == "alpha" or f == "alphamap" do return "AlphaMap"
    if f == "height" or f == "heightmap" do return "HeightMap"
    if f == "blend" or f == "blendmap" do return "BlendMap"
    undefined
)

-- Bake To Texture path: the map type keywords accepted by addMap, most likely
-- first.  Which of them actually work depends on the active renderer -- under
-- Arnold for example LightingMap / NormalsMap / AmbientOcclusion are refused
-- outright -- so the caller tries each candidate in turn.
fn mcpBakeElementKeywords friendly =
(
    local f = toLower (friendly as string)
    if f == "diffuse" or f == "diffusemap" do return #(#DiffuseMap)
    if f == "normal" or f == "normals" or f == "normalsmap" do return #(#NormalsMap, #NormalMap)
    if f == "lighting" or f == "lightingmap" do return #(#LightingMap, #CompleteMap)
    if f == "complete" or f == "completemap" do return #(#CompleteMap)
    if f == "ao" or f == "ambientocclusion" or f == "ambient_occlusion" do
        return #(#AmbientOcclusion, #AO, #AmbientOcclusionMap)
    if f == "shadows" or f == "shadow" or f == "shadowsmap" do return #(#ShadowsMap)
    if f == "specular" or f == "specularmap" do return #(#SpecularMap)
    if f == "alpha" or f == "alphamap" do return #(#AlphaMap)
    if f == "height" or f == "heightmap" do return #(#HeightMap)
    if f == "blend" or f == "blendmap" do return #(#BlendMap)
    undefined
)

-- Kept for the legacy back end, which instantiates the element class directly.
fn mcpBakeElementKeyword friendly =
(
    local kws = mcpBakeElementKeywords friendly
    if kws == undefined do return undefined
    kws[1]
)


/*------------------------------------------------------------ output naming */
fn mcpBakeBaseName tpl nodeName elName =
(
    local nm = tpl
    nm = substituteString nm "%s" nodeName
    nm = substituteString nm "%e" elName
    nm = substituteString nm "\\" "_"
    nm = substituteString nm "/" "_"
    nm = substituteString nm ":" "_"
    nm = substituteString nm "*" "_"
    nm = substituteString nm "?" "_"
    nm = substituteString nm "<" "_"
    nm = substituteString nm ">" "_"
    nm = substituteString nm "|" "_"
    nm
)

/* Callers pass the folder with or without a trailing separator ("C:/out" or
   "C:/out/"), and both are reasonable.  Joining naively produced
   "C:/out/\\name.png", which then showed up verbatim in the tool result. */
fn mcpBakeJoinPath folder name =
(
    local f = folder as string
    local last = ""
    while f.count > 0 do
    (
        last = substring f f.count 1
        if last == "\\" or last == "/" then f = substring f 1 (f.count - 1)
        else exit
    )
    f + "\\" + name
)

fn mcpBakeExpectedFile folder tpl nodeName elName size fmt =
(
    mcpBakeJoinPath folder ((mcpBakeBaseName tpl nodeName elName) + "." + fmt)
)


/*-------------------------------------------------------------- UV channels */
fn mcpBakeHasMapChannel n channel =
(
    local ok = false
    local msh = try ( n.mesh ) catch ( undefined )
    if msh != undefined do
    (
        try ( ok = meshop.getMapSupport msh channel ) catch ( ok = false )
    )
    ok
)

-- Baking needs UVs. Primitives without a UVW Map modifier have none, and every
-- bake call on them fails with a confusing UV-channel error.
fn mcpBakeEnsureUV n =
(
    if not (mcpBakeHasMapChannel n 1) do
    (
        try ( addModifier n (UVWMap maptype:4) ) catch()
    )
    mcpBakeHasMapChannel n 1
)


/*--------------------------------------------------------- renderer plumbing */

-- True when the Bake To Texture interface exists (3ds Max 2021+).
fn mcpBakeHasBTT =
(
    local ok = false
    try ( ok = (BakeToTexture != undefined) ) catch ( ok = false )
    ok
)

-- The standard bake elements only exist for Scanline. Returning the previous
-- renderer lets the caller restore it after the bake.
fn mcpBakeUseBakeRenderer =
(
    local prev = undefined
    local swapped = false
    try
    (
        prev = renderers.current
        if ((classof prev) as string) != "Default_Scanline_Renderer" then
        (
            renderers.current = Default_Scanline_Renderer()
            swapped = true
        )
    )
    catch ( swapped = false )
    #(prev, swapped)
)


/*--------------------------------------------------- back end: Bake To Texture */
fn mcpBakeRunBTT nodes elements folder size fmt tpl =
(
    local made = #()
    local failures = #()
    local written = #()
    local planned = #()
    local ran = false

    try ( BakeToTexture.deleteAllMaps() ) catch()
    try ( BakeToTexture.outputPath = folder ) catch()

    for n in nodes do
    (
        if not (mcpBakeEnsureUV n) then
        (
            append failures (n.name + ": no UV channel (could not create one)")
        )
        else
        (
            for ef in elements do
            (
                local kws = mcpBakeElementKeywords ef
                if kws == undefined then
                (
                    append failures ((ef as string) + ": unknown bake element")
                )
                else
                (
                    local m = undefined
                    local used = undefined
                    local tried = #()
                    for kw in kws while m == undefined do
                    (
                        append tried (kw as string)
                        m = try ( BakeToTexture.addMap n kw ) catch ( undefined )
                        if m != undefined do used = kw
                    )
                    if m == undefined then
                    (
                        local msg = n.name + " / " + (ef as string) + ": not supported by this renderer"
                        append failures (msg + " (tried " + (tried as string) + ")")
                    )
                    else
                    (
                        local base = mcpBakeBaseName tpl n.name (used as string)
                        try ( m.filename = base ) catch()
                        try ( m.fileType = fmt ) catch()
                        try ( m.imageWidth = size ) catch()
                        try ( m.imageHeight = size ) catch()
                        try ( m.edgePadding = mcpBakePadding ) catch()
                        append planned (mcpBakeJoinPath folder (base + "." + fmt))
                        if (findItem made n.name) == 0 do append made n.name
                    )
                )
            )
        )
    )

    if planned.count > 0 do
    (
        try ( BakeToTexture.bake(); ran = true )
        catch ( append failures ("bake: " + (getCurrentException())) )
    )

    -- Always release the registrations: a dangling map pointing at a deleted
    -- node crashes Max on the next bake.
    try ( BakeToTexture.deleteAllMaps() ) catch()

    for fp in planned do ( if doesFileExist fp do append written fp )
    #(made, failures, written, ran)
)


/*-------------------------------------------------------- back end: legacy RTT */
fn mcpBakeRunLegacy nodes elements folder size fmt tpl =
(
    local made = #()
    local failures = #()
    local written = #()
    local planned = #()
    local ran = false

    for n in nodes do
    (
        if not (mcpBakeEnsureUV n) then
        (
            append failures (n.name + ": no UV channel (could not create one)")
        )
        else
        (
            local ok = true
            try
            (
                local ibp = n.iNodeBakeProperties
                ibp.removeAllBakeElements()
                ibp.bakeEnabled = true
                ibp.bakeChannel = 1
                ibp.nDilations = mcpBakePadding
                for ef in elements do
                (
                    local cls = mcpBakeClassName ef
                    if cls == undefined then
                    (
                        append failures ((ef as string) + ": unknown bake element")
                        ok = false
                    )
                    else
                    (
                        local el = try ( execute (cls + "()") ) catch ( undefined )
                        if el == undefined then
                        (
                            append failures ((cls as string) + ": not available")
                            ok = false
                        )
                        else
                        (
                            local base = mcpBakeBaseName tpl n.name cls
                            local fp = mcpBakeJoinPath folder (base + "." + fmt)
                            -- The legacy API wants the full path in fileType and
                            -- the bare name in fileName; the names are swapped
                            -- relative to what you would expect.
                            try ( el.fileType = fp ) catch()
                            try ( el.fileName = (base + "." + fmt) ) catch()
                            try ( el.outputSzX = size ) catch()
                            try ( el.outputSzY = size ) catch()
                            try ( el.enabled = true ) catch()
                            try ( ibp.addBakeElement el ) catch()
                            append planned fp
                        )
                    )
                )
            )
            catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
            if ok do ( if (findItem made n.name) == 0 do append made n.name )
        )
    )

    if planned.count > 0 do
    (
        try
        (
            select nodes
            render rendertype:#bakeSelected vfb:off progressBar:false outputSize:[size,size]
            ran = true
        )
        catch ( append failures ("render: " + (getCurrentException())) )
    )

    for fp in planned do ( if doesFileExist fp do append written fp )
    #(made, failures, written, ran)
)


/*----------------------------------------------- core bake: dispatch + verify */
fn mcpBakeRun nodes elements folder size fmt tpl =
(
    if folder == "" do folder = try ( getDir #renderoutput ) catch ( getDir #temp )
    if not (doesDirectoryExist folder) do ( try ( makeDir folder all:true ) catch() )
    if nodes.count == 0 do mcpFail "err.no_selection"

    local restore = mcpBakeUseBakeRenderer()
    local prevRenderer = restore[1]
    local swapped = restore[2]

    local route = "btt"
    local res = undefined
    if mcpBakeHasBTT() then
    (
        res = mcpBakeRunBTT nodes elements folder size fmt tpl
    )
    else
    (
        route = "legacy"
        res = mcpBakeRunLegacy nodes elements folder size fmt tpl
    )

    -- Put the renderer back before anything else can fail.
    if swapped and prevRenderer != undefined do
    (
        try ( renderers.current = prevRenderer ) catch()
    )

    local made = res[1]
    local failures = res[2]
    local written = res[3]
    local ran = res[4]

    if written.count == 0 do
    (
        local detail = folder
        if failures.count > 0 do detail = folder + " | " + (failures[1] as string)
        mcpFail "err.bake_no_output" a1:route a2:detail
    )

    local p = #()
    mcpPair p "baked" made
    mcpPair p "failures" failures
    mcpPair p "written" written
    mcpPair p "folder" folder
    mcpPair p "ran" ran
    mcpPair p "route" route
    mcpPair p "renderer" (try ( (classof renderers.current) as string ) catch ( "" ))
    mcpPair p "message" (mcpMsg "msg.bake_done" a1:folder)
    mcpObj p
)


/*=============================================================== entry points */

fn mcpH_bake_texture params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local folder = mcpStr params "folder" default:mcpBakeFolder
    local size = mcpInt params "size" default:mcpBakeSize
    local fmt = toLower (mcpStr params "format" default:mcpBakeFormat)
    local tpl = mcpStr params "template" default:mcpBakeTemplate
    local elements = mcpArr params "elements"
    if elements.count == 0 do elements = #("diffuse", "lighting")
    mcpBakeRun nodes elements folder size fmt tpl
)


fn mcpH_bake_ao params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local folder = mcpStr params "folder" default:mcpBakeFolder
    local size = mcpInt params "size" default:mcpBakeSize
    local fmt = toLower (mcpStr params "format" default:mcpBakeFormat)
    local tpl = mcpStr params "template" default:mcpBakeTemplate
    local elements = mcpArr params "elements"
    if elements.count == 0 do elements = #("ao")
    mcpBakeRun nodes elements folder size fmt tpl
)


fn mcpH_bake_normals params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local folder = mcpStr params "folder" default:mcpBakeFolder
    local size = mcpInt params "size" default:mcpBakeSize
    local fmt = toLower (mcpStr params "format" default:mcpBakeFormat)
    local tpl = mcpStr params "template" default:mcpBakeTemplate
    local elements = mcpArr params "elements"
    if elements.count == 0 do elements = #("normal")
    mcpBakeRun nodes elements folder size fmt tpl
)


fn mcpH_bake_lighting params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local folder = mcpStr params "folder" default:mcpBakeFolder
    local size = mcpInt params "size" default:mcpBakeSize
    local fmt = toLower (mcpStr params "format" default:mcpBakeFormat)
    local tpl = mcpStr params "template" default:mcpBakeTemplate
    local elements = mcpArr params "elements"
    if elements.count == 0 do elements = #("lighting")
    mcpBakeRun nodes elements folder size fmt tpl
)


fn mcpH_bake_set_output params =
(
    local f = mcpStr params "folder" default:""
    if f != "" do mcpBakeFolder = f
    local sz = mcpInt params "size" default:-1
    if sz > 0 do mcpBakeSize = sz
    local fmt = toLower (mcpStr params "format" default:"")
    if fmt != "" do mcpBakeFormat = fmt
    local pad = mcpInt params "padding" default:-1
    if pad >= 0 do mcpBakePadding = pad
    local tpl = mcpStr params "template" default:""
    if tpl != "" do mcpBakeTemplate = tpl
    local p = #()
    mcpPair p "folder" mcpBakeFolder
    mcpPair p "size" mcpBakeSize
    mcpPair p "format" mcpBakeFormat
    mcpPair p "padding" mcpBakePadding
    mcpPair p "template" mcpBakeTemplate
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_bake_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local elements = mcpArr params "elements"
    if elements.count == 0 do mcpFail "err.missing_param" a1:"elements"
    local folder = mcpStr params "folder" default:mcpBakeFolder
    local size = mcpInt params "size" default:mcpBakeSize
    local fmt = toLower (mcpStr params "format" default:mcpBakeFormat)
    local tpl = mcpStr params "template" default:mcpBakeTemplate
    mcpBakeRun nodes elements folder size fmt tpl
)


fn mcpH_bake_get_settings params =
(
    local p = #()
    mcpPair p "folder" mcpBakeFolder
    mcpPair p "size" mcpBakeSize
    mcpPair p "format" mcpBakeFormat
    mcpPair p "padding" mcpBakePadding
    mcpPair p "template" mcpBakeTemplate
    mcpPair p "route" (if mcpBakeHasBTT() then "btt" else "legacy")
    mcpObj p
)


/*=============================================================== registry */

fn mcpRegisterBake =
(
    mcpRegister "bake_get_settings" mcpH_bake_get_settings undoable:false
    mcpRegister "bake_set_output" mcpH_bake_set_output undoable:false
    mcpRegister "bake_texture" mcpH_bake_texture undoable:false
    mcpRegister "bake_ao" mcpH_bake_ao undoable:false
    mcpRegister "bake_normals" mcpH_bake_normals undoable:false
    mcpRegister "bake_lighting" mcpH_bake_lighting undoable:false
    mcpRegister "bake_objects" mcpH_bake_objects undoable:false
    ok
)

mcpRegisterBake()
