/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_bake.ms
   Render To Texture: bake maps (diffuse, AO, normals, lighting) for game engines.

   Category: pipeline (bake_)

   Texture baking is SLOW and blocks 3ds Max, so every handler is registered
   undoable:false and always verifies the output files with doesFileExist.

   Pitfall baked into the design: bake_texture requires the objects to have a
   UVW channel and a shell/offset; without a clean UV set you get overlapping
   UVs and a smeared map. ZDepth / normal elements need explicit output paths
   or the render skips them - we always set one from the folder + template.

   No struct, no lambdas, no backslash line continuations.
-----------------------------------------------------------------------------*/

global mcpH_bake_texture, mcpH_bake_ao, mcpH_bake_normals, mcpH_bake_lighting
global mcpH_bake_set_output, mcpH_bake_objects, mcpH_bake_get_settings
global mcpBakeClassName, mcpBakeExpectedFile, mcpBakeRun
global mcpBakeFolder, mcpBakeSize, mcpBakeFormat, mcpBakePadding, mcpBakeTemplate, mcpBakeElements

mcpBakeFolder = ""
mcpBakeSize = 512
mcpBakeFormat = "png"
mcpBakePadding = 4
mcpBakeTemplate = "%s_%e"
mcpBakeElements = #()


/*-------------------------------------------------------- bake element class */
fn mcpBakeClassName friendly =
(
    local f = toLower (friendly as string)
    if f == "diffuse" do return "DiffuseMap"
    if f == "normal" or f == "normals" do return "NormalMap"
    if f == "lighting" or f == "complete" or f == "completemap" do return "CompleteMap"
    if f == "ao" or f == "ambientocclusion" do return "AmbientOcclusion"
    if f == "shadows" or f == "shadow" do return "ShadowsMap"
    if f == "specular" do return "SpecularMap"
    if f == "bump" do return "BumpMap"
    if f == "alpha" do return "AlphaMap"
    if f == "mixedao" do return "MixedAO"
    if f == "height" do return "HeightMap"
    if f == "selfillum" or f == "emissive" do return "SelfIllumMap"
    undefined
)


/*--------------------------------------------------- expected output filename */
fn mcpBakeExpectedFile folder tpl nodeName elName size fmt =
(
    local nm = tpl
    nm = substituteString nm "%s" nodeName
    nm = substituteString nm "%e" elName
    folder + "\\" + nm + "." + fmt
)


/*----------------------------------------------- core bake: setup + run + verify */
fn mcpBakeRun nodes elements folder size fmt tpl =
(
    if folder == "" do folder = try ( getDir #renderoutput ) catch ( getDir #temp )
    local baked = #()
    local failures = #()
    local written = #()
    if not (doesDirectoryExist folder) do ( try ( makeDir folder all:true ) catch() )
    for n in nodes do
    (
        local ok = true
        try
        (
            n.RenderToTexture.enabled = true
            n.RenderToTexture.bakeChannel = 1
            n.RenderToTexture.width = size
            n.RenderToTexture.height = size
            n.RenderToTexture.outputPath = folder
            n.RenderToTexture.fileType = (folder + "\\tmp." + fmt)
            n.RenderToTexture.antialias = true
            local existing = 0
            try ( existing = n.getNumBakeElements() ) catch ( existing = 0 )
            for i = (existing - 1) to 0 by -1 do ( try ( n.removeBakeElement i ) catch() )
            for ef in elements do
            (
                local cls = mcpBakeClassName ef
                if cls == undefined do cls = ef
                if mcpClassExists cls do
                (
                    local el = (execute cls)()
                    el.outputFilename = (mcpBakeExpectedFile folder tpl n.name cls size fmt)
                    try ( n.addBakeElement el ) catch()
                )
            )
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        if ok do append baked n.name
    )
    local ran = false
    try ( rktBatchRender nodes; ran = true ) catch ( append failures ("batch: " + (getCurrentException())) )
    for n in nodes do
        for ef in elements do
        (
            local cls = mcpBakeClassName ef
            if cls == undefined do cls = ef
            local fp = mcpBakeExpectedFile folder tpl n.name cls size fmt
            if doesFileExist fp do append written fp
        )
    local p = #()
    mcpPair p "baked" baked
    mcpPair p "failures" failures
    mcpPair p "written" written
    mcpPair p "folder" folder
    mcpPair p "ran" ran
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
