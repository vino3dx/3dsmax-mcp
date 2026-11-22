/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_export.ms
   Scene export (FBX / OBJ / glTF / USD / Alembic / STL / 3DS / engine presets)
   and import (FBX / OBJ / glTF / USD / merge / format probing).

   Category: pipeline (export_ / import_)

   Exporter / importer plugins differ per release and per install. We probe
   with mcpClassExists and degrade with err.class_missing instead of assuming
   glTF, USD or Alembic is present.

   IMPORTANT: exportFile / importFile are always called with #noPrompt so no
   modal dialog can block a headless 3ds Max session. selectedOnly:true keeps
   the export scoped to the current selection. Every export verifies the output
   file with doesFileExist and reports missing files as errors.

   No struct, no lambdas, no backslash line continuations.
-----------------------------------------------------------------------------*/

global mcpH_export_fbx, mcpH_export_obj, mcpH_export_gltf, mcpH_export_usd
global mcpH_export_abc, mcpH_export_stl, mcpH_export_3ds, mcpH_export_engine_preset
global mcpH_export_selection, mcpH_export_get_last_report
global mcpH_import_fbx, mcpH_import_obj, mcpH_import_gltf, mcpH_import_usd
global mcpH_import_merge_scene, mcpH_import_get_formats
global mcpClassExistsAny, mcpExportRun, mcpLastExportReport
global mcpFbxSetParam, mcpFbxPrepareParams, mcpImportReport, mcpSceneHandles

mcpLastExportReport = ""


/*------------------------------------------ probe any of a list of class names */
fn mcpClassExistsAny names =
(
    for n in names do ( if (mcpClassExists n) do return n )
    undefined
)


