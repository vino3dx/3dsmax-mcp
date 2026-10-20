/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_scene.ms
   Scene session management, layers, external assets, file IO and MAXScript
   introspection.

   Categories: scene, files, system (introspection)
-----------------------------------------------------------------------------*/

global mcpH_scene_info, mcpH_scene_statistics, mcpH_scene_new, mcpH_scene_reset
global mcpH_scene_open, mcpH_scene_save, mcpH_scene_save_as, mcpH_scene_merge
global mcpH_list_layers, mcpH_create_layer, mcpH_delete_layer
global mcpH_set_layer_properties, mcpH_assign_to_layer, mcpH_move_objects_to_new_layer
global mcpH_get_scene_assets, mcpH_find_missing_assets, mcpH_relink_assets
global mcpH_read_text_file, mcpH_write_text_file, mcpH_list_directory, mcpH_file_exists
global mcpH_make_directory, mcpH_copy_file, mcpH_delete_file, mcpH_get_file_info
global mcpH_list_max_classes, mcpH_get_class_properties, mcpH_get_class_methods
global mcpH_does_class_exist, mcpH_list_scene_classes
global mcpH_get_property_value, mcpH_set_property_value
global mcpCollectBitmapTextures, mcpResolveAny, mcpGetPropByPath, mcpSetPropByPath
global mcpLayerNodes, mcpGetLayer, mcpEnsureLayer, mcpBuildFileIndex, mcpClassBuckets


/*================================================================= scene info*/
fn mcpH_scene_info params =
(
    local p = #()
    mcpPair p "name" (try ( maxFileName ) catch ( "" ))
    mcpPair p "path" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "file" (try ( maxFilePath + maxFileName ) catch ( "" ))
    mcpPair p "modified" (try ( getSaveRequired() ) catch ( false ))
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "selectionCount" (try ( selection.count ) catch ( 0 ))
    mcpPair p "layerCount" (try ( LayerManager.count ) catch ( 0 ))
    mcpPair p "currentLayer" (try ( LayerManager.current.name ) catch ( "" ))
    mcpPair p "renderer" (mcpCurrentRendererName())
    mcpPair p "units" (try ( (units.SystemType) as string ) catch ( "" ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpObj p
)

fn mcpH_scene_statistics params =
(
    local includeHidden = mcpBool params "includeHidden" default:true

    local geometryCount = 0
    local shapeCount = 0
    local lightCount = 0
    local cameraCount = 0
    local helperCount = 0
    local spacewarpCount = 0
    local boneCount = 0
    local otherCount = 0
    local totalFaces = 0
    local totalVerts = 0
    local hiddenCount = 0
    local frozenCount = 0

    local list = #()
    try ( for o in objects do append list o ) catch()

    for o in list do
    (
        local isHidden = false
        local isFrozen = false
        try ( isHidden = o.isHidden ) catch()
        try ( isFrozen = o.isFrozen ) catch()
        if isHidden do hiddenCount += 1
        if isFrozen do frozenCount += 1

        if includeHidden or not isHidden then
        (
            local sc = "Other"
            try ( sc = (superclassof o) as string ) catch ( sc = "Other" )
            if sc == "Geometry" then geometryCount += 1
            else if sc == "Shape" then shapeCount += 1
            else if sc == "Light" then lightCount += 1
            else if sc == "Camera" then cameraCount += 1
            else if sc == "Helper" then helperCount += 1
            else if sc == "SpacewarpObject" then spacewarpCount += 1
            else if sc == "System" then boneCount += 1
            else otherCount += 1
        )

        local pc = undefined
        try ( pc = getPolygonCount o ) catch ( pc = undefined )
        if pc != undefined and pc.count >= 2 do
        (
            totalFaces += pc[1]
            totalVerts += pc[2]
        )
    )

    local materialCount = 0
    try ( materialCount = sceneMaterials.count ) catch()
    local bitmapCount = (mcpCollectBitmapTextures()).count

    local p = #()
    mcpPair p "objects" list.count
    mcpPair p "geometry" geometryCount
    mcpPair p "shapes" shapeCount
    mcpPair p "lights" lightCount
    mcpPair p "cameras" cameraCount
    mcpPair p "helpers" helperCount
    mcpPair p "spacewarps" spacewarpCount
    mcpPair p "systems" boneCount
    mcpPair p "other" otherCount
    mcpPair p "hidden" hiddenCount
    mcpPair p "frozen" frozenCount
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "materials" materialCount
    mcpPair p "bitmaps" bitmapCount
    mcpObj p
)


/*=============================================================== scene session*/
fn mcpH_scene_new params =
(
    resetMaxFile #noPrompt
    mcpRedraw()
    local p = #()
    mcpPair p "created" true
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_scene_reset params =
(
    -- resetMaxFile clears the scene; the material editor and units are reset
    -- separately because there is no scriptable factory reset for preferences.
    resetMaxFile #noPrompt
    try ( for i = 1 to 24 do meditMaterials[i] = StandardMaterial() ) catch()
    try ( units.SystemType = #Inches; units.SystemScale = 1.0 ) catch()
    try ( frameRate = 30 ) catch()
    mcpRedraw()
    local p = #()
    mcpPair p "reset" true
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_scene_open params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local quiet = mcpBool params "quiet" default:true
    local ok = true
    local err = ""
    try ( loadMaxFile path quiet:quiet )
    catch ( ok = false; err = getCurrentException() )
    if not ok do throw err
    mcpRedraw()
    local p = #()
    mcpPair p "opened" path
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "message" (mcpMsg "msg.loaded" a1:path)
    mcpObj p
)

fn mcpH_scene_save params =
(
    local full = ""
    try ( full = maxFilePath + maxFileName ) catch ( full = "" )
    if full == "" do mcpFail "err.missing_param" a1:"path"
    try ( makeDir (getFilenamePath full) all:true ) catch()
    saveMaxFile full quiet:true clearNeedSaveFlag:true
    local p = #()
    mcpPair p "saved" full
    mcpPair p "message" (mcpMsg "msg.saved" a1:full)
    mcpObj p
)

fn mcpH_scene_save_as params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".max"
    try ( makeDir (getFilenamePath path) all:true ) catch()
    saveMaxFile path quiet:true clearNeedSaveFlag:true
    local p = #()
    mcpPair p "saved" path
    mcpPair p "message" (mcpMsg "msg.saved" a1:path)
    mcpObj p
)

fn mcpH_scene_merge params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local names = mcpArr params "objects"
    local quiet = mcpBool params "quiet" default:true

    local ok = true
    local mode = "full"
    if names.count > 0 then
    (
        try ( mergeMAXFile path names #noPrompt quiet:quiet; mode = "selected" )
        catch ( mergeMAXFile path #noPrompt quiet:quiet; mode = "full (selective merge failed)" )
    )
    else mergeMAXFile path #noPrompt quiet:quiet

    mcpRedraw()
    local p = #()
    mcpPair p "merged" path
    mcpPair p "mode" mode
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "message" (mcpMsg "msg.import_done" a1:path)
    mcpObj p
)


/*====================================================================== layers*/
fn mcpGetLayer layerName =
(
    local lay = undefined
    try ( lay = LayerManager.getLayerFromName layerName ) catch ( lay = undefined )
    lay
)

fn mcpEnsureLayer layerName =
(
    local lay = mcpGetLayer layerName
    if lay == undefined do
    (
        try ( lay = LayerManager.newLayerFromName layerName )
        catch ( mcpFail "err.not_found_in_list" a1:layerName a2:"layer" )
    )
    lay
)

-- Enumerating through the scene rather than through the layer object keeps this
-- working on every release (the Layer API changed between 2018 and 2022).
fn mcpLayerNodes layerName =
(
    local out = #()
    try
    (
        for o in objects do
        (
            local ln = ""
            try ( ln = o.layer.name ) catch ( ln = "" )
            if ln == layerName do append out o
        )
    )
    catch()
    out
)

fn mcpH_list_layers params =
(
    local limit = mcpInt params "limit" default:500
    local layers = #()
    local count = 0

    local names = #()
    try
    (
        local lm = LayerManager
        for i = 0 to (lm.count - 1) do
        (
            local lay = undefined
            try ( lay = lm.getLayer i ) catch ( lay = undefined )
            if lay != undefined do append names (lay.name)
        )
    )
    catch ( names = #() )

    for nm in names do
    (
        if count < limit do
        (
            count += 1
            local p = #()
            mcpPair p "name" nm
            local lay = mcpGetLayer nm
            local hidden = false
            local frozen = false
            local col = undefined
            if lay != undefined do
            (
                try ( hidden = lay.isHidden ) catch()
                try ( frozen = lay.isFrozen ) catch()
                try ( col = lay.wireColor ) catch ( col = undefined )
            )
            mcpPair p "hidden" hidden
            mcpPair p "frozen" frozen
            mcpPair p "wireColor" col
            mcpPair p "nodeCount" (mcpLayerNodes nm).count
            append layers (mcpObj p)
        )
    )

    local p = #()
    mcpPair p "count" names.count
    mcpPair p "layers" layers
    mcpObj p
)

fn mcpH_create_layer params =
(
    local name = mcpReqStr params "name"
    if mcpGetLayer name != undefined do mcpFail "err.bad_value" a1:("layer already exists: " + name)

    local lay = mcpEnsureLayer name
    local col = mcpGet params "color"
    if col != undefined do ( try ( lay.wireColor = mcpColorFrom col ) catch() )
    if (mcpGet params "hidden") != undefined do
        ( try ( lay.isHidden = mcpBool params "hidden" default:false ) catch() )

    local p = #()
    mcpPair p "layer" name
    mcpPair p "message" (mcpMsg "msg.created" a1:name)
    mcpObj p
)

fn mcpH_delete_layer params =
(
    local name = mcpReqStr params "name"
    local lay = mcpGetLayer name
    if lay == undefined do mcpFail "err.not_found_in_list" a1:name a2:"layer"

    local deleteObjects = mcpBool params "deleteObjects" default:false
    local nodes = mcpLayerNodes name
    local moved = 0
    local removed = 0

    if deleteObjects then
    (
        for n in nodes do ( try ( delete n; removed += 1 ) catch() )
    )
    else
    (
        local home = mcpGetLayer "0"
        if home == undefined do ( try ( home = LayerManager.getLayer 0 ) catch ( home = undefined ) )
        for n in nodes do
        (
            local ok = false
            if home != undefined do ( try ( home.addNode n; ok = true ) catch ( ok = false ) )
            if ok then moved += 1
        )
    )

    local ok = true
    try ( LayerManager.deleteLayerByName name )
    catch ( ok = false )

    local p = #()
    mcpPair p "deleted" ok
    mcpPair p "objectsDeleted" removed
    mcpPair p "objectsMovedToDefault" moved
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_set_layer_properties params =
(
    local name = mcpReqStr params "name"
    local lay = mcpEnsureLayer name
    local applied = #()

    if (mcpGet params "hidden") != undefined do
        ( try ( lay.isHidden = mcpBool params "hidden" default:false; append applied "hidden" ) catch() )
    if (mcpGet params "frozen") != undefined do
        ( try ( lay.isFrozen = mcpBool params "frozen" default:false; append applied "frozen" ) catch() )
    if (mcpGet params "color") != undefined do
        ( try ( lay.wireColor = mcpColorFrom (mcpGet params "color"); append applied "color" ) catch() )
    if (mcpGet params "renderable") != undefined do
        ( try ( lay.renderable = mcpBool params "renderable" default:true; append applied "renderable" ) catch() )

    local p = #()
    mcpPair p "layer" name
    mcpPair p "applied" applied
    mcpObj p
)

fn mcpH_assign_to_layer params =
(
    local layerName = mcpReqStr params "layer"
    local lay = mcpEnsureLayer layerName
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true

    local moved = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local err = ""
        try ( lay.addNode n )
        catch ( ok = false; err = getCurrentException() )
        if ok then append moved n.name else append failures (n.name + ": " + err)
    )

    local p = #()
    mcpPair p "layer" layerName
    mcpPair p "moved" moved
    mcpPair p "failures" failures
    mcpObj p
)

fn mcpH_move_objects_to_new_layer params =
(
    local layerName = mcpReqStr params "layer"
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if mcpGetLayer layerName == undefined do mcpEnsureLayer layerName
    mcpH_assign_to_layer (mcpObj #(#("layer", layerName), #("objects", (for n in nodes collect n.name))))
)


/*====================================================================== assets*/
fn mcpCollectBitmapTextures =
(
    local out = #()
    try
    (
        for t in (getClassInstances BitmapTexture) do
            ( if findItem out t == 0 do append out t )
    )
    catch()
    -- Renderer specific bitmap classes, when present.
    local extras = #("VRayBitmap", "VRayHDRI", "CoronaBitmap", "FStormBitmap", "OSLBitmap")
    for clsName in extras do
    (
        if mcpClassExists clsName do
        (
            local found = #()
            try ( found = execute ("for o in (getClassInstances " + clsName + ") collect o") ) catch ( found = #() )
            try ( for t in found do ( if findItem out t == 0 do append out t ) ) catch()
        )
    )
    out
)

fn mcpH_get_scene_assets params =
(
    local limit = mcpInt params "limit" default:500
    local textures = mcpCollectBitmapTextures()
    local items = #()
    local missing = 0
    local count = 0

    for t in textures do
    (
        local fname = ""
        try ( fname = t.filename ) catch ( fname = "" )
        local exists = false
        if fname != "" do ( try ( exists = doesFileExist fname ) catch ( exists = false ) )
        if not exists and fname != "" do missing += 1

        if count < limit do
        (
            count += 1
            local p = #()
            mcpPair p "name" (try ( t.name ) catch ( "" ))
            mcpPair p "class" (try ( (classof t) as string ) catch ( "" ))
            mcpPair p "filename" fname
            mcpPair p "exists" exists
            append items (mcpObj p)
        )
    )

    local p = #()
    mcpPair p "count" textures.count
    mcpPair p "missing" missing
    mcpPair p "assets" items
    mcpObj p
)

fn mcpH_find_missing_assets params =
(
    local textures = mcpCollectBitmapTextures()
    local byFile = #()
    local counts = #()

    for t in textures do
    (
        local fname = ""
        try ( fname = t.filename ) catch ( fname = "" )
        if fname != "" then
        (
            local exists = false
            try ( exists = doesFileExist fname ) catch ( exists = false )
            if not exists do
            (
                local idx = 0
                for i = 1 to byFile.count while idx == 0 do ( if byFile[i] == fname do idx = i )
                if idx == 0 then ( append byFile fname; append counts 1 )
                else counts[idx] += 1
            )
        )
    )

    local items = #()
    for i = 1 to byFile.count do
    (
        local p = #()
        mcpPair p "filename" byFile[i]
        mcpPair p "references" counts[i]
        append items (mcpObj p)
    )

    local out = #()
    mcpPair out "count" byFile.count
    mcpPair out "missing" items
    mcpObj out
)

-- Builds a lower case filename index of every file under the given roots.
fn mcpBuildFileIndex roots =
(
    local index = #()
    for r in roots do
    (
        if not (doesFileExist r) then
        (
            local ok = true
            try ( makeDir r all:true ) catch ( ok = false )
        )
        local files = #()
        try
        (
            files = ((dotNetClass "System.IO.Directory").GetFiles r "*.*" ((dotNetClass "System.IO.SearchOption").AllDirectories))
        )
        catch ( files = #() )
        try
        (
            local nFiles = 0
            try ( nFiles = files.Length ) catch ( nFiles = 0 )
            if nFiles == 0 do ( try ( nFiles = files.count ) catch ( nFiles = 0 ) )
            for i = 0 to (nFiles - 1) do
            (
                local full = undefined
                try ( full = files.GetValue i ) catch ( full = files[i + 1] )
                append index #((toLower (getFilenameFile full)) + (toLower (getFilenameType full)), full)
            )
        )
        catch()
    )
    index
)

fn mcpH_relink_assets params =
(
    local roots = mcpArr params "searchPaths"
    if roots.count == 0 do mcpFail "err.missing_param" a1:"searchPaths"
    local onlyMissing = mcpBool params "onlyMissing" default:true
    local dryRun = mcpBool params "dryRun" default:false

    local textures = mcpCollectBitmapTextures()
    local plan = #()
    local unresolved = #()
    local skipped = 0

    -- Pass 1: cheap reconstruction, "same relative name under a new root".
    local pending = #()
    for t in textures do
    (
        local fname = ""
        try ( fname = t.filename ) catch ( fname = "" )
        if fname == "" then skipped += 1
        else
        (
            local exists = false
            try ( exists = doesFileExist fname ) catch ( exists = false )
            if onlyMissing and exists then skipped += 1
            else
            (
                local base = filenameFromPath fname
                local hit = ""
                for r in roots while hit == "" do
                (
                    local candidate = ((r as string) + "\\" + base)
                    if doesFileExist candidate do hit = candidate
                )
                if hit != "" then append plan #(t, fname, hit)
                else append pending t
            )
        )
    )

    -- Pass 2: full filename index for whatever is still unresolved.
    if pending.count > 0 do
    (
        local index = mcpBuildFileIndex roots
        for t in pending do
        (
            local fname = ""
            try ( fname = t.filename ) catch ( fname = "" )
            local key = (toLower (getFilenameFile fname)) + (toLower (getFilenameType fname))
            local hit = ""
            for e in index while hit == "" do ( if e[1] == key do hit = e[2] )
            if hit != "" then append plan #(t, fname, hit)
            else append unresolved fname
        )
    )

    local relinked = #()
    local applied = 0
    if not dryRun then
    (
        for e in plan do
        (
            local tex = e[1]
            local ok = true
            try
            (
                tex.filename = e[3]
                try ( tex.reload() ) catch()
            )
            catch ( ok = false )
            if ok do applied += 1
            append relinked (mcpObj #(#("name", (try ( tex.name ) catch ( "" ))), #("from", e[2]), #("to", e[3]), #("ok", ok)))
        )
    )
    else
    (
        for e in plan do
        (
            local tex = e[1]
            append relinked (mcpObj #(#("name", (try ( tex.name ) catch ( "" ))), #("from", e[2]), #("to", e[3]), #("ok", true)))
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "dryRun" dryRun
    mcpPair p "totalTextures" textures.count
    mcpPair p "skipped" skipped
    mcpPair p "planned" plan.count
    mcpPair p "applied" applied
    mcpPair p "unresolved" unresolved
    mcpPair p "plan" relinked
    mcpObj p
)


/*=================================================================== file I/O*/
fn mcpH_read_text_file params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local maxChars = mcpInt params "maxChars" default:200000

    local text = ""
    local ok = true
    try ( text = ((dotNetClass "System.IO.File").ReadAllText path) )
    catch ( ok = false; text = "" )
    if not ok do
    (
        -- Fall back to the ANSI path for legacy files.
        try ( text = ((dotNetClass "System.IO.File").ReadAllText path ((dotNetClass "System.Text.Encoding").Default)) )
        catch ( mcpFail "err.invalid_argument" a1:"path" a2:(getCurrentException()) )
    )
    if text == undefined do text = ""

    local truncated = false
    if text.count > maxChars do
    (
        text = substring text 1 maxChars
        truncated = true
    )

    local p = #()
    mcpPair p "path" path
    mcpPair p "truncated" truncated
    mcpPair p "content" text
    mcpObj p
)

fn mcpH_write_text_file params =
(
    local path = mcpReqStr params "path"
    local content = mcpStr params "content" default:""
    local append = mcpBool params "append" default:false
    local encoding = toLower (mcpStr params "encoding" default:"utf-8")

    try ( makeDir (getFilenamePath path) all:true ) catch()

    local ok = true
    local err = ""
    try
    (
        if encoding == "ansi" then
        (
            local enc = ((dotNetClass "System.Text.Encoding").Default)
            if append then ((dotNetClass "System.IO.File").AppendAllText path content enc)
            else ((dotNetClass "System.IO.File").WriteAllText path content enc)
        )
        else
        (
            if append then ((dotNetClass "System.IO.File").AppendAllText path content)
            else ((dotNetClass "System.IO.File").WriteAllText path content)
        )
    )
    catch ( ok = false; err = getCurrentException() )
    if not ok do throw err

    local p = #()
    mcpPair p "path" path
    mcpPair p "written" ok
    mcpPair p "size" (try ( getFileSize path ) catch ( 0 ))
    mcpObj p
)

fn mcpH_list_directory params =
(
    local path = mcpReqStr params "path"
    local pattern = mcpStr params "pattern" default:"*.*"
    if pattern == "" do pattern = "*.*"
    local recursive = mcpBool params "recursive" default:false
    local limit = mcpInt params "limit" default:500

    if not (doesFileExist path) do
    (
        -- doesFileExist is false for directories of some paths; probe explicitly
        local isDir = false
        try ( isDir = ((dotNetClass "System.IO.Directory").Exists path) ) catch ( isDir = false )
        if not isDir do mcpFail "err.file_missing" a1:path
    )

    local files = #()
    try
    (
        local option = if recursive then ((dotNetClass "System.IO.SearchOption").AllDirectories)
                       else ((dotNetClass "System.IO.SearchOption").TopDirectoryOnly)
        files = ((dotNetClass "System.IO.Directory").GetFiles path pattern option)
    )
    catch ( files = #() )

    local items = #()
    local total = 0
    -- Directory.GetFiles returns a string[] that MAXScript may expose either as
    -- a .NET array (Length/GetValue) or as a plain array (count/[i]).
    try ( total = files.Length ) catch ( total = 0 )
    if total == 0 do ( try ( total = files.count ) catch ( total = 0 ) )

    local n = total
    if n > limit do n = limit
    for i = 0 to (n - 1) do
    (
        local full = undefined
        try ( full = files.GetValue i ) catch ( full = files[i + 1] )
        local p = #()
        mcpPair p "name" (filenameFromPath full)
        mcpPair p "path" full
        mcpPair p "size" (try ( getFileSize full ) catch ( 0 ))
        append items (mcpObj p)
    )

    local out = #()
    mcpPair out "count" total
    mcpPair out "truncated" (total > limit)
    mcpPair out "files" items
    mcpObj out
)

fn mcpH_file_exists params =
(
    local path = mcpReqStr params "path"
    local isFile = false
    local isDir = false
    try ( isFile = doesFileExist path ) catch()
    try ( isDir = ((dotNetClass "System.IO.Directory").Exists path) ) catch()
    local p = #()
    mcpPair p "path" path
    mcpPair p "exists" (isFile or isDir)
    mcpPair p "isFile" isFile
    mcpPair p "isDirectory" isDir
    mcpObj p
)

fn mcpH_make_directory params =
(
    local path = mcpReqStr params "path"
    local ok = true
    try ( makeDir path all:true ) catch ( ok = false )
    local p = #()
    mcpPair p "path" path
    mcpPair p "created" ok
    mcpObj p
)

fn mcpH_copy_file params =
(
    local src = mcpReqStr params "source"
    local dst = mcpReqStr params "destination"
    if not (doesFileExist src) do mcpFail "err.file_missing" a1:src
    local overwrite = mcpBool params "overwrite" default:true

    -- Allow the destination to be a folder.
    local isDir = false
    try ( isDir = ((dotNetClass "System.IO.Directory").Exists dst) ) catch()
    if isDir do dst = dst + "\\" + (filenameFromPath src)
    try ( makeDir (getFilenamePath dst) all:true ) catch()

    local ok = true
    local err = ""
    try ( ((dotNetClass "System.IO.File").Copy src dst overwrite) )
    catch ( ok = false; err = getCurrentException() )
    if not ok do throw err

    local p = #()
    mcpPair p "source" src
    mcpPair p "destination" dst
    mcpPair p "copied" true
    mcpObj p
)

fn mcpH_delete_file params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    ((dotNetClass "System.IO.File").Delete path)
    local p = #()
    mcpPair p "path" path
    mcpPair p "deleted" true
    mcpObj p
)

fn mcpH_get_file_info params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local modified = ""
    try ( modified = (((dotNetClass "System.IO.File").GetLastWriteTime path).ToString "yyyy-MM-dd HH:mm:ss") )
    catch ( modified = "" )
    local p = #()
    mcpPair p "path" path
    mcpPair p "name" (filenameFromPath path)
    mcpPair p "size" (try ( getFileSize path ) catch ( 0 ))
    mcpPair p "modified" modified
    mcpPair p "extension" (getFilenameType path)
    mcpObj p
)


/*=============================================================== introspection*/
-- MAXScript exposes a per superclass class registry: <superclass>.classes.
-- It is the only reliable way to enumerate what plugins are installed.
fn mcpClassBuckets =
(
    #(
        "geometry", "shape", "light", "camera", "helper", "spacewarp", "system",
        "material", "textureMap", "modifier", "controller", "renderer", "filter",
        "effect", "atmospheric"
    )
)

fn mcpH_list_max_classes params =
(
    local keyword = toLower (mcpStr params "keyword" default:"")
    local limit = mcpInt params "limit" default:100

    local found = #()
    local seen = #()
    local scanned = 0
    local bucketsOk = 0

    for bucketName in mcpClassBuckets do
    (
        local bucket = undefined
        try ( bucket = execute bucketName ) catch ( bucket = undefined )
        if bucket != undefined do
        (
            local classes = #()
            try ( classes = bucket.classes ) catch ( classes = #() )
            if classes.count > 0 do bucketsOk += 1
            for c in classes do
            (
                scanned += 1
                local nm = ""
                try ( nm = c as string ) catch ( nm = "" )
                if nm != "" do
                (
                    if findItem seen nm == 0 then
                    (
                        append seen nm
                        if keyword == "" or (findString (toLower nm) keyword) != undefined do
                            ( if found.count < limit do append found nm )
                    )
                )
            )
        )
    )

    local p = #()
    mcpPair p "keyword" keyword
    mcpPair p "scanned" scanned
    mcpPair p "buckets" bucketsOk
    mcpPair p "count" found.count
    mcpPair p "classes" found
    mcpObj p
)

fn mcpH_does_class_exist params =
(
    local clsName = mcpReqStr params "className"
    local p = #()
    mcpPair p "className" clsName
    mcpPair p "exists" (mcpClassExists clsName)
    mcpObj p
)

fn mcpH_list_scene_classes params =
(
    local names = #()
    local counts = #()
    local list = #()
    try ( for o in objects do append list o ) catch()

    for o in list do
    (
        local nm = ""
        try ( nm = (classof o) as string ) catch ( nm = "Unknown" )
        local idx = 0
        for i = 1 to names.count while idx == 0 do ( if names[i] == nm do idx = i )
        if idx == 0 then ( append names nm; append counts 1 )
        else counts[idx] += 1
    )

    local items = #()
    for i = 1 to names.count do
        append items (mcpObj #(#("class", names[i]), #("count", counts[i])))

    local p = #()
    mcpPair p "distinctClasses" names.count
    mcpPair p "classes" items
    mcpObj p
)

fn mcpH_get_class_properties params =
(
    local clsName = mcpReqStr params "className"
    local limit = mcpInt params "limit" default:200
    mcpEnsureClass clsName

    local cls = execute clsName
    local inst = undefined
    local created = false
    try ( inst = cls(); created = true ) catch ( inst = undefined )

    if inst == undefined do
    (
        local p0 = #()
        mcpPair p0 "className" clsName
        mcpPair p0 "properties" #()
        mcpPair p0 "note" "This class cannot be instantiated without arguments. Use execute_maxscript with getPropNames on an existing instance."
        return (mcpObj p0)
    )

    local propNames = #()
    try ( propNames = getPropNames inst ) catch ( propNames = #() )
    if propNames == undefined do propNames = #()

    local props = #()
    local skipped = 0
    for n in propNames do
    (
        if props.count >= limit then exit
        local v = undefined
        local ok = true
        try ( v = getProperty inst n ) catch ( ok = false )
        if ok then
        (
            local it = #()
            mcpPair it "name" (n as string)
            mcpPair it "type" (try ( (classof v) as string ) catch ( "" ))
            mcpPair it "value" (mcpResultToJson v)
            append props (mcpObj it)
        )
        else skipped += 1
    )

    if created and (isKindOf inst Node) do ( try ( delete inst ) catch() )

    local p = #()
    mcpPair p "className" clsName
    mcpPair p "count" props.count
    mcpPair p "unreadable" skipped
    mcpPair p "properties" props
    mcpObj p
)

fn mcpH_get_class_methods params =
(
    local clsName = mcpReqStr params "className"
    mcpEnsureClass clsName

    local cls = execute clsName
    local inst = undefined
    local created = false
    try ( inst = cls(); created = true ) catch ( inst = undefined )

    local names = #()
    if inst != undefined do
    (
        local propNames = #()
        try ( propNames = getPropNames inst ) catch ( propNames = #() )
        for n in propNames do
        (
            local v = undefined
            local ok = true
            try ( v = getProperty inst n ) catch ( ok = false )
            if ok then
            (
                local isFn = false
                try ( isFn = (classof v == MAXScriptFunction) ) catch ( isFn = false )
                if isFn do append names (n as string)
            )
        )
        if created and (isKindOf inst Node) do ( try ( delete inst ) catch() )
    )

    local p = #()
    mcpPair p "className" clsName
    mcpPair p "count" names.count
    mcpPair p "methods" names
    mcpPair p "note" "MAXScript only exposes callable members that the class publishes as properties. For the full API use execute_maxscript with showClass and the MAXScript reference."
    mcpObj p
)


/*======================================================= generic property access*/
fn mcpResolveAny spec =
(
    local node = mcpResolveNode spec
    if node != undefined then return node

    -- scene material by name
    local mat = undefined
    try
    (
        for m in sceneMaterials do
            ( if m.name == (spec as string) do ( mat = m; exit ) )
    )
    catch()
    if mat != undefined then return mat
    undefined
)

-- Walks a dotted path, e.g. "material.diffuse" or "modifiers.1.enabled".
fn mcpGetPropByPath root path =
(
    local parts = mcpStringSplit path "."
    local cur = root
    local err = ""
    for i = 1 to parts.count do
    (
        if cur == undefined then ( err = "path broke before " + parts[i]; exit )
        local key = parts[i]
        local idx = -1
        try ( idx = key as integer ) catch ( idx = -1 )
        -- "as integer" on a non-numeric key yields undefined without throwing
        -- (see mcp_core.ms mcpResolveNode); guard before comparing.
        if idx == undefined do idx = -1
        if idx > 0 then
        (
            local nxt = undefined
            try ( nxt = cur[idx] ) catch ( nxt = undefined )
            if nxt == undefined then ( err = "index " + key + " out of range"; exit )
            cur = nxt
        )
        else
        (
            local nxt = undefined
            local ok = true
            try ( nxt = getProperty cur key ) catch ( ok = false )
            if not ok then ( err = "no property '" + key + "'"; exit )
            cur = nxt
        )
    )
    #(err == "", cur, err)
)

fn mcpSetPropByPath root path rawValue =
(
    local parts = mcpStringSplit path "."
    if parts.count == 0 do return #(false, "empty path")

    local cur = root
    for i = 1 to (parts.count - 1) do
    (
        local key = parts[i]
        local idx = -1
        try ( idx = key as integer ) catch ( idx = -1 )
        if idx == undefined do idx = -1
        local nxt = undefined
        if idx > 0 then ( try ( nxt = cur[idx] ) catch ( nxt = undefined ) )
        else ( try ( nxt = getProperty cur key ) catch ( nxt = undefined ) )
        if nxt == undefined do return #(false, "path broke at " + key)
        cur = nxt
    )

    local lastKey = parts[parts.count]
    local current = undefined
    local readable = true
    try ( current = getProperty cur lastKey ) catch ( readable = false )

    -- Coerce the incoming string to the type of the current value.
    local value = rawValue
    if readable and current != undefined then
    (
        local cls = classof current
        if cls == BooleanClass then value = ((toLower (rawValue as string)) == "true" or rawValue == "1")
        else if isKindOf current Number then ( try ( value = (rawValue as float) ) catch ( value = rawValue ) )
        else if isKindOf current String then value = (rawValue as string)
        else if isKindOf current Point3 then
        (
            local nums = #()
            local cleaned = substituteString (rawValue as string) "[" ""
            cleaned = substituteString cleaned "]" ""
            for s2 in (mcpStringSplit cleaned ",") do
                ( try ( append nums ((trimLeft (trimRight s2)) as float) ) catch() )
            value = mcpPoint3From nums default:current
        )
        else if isKindOf current Color then value = mcpColorFrom rawValue default:current
        else if isKindOf current Name then ( try ( value = ((rawValue as string) as name) ) catch() )
    )

    local ok = true
    local err = ""
    try ( setProperty cur lastKey value )
    catch ( ok = false; err = getCurrentException() )
    #(ok, err)
)

fn mcpH_get_property_value params =
(
    local spec = mcpReqStr params "object"
    local path = mcpReqStr params "property"

    local root = mcpResolveAny spec
    if root == undefined do mcpFail "err.node_not_found" a1:spec

    local res = mcpGetPropByPath root path
    local p = #()
    mcpPair p "object" spec
    mcpPair p "property" path
    mcpPair p "ok" res[1]
    if res[1] then mcpPair p "value" (mcpResultToJson res[2])
    else mcpPair p "error" res[3]
    mcpObj p
)

fn mcpH_set_property_value params =
(
    local spec = mcpReqStr params "object"
    local path = mcpReqStr params "property"
    if (mcpGet params "value") == undefined do mcpFail "err.missing_param" a1:"value"
    local rawValue = mcpGet params "value"

    local root = mcpResolveAny spec
    if root == undefined do mcpFail "err.node_not_found" a1:spec

    local res = mcpSetPropByPath root path rawValue
    if not res[1] do mcpFail "err.invalid_argument" a1:path a2:res[2]

    mcpRedraw()
    local p = #()
    mcpPair p "object" spec
    mcpPair p "property" path
    mcpPair p "ok" true
    mcpObj p
)


/*=================================================================== registry*/
fn mcpRegisterScene =
(
    mcpRegister "scene_info" mcpH_scene_info undoable:false
    mcpRegister "scene_statistics" mcpH_scene_statistics undoable:false
    mcpRegister "scene_new" mcpH_scene_new label:"New Scene"
    mcpRegister "scene_reset" mcpH_scene_reset label:"Reset 3ds Max"
    mcpRegister "scene_open" mcpH_scene_open label:"Open Scene"
    mcpRegister "scene_save" mcpH_scene_save undoable:false
    mcpRegister "scene_save_as" mcpH_scene_save_as undoable:false
    mcpRegister "scene_merge" mcpH_scene_merge label:"Merge Scene"

    mcpRegister "list_layers" mcpH_list_layers undoable:false
    mcpRegister "create_layer" mcpH_create_layer label:"Create Layer"
    mcpRegister "delete_layer" mcpH_delete_layer label:"Delete Layer"
    mcpRegister "set_layer_properties" mcpH_set_layer_properties label:"Layer Properties"
    mcpRegister "assign_to_layer" mcpH_assign_to_layer label:"Assign To Layer"
    mcpRegister "move_objects_to_new_layer" mcpH_move_objects_to_new_layer label:"Move To New Layer"

    mcpRegister "get_scene_assets" mcpH_get_scene_assets undoable:false
    mcpRegister "find_missing_assets" mcpH_find_missing_assets undoable:false
    mcpRegister "relink_assets" mcpH_relink_assets label:"Relink Assets"

    mcpRegister "read_text_file" mcpH_read_text_file undoable:false
    mcpRegister "write_text_file" mcpH_write_text_file undoable:false
    mcpRegister "list_directory" mcpH_list_directory undoable:false
    mcpRegister "file_exists" mcpH_file_exists undoable:false
    mcpRegister "make_directory" mcpH_make_directory undoable:false
    mcpRegister "copy_file" mcpH_copy_file undoable:false
    mcpRegister "delete_file" mcpH_delete_file undoable:false
    mcpRegister "get_file_info" mcpH_get_file_info undoable:false

    mcpRegister "list_max_classes" mcpH_list_max_classes undoable:false
    mcpRegister "does_class_exist" mcpH_does_class_exist undoable:false
    mcpRegister "list_scene_classes" mcpH_list_scene_classes undoable:false
    mcpRegister "get_class_properties" mcpH_get_class_properties undoable:false
    mcpRegister "get_class_methods" mcpH_get_class_methods undoable:false
    mcpRegister "get_property_value" mcpH_get_property_value undoable:false
    mcpRegister "set_property_value" mcpH_set_property_value label:"Set Property"
    ok
)

mcpRegisterScene()