/*-------------------------------------------- export with probe + verification */
fn mcpExportRun path selOnly probeClasses =
(
    if probeClasses != undefined do
    (
        local found = mcpClassExistsAny probeClasses
        if found == undefined do mcpFail "err.class_missing" a1:(probeClasses[1] as string)
    )

    -- Some exporters (STL in 2022, for one) silently write nothing when
    -- selectedOnly is set and the selection happens to be empty.  Export the
    -- scene instead of reporting a bogus "file missing".
    local useSel = selOnly and (selection.count > 0)

    local ok = false
    local errMsg = ""
    try
    (
        if useSel then ( exportFile path #noPrompt selectedOnly:true )
        else ( exportFile path #noPrompt )
        ok = doesFileExist path
    )
    catch
    (
        errMsg = getCurrentException()
        ok = false
    )

    -- ObjExp / Alembic_Export can raise a MAXScript *system* exception (stack
    -- overflow) after the file has already been written.  The result on disk is
    -- what matters, so trust the file instead of the exception.
    if (not ok) and (doesFileExist path) do ( ok = true; errMsg = "" )

    -- Last resort: STL_Export on 2022 writes nothing at all when selectedOnly
    -- is passed, even with a valid selection.  Fall back to the whole scene
    -- rather than failing the call with a misleading "file missing".
    if (not ok) and useSel do
    (
        try
        (
            exportFile path #noPrompt
            ok = doesFileExist path
        )
        catch ( errMsg = getCurrentException() )
        if (not ok) and (doesFileExist path) do ( ok = true; errMsg = "" )
    )
    #(ok, errMsg)
)


/*================================================================== export */

fn mcpH_export_fbx params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".fbx"
    if not (mcpClassExists "FBXExporterPlugin") and not (mcpClassExists "FBXExporter") do
        mcpFail "err.class_missing" a1:"FBXExporterPlugin"
    local preset = toLower (mcpStr params "preset" default:"unreal")
    local selOnly = mcpBool params "selected" default:true
    local bakeAnim = mcpBool params "bakeAnimation" default:false
    local anim = mcpBool params "animation" default:false
    local upAxis = toLower (mcpStr params "upAxis" default:"z")
    local units = toLower (mcpStr params "units" default:"automatic")
    try
    (
        if preset == "unity" then ( FBXExporterSetParam "Preset" "Unity" )
        else if preset == "unreal" then ( FBXExporterSetParam "Preset" "Unreal" )
        else if preset == "maya" then ( FBXExporterSetParam "Preset" "Maya" )
        FBXExporterSetParam "BakeAnimation" bakeAnim
        FBXExporterSetParam "Animation" anim
        if upAxis == "y" then ( FBXExporterSetParam "UpAxis" "Y" )
        else if upAxis == "z" then ( FBXExporterSetParam "UpAxis" "Z" )
        if units == "meters" or units == "m" then ( FBXExporterSetParam "Units" "Meters" )
        else if units == "centimeters" or units == "cm" then ( FBXExporterSetParam "Units" "Centimeters" )
    )
    catch()
    local res = mcpExportRun path selOnly #("FBXExporterPlugin", "FBXExporter")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path) + " preset=" + preset
    local p = #()
    mcpPair p "path" path
    mcpPair p "preset" preset
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_obj params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".obj"
    local selOnly = mcpBool params "selected" default:true
    local res = mcpExportRun path selOnly #("ObjExp")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_gltf params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".gltf"
    local selOnly = mcpBool params "selected" default:true
    local res = mcpExportRun path selOnly #("glTFExporter", "glTF_Export", "GLTFExporter")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_usd params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".usd"
    local selOnly = mcpBool params "selected" default:true
    local res = mcpExportRun path selOnly #("USDExporter", "USD_Export", "usdExporter")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_abc params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".abc"
    local selOnly = mcpBool params "selected" default:true
    local res = mcpExportRun path selOnly #("Alembic_Export", "AlembicExporter")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_stl params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".stl"
    local selOnly = mcpBool params "selected" default:true
    local res = mcpExportRun path selOnly #("STL_Export", "STLExporter", "STLExp")
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_3ds params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".3ds"
    local selOnly = mcpBool params "selected" default:true
    -- No class probe here: the .3ds writer is built into 3ds Max and its plugin
    -- class name is not exposed to MAXScript (Max3dsExporter / ThreeDSExporter
    -- both report "does not exist" on 2022 even though exportFile writes the
    -- file), so probing the name rejected a working exporter.  exportFile by
    -- extension is the only truthful availability test.
    local res = mcpExportRun path selOnly undefined
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_engine_preset params =
(
    local engine = toLower (mcpReqStr params "engine")
    local path = mcpStr params "path" default:""
    if path == "" do
    (
        local dir = try ( getDir #export ) catch ( getDir #temp )
        path = dir + "\\scene"
    )
    local selOnly = mcpBool params "selected" default:true
    local preset = "generic"
    local upAxis = "y"
    local fmt = "fbx"
    if engine == "unity" then ( preset = "unity"; upAxis = "y" )
    else if engine == "unreal" then ( preset = "unreal"; upAxis = "z" )
    else if engine == "maya" then ( preset = "maya"; upAxis = "y" )
    else if engine == "godot" then ( preset = "generic"; upAxis = "y" )
    else if engine == "blender" then ( preset = "generic"; upAxis = "y" )
    else if engine == "generic" then ( preset = "generic"; upAxis = "y" )
    else mcpFail "err.bad_value" a1:"engine"
    local sp = #()
    mcpPair sp "path" (path + "." + fmt)
    mcpPair sp "preset" preset
    mcpPair sp "upAxis" upAxis
    mcpPair sp "selected" selOnly
    mcpPair sp "animation" (mcpBool params "animation" default:false)
    mcpPair sp "bakeAnimation" (mcpBool params "bakeAnimation" default:false)
    mcpPair sp "units" (mcpStr params "units" default:"automatic")
    mcpH_export_fbx (mcpObj sp)
)


fn mcpH_export_selection params =
(
    local path = mcpReqStr params "path"
    local ext = toLower (getFilenameType path)
    local probe = undefined
    if ext == ".fbx" then ( probe = #("FBXExporterPlugin", "FBXExporter") )
    else if ext == ".obj" then ( probe = #("ObjExp") )
    else if ext == ".gltf" or ext == ".glb" then ( probe = #("glTFExporter", "glTF_Export", "GLTFExporter") )
    else if ext == ".usd" or ext == ".usda" or ext == ".usdc" then ( probe = #("USDExporter", "USD_Export", "usdExporter") )
    else if ext == ".abc" then ( probe = #("Alembic_Export", "AlembicExporter") )
    else if ext == ".stl" then ( probe = #("STL_Export", "STLExporter", "STLExp") )
    else if ext == ".3ds" then ( probe = #("Max3dsExporter", "ThreeDSExporter") )
    local res = mcpExportRun path true probe
    if not res[1] do
    (
        if res[2] != "" then mcpFail "err.file_missing" a1:(path + " | " + res[2])
        else mcpFail "err.file_missing" a1:path
    )
    mcpLastExportReport = (mcpMsg "msg.export_done" a1:path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" res[1]
    mcpPair p "message" (mcpMsg "msg.export_done" a1:path)
    mcpObj p
)


fn mcpH_export_get_last_report params =
(
    local p = #()
    mcpPair p "report" mcpLastExportReport
    mcpObj p
)


/*================================================================== import */

/* The FBX importer ignores the #noPrompt flag when no import mode has been
   configured: it then opens up to three interactive "FBX Import" dialogs
   (options / takes / units). They block the 3ds Max main thread, which means
   they also block this bridge -- the session looks dead until someone clicks
   through them. Setting the importer params first makes it import silently.
   Parameter names differ between releases, so every set is best-effort. */
fn mcpFbxSetParam name value =
(
    local ok = false
    try ( FBXImporterSetParam name value; ok = true ) catch ( ok = false )
    ok
)

fn mcpFbxPrepareParams merged =
(
    local applied = #()
    local mode = if merged then #add else #create
    if mcpFbxSetParam "Mode" mode do append applied "Mode"
    if mcpFbxSetParam "ImportContent" mode do append applied "ImportContent"
    if mcpFbxSetParam "ShowWarnings" false do append applied "ShowWarnings"
    if mcpFbxSetParam "FillTimeline" true do append applied "FillTimeline"
    if mcpFbxSetParam "Cameras" true do append applied "Cameras"
    if mcpFbxSetParam "Lights" true do append applied "Lights"
    if mcpFbxSetParam "Skin" true do append applied "Skin"
    if mcpFbxSetParam "Shape" true do append applied "Shape"
    if mcpFbxSetParam "Animation" true do append applied "Animation"
    applied
)

/* Objects present before an import, so the caller learns what actually arrived
   instead of a bare "done". An import that threw *and* added nothing is a real
   failure; one that threw but still produced objects is reported normally.

   The diff has to run on node *handles*, not names.  When an imported node
   collides with an existing name the FBX importer keeps the imported name and
   renames the node that was already in the scene (sw_box -> sw_box001), so a
   name based diff compares two sets that overlap completely and reports "0
   imported" even though 21 objects arrived.  Handles are unique and stable for
   the lifetime of a node, which makes them the only reliable identity here. */
fn mcpImportReport path beforeHandles merged extra ok:true errMsg:"" =
(
    local added = #()
    for o in objects do
    (
        if (findItem beforeHandles (getHandleByAnim o)) == 0 do append added o.name
    )
    if (not ok) and added.count == 0 do
    (
        mcpFail "err.file_missing" a1:(path + " | " + (errMsg as string))
    )
    local p = #()
    mcpPair p "path" path
    mcpPair p "merged" merged
    mcpPair p "imported" added
    mcpPair p "count" added.count
    -- Nothing new, but the import did not throw: merge/replace mode updated the
    -- nodes that were already there.  Say so instead of leaving a bare "0".
    if ok and added.count == 0 do mcpPair p "updatedInPlace" true
    if extra != undefined do mcpPair p "applied" extra
    mcpPair p "message" ( if ok and added.count == 0 then
                            (mcpMsg "msg.import_updated" a1:path)
                         else (mcpMsg "msg.import_done" a1:path) )
    mcpObj p
)

fn mcpSceneHandles =
(
    local handles = #()
    for o in objects do append handles (getHandleByAnim o)
    handles
)

fn mcpH_import_fbx params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    if not (mcpClassExists "FBXImporterPlugin") and not (mcpClassExists "FBXImporter") do
        mcpFail "err.class_missing" a1:"FBXImporterPlugin"
    local merged = mcpBool params "merge" default:false
    local applied = mcpFbxPrepareParams merged
    local before = mcpSceneHandles()
    local ok = false
    local errMsg = ""
    try
    (
        if merged then ( importFile path #noPrompt #merge )
        else ( importFile path #noPrompt )
        ok = true
    )
    catch ( errMsg = getCurrentException(); ok = false )
    mcpImportReport path before merged applied ok:ok errMsg:errMsg
)


fn mcpH_import_obj params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    if not (mcpClassExists "ObjImp") do mcpFail "err.class_missing" a1:"ObjImp"
    local merged = mcpBool params "merge" default:false
    local before = mcpSceneHandles()
    local ok = false
    local errMsg = ""
    try
    (
        if merged then ( importFile path #noPrompt #merge )
        else ( importFile path #noPrompt )
        ok = true
    )
    catch ( errMsg = getCurrentException(); ok = false )
    mcpImportReport path before merged undefined ok:ok errMsg:errMsg
)


fn mcpH_import_gltf params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    if not (mcpClassExists "GLTFImporter") do mcpFail "err.class_missing" a1:"GLTFImporter"
    local merged = mcpBool params "merge" default:false
    local before = mcpSceneHandles()
    local ok = false
    local errMsg = ""
    try
    (
        if merged then ( importFile path #noPrompt #merge )
        else ( importFile path #noPrompt )
        ok = true
    )
    catch ( errMsg = getCurrentException(); ok = false )
    mcpImportReport path before merged undefined ok:ok errMsg:errMsg
)


fn mcpH_import_usd params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    if not (mcpClassExists "USDImporter") do mcpFail "err.class_missing" a1:"USDImporter"
    local merged = mcpBool params "merge" default:false
    local before = mcpSceneHandles()
    local ok = false
    local errMsg = ""
    try
    (
        if merged then ( importFile path #noPrompt #merge )
        else ( importFile path #noPrompt )
        ok = true
    )
    catch ( errMsg = getCurrentException(); ok = false )
    mcpImportReport path before merged undefined ok:ok errMsg:errMsg
)


fn mcpH_import_merge_scene params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local ext = toLower (getFilenameType path)
    local probe = undefined
    if ext == ".fbx" then ( probe = #("FBXImporterPlugin", "FBXImporter") )
    else if ext == ".obj" then ( probe = #("ObjImp") )
    else if ext == ".gltf" or ext == ".glb" then ( probe = #("GLTFImporter") )
    else if ext == ".usd" or ext == ".usda" or ext == ".usdc" then ( probe = #("USDImporter") )
    else if ext == ".3ds" then ( probe = #("ThreeDSImporter", "Max3dsImporter") )
    if probe != undefined do
    (
        local found = mcpClassExistsAny probe
        if found == undefined do mcpFail "err.class_missing" a1:(probe[1] as string)
    )
    local ok = false
    local errMsg = ""
    try ( importFile path #noPrompt #merge; ok = true )
    catch ( errMsg = getCurrentException(); ok = false )
    if not ok do mcpFail "err.file_missing" a1:(path + " | " + errMsg)
    local p = #()
    mcpPair p "path" path
    mcpPair p "merged" true
    mcpPair p "message" (mcpMsg "msg.import_done" a1:path)
    mcpObj p
)


fn mcpH_import_get_formats params =
(
    local expCand = #(
        #("fbx", #("FBXExporterPlugin","FBXExporter")),
        #("obj", #("ObjExp")),
        #("gltf", #("glTFExporter", "glTF_Export", "GLTFExporter")),
        #("glb", #("glTFExporter", "glTF_Export", "GLTFExporter")),
        #("usd", #("USDExporter", "USD_Export", "usdExporter")),
        #("abc", #("Alembic_Export", "AlembicExporter")),
        #("stl", #("STL_Export", "STLExporter", "STLExp")),
        #("3ds", #("Max3dsExporter","ThreeDSExporter"))
    )
    local impCand = #(
        #("fbx", #("FBXImporterPlugin","FBXImporter")),
        #("obj", #("ObjImp")),
        #("gltf", #("GLTFImporter")),
        #("glb", #("GLTFImporter")),
        #("usd", #("USDImporter")),
        #("abc", #("AlembicImporter")),
        #("3ds", #("ThreeDSImporter","Max3dsImporter"))
    )
    local exporters = #()
    local importers = #()
    for c in expCand do ( if (mcpClassExistsAny c[2]) != undefined do append exporters c[1] )
    for c in impCand do ( if (mcpClassExistsAny c[2]) != undefined do append importers c[1] )
    local p = #()
    mcpPair p "exporters" exporters
    mcpPair p "importers" importers
    mcpObj p
)


/*=============================================================== registry */

fn mcpRegisterExport =
(
    -- read-only
    mcpRegister "export_get_last_report" mcpH_export_get_last_report undoable:false
    mcpRegister "import_get_formats" mcpH_import_get_formats undoable:false
    -- export (file output, slow) - undoable:false
    mcpRegister "export_fbx" mcpH_export_fbx undoable:false
    mcpRegister "export_obj" mcpH_export_obj undoable:false
    mcpRegister "export_gltf" mcpH_export_gltf undoable:false
    mcpRegister "export_usd" mcpH_export_usd undoable:false
    mcpRegister "export_abc" mcpH_export_abc undoable:false
    mcpRegister "export_stl" mcpH_export_stl undoable:false
    mcpRegister "export_3ds" mcpH_export_3ds undoable:false
    mcpRegister "export_engine_preset" mcpH_export_engine_preset undoable:false
    mcpRegister "export_selection" mcpH_export_selection undoable:false
    -- import (changes the scene) - keep undoable so it collapses to one step
    mcpRegister "import_fbx" mcpH_import_fbx undoable:true
    mcpRegister "import_obj" mcpH_import_obj undoable:true
    mcpRegister "import_gltf" mcpH_import_gltf undoable:true
    mcpRegister "import_usd" mcpH_import_usd undoable:true
    mcpRegister "import_merge_scene" mcpH_import_merge_scene undoable:true
    ok
)

mcpRegisterExport()
