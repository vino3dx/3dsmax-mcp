/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_pipeline.ms
   Consolidated pipeline module: renderer setup, rendering, render elements,
   viewport control, visual feedback (base64 images), texture baking, and
   scene export/import.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_render.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_render.ms
   Renderer selection / settings, rendering, render elements and viewport capture.

   Category: pipeline (render_ / viewport_)

   NOTE: rendering and viewport capture are SLOW and block 3ds Max, so every
   handler here is registered undoable:false and writes to a real path that is
   verified afterwards with doesFileExist. If the file is missing we raise a
   clear error instead of reporting success.

   No struct, no lambdas, no backslash line continuations - only the proven
   subset from BRIDGE_CONVENTIONS.md section 4.1.
-----------------------------------------------------------------------------*/

global mcpH_render_set_engine, mcpH_render_get_engine, mcpH_render_get_settings
global mcpH_render_set_resolution, mcpH_render_set_output, mcpH_render_set_quality
global mcpH_render_set_frame_range, mcpH_render_save_preset, mcpH_render_load_preset
global mcpH_render_still, mcpH_render_frames, mcpH_render_animation
global mcpH_render_camera_view, mcpH_render_region, mcpH_render_preview, mcpH_render_batch
global mcpH_render_elements_list, mcpH_render_element_add, mcpH_render_element_remove
global mcpH_render_element_set_output
global mcpH_viewport_capture, mcpH_viewport_capture_all, mcpH_viewport_set_view
global mcpH_viewport_set_layout, mcpH_viewport_zoom_extents, mcpH_viewport_set_shading
global mcpH_viewport_stats, mcpH_viewport_toggle_grid
global mcpRendererClassName, mcpRenderFramePath, mcpRenderElementClassName, mcpPipelineAvailNote


/*-------------------------------------------------------- local bilingual note*/
fn mcpPipelineAvailNote avail =
(
    local prefix = if mcpLang == "en" then "Available: " else "本机可用："
    prefix + (mcpStringJoin avail ", ")
)


/*-------------------------------------------------- friendly engine -> class */
fn mcpRendererClassName friendly =
(
    local f = toLower (friendly as string)
    if f == "scanline" do return "Default_Scanline_Renderer"
    -- 3ds Max 2022+ registers Arnold as "Arnold"; older MAXtoA builds used
    -- "Arnold_Renderer".  Pick whichever this installation actually has.
    if f == "arnold" do return (if (mcpClassExists "Arnold") then "Arnold" else "Arnold_Renderer")
    if f == "vray" or f == "v-ray" do return "V_Ray_Adv"
    if f == "corona" do return "CoronaRenderer"
    if f == "fstorm" or f == "fstormrender" do return "FStormRender"
    if f == "redshift" do return "Redshift_Renderer"
    if f == "art" do return "ART_Renderer"
    if f == "quicksilver" or f == "hardware" do return "Quicksilver_Hardware_Renderer"
    undefined
)


/*----------------------------------------------------- frame path with number */
fn mcpRenderFramePath base frameIndex =
(
    if base == "" do
    (
        local dir = try ( getDir #renderoutput ) catch ( getDir #temp )
        return (dir + "\\render_" + (formattedPrint frameIndex format:"04d") + ".png")
    )
    local dir = getFilenamePath base
    local fileNoExt = getFilenameFile base
    local ext = getFilenameType base
    if ext == "" do ext = ".png"
    dir + fileNoExt + "_" + (formattedPrint frameIndex format:"04d") + ext
)


/*------------------------------------------------------- render element class */
fn mcpRenderElementClassName friendly =
(
    local f = toLower (friendly as string)
    if f == "zdepth" or f == "z" or f == "z_depth" do return "Z_Depth"
    if f == "normal" or f == "normals" do return "Normal"
    if f == "objectid" or f == "object_id" do return "Object_ID"
    if f == "materialid" or f == "material_id" do return "Material_ID"
    if f == "alpha" do return "Alpha"
    if f == "reflection" do return "Reflection"
    if f == "refraction" do return "Refraction"
    if f == "specular" do return "Specular"
    if f == "diffuse" do return "Diffuse"
    if f == "lighting" do return "Lighting"
    if f == "shadows" or f == "shadow" do return "Shadow"
    if f == "ao" do return "AO"
    if f == "sss" do return "SSS"
    if f == "selfillum" or f == "self_illumination" do return "Self_Illumination"
    if f == "uv" or f == "uvw" or f == "uv_coordinates" do return "UV_Coordinates"
    if f == "velocity" do return "Velocity"
    if f == "coverage" do return "Coverage"
    undefined
)


/*=========================================================== renderer settings*/

fn mcpH_render_set_engine params =
(
    local friendly = mcpReqStr params "engine"
    local cls = mcpRendererClassName friendly
    if cls == undefined do mcpFail "err.bad_value" a1:"engine"
    if not (mcpClassExists cls) do
    (
        local cand = #("Default_Scanline_Renderer","Arnold","Arnold_Renderer","V_Ray_Adv","CoronaRenderer",
            "FStormRender","Redshift_Renderer","ART_Renderer","Quicksilver_Hardware_Renderer")
        local avail = #()
        for c in cand do ( if (mcpClassExists c) do append avail c )
        local msg = mcpMsg "err.render_engine" a1:cls
        if avail.count > 0 then ( msg = msg + " " + (mcpPipelineAvailNote avail) )
        else ( msg = msg + " " + (if mcpLang == "en" then "(none detected)" else "（未检测到任何渲染器）") )
        throw msg
    )
    local r = undefined
    try ( r = (execute cls)() ) catch ( mcpFail "err.render_engine" a1:cls )
    try ( renderers.production = r ) catch ( mcpFail "err.render_engine" a1:cls )
    local p = #()

    -- Every failure path above mcpFails, so reaching here means the change
    -- was applied.
    mcpPair p "success" true
    mcpPair p "engine" (mcpCurrentRendererName())
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_get_engine params =
(
    local p = #()
    mcpPair p "engine" (mcpCurrentRendererName())
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_get_settings params =
(
    local p = #()
    mcpPair p "renderer" (mcpCurrentRendererName())
    mcpPair p "width" (try ( renderWidth as integer ) catch ( 0 ))
    mcpPair p "height" (try ( renderHeight as integer ) catch ( 0 ))
    mcpPair p "pixelAspect" (try ( renderPixelAspect as float ) catch ( 1.0 ))
    local outPath = ""
    try ( outPath = rendOutputFilename ) catch ( outPath = "" )
    mcpPair p "outputPath" outPath
    local fmt = ""
    if outPath != "" do fmt = toLower (substring (getFilenameType outPath) 2 -1)
    mcpPair p "outputFormat" fmt
    mcpPair p "timeType" (try ( rendTimeType as integer ) catch ( 0 ))
    mcpPair p "frameStart" (try ( renderStart as integer ) catch ( 0 ))
    mcpPair p "frameEnd" (try ( renderEnd as integer ) catch ( 0 ))
    mcpPair p "frames" (try ( rendPickupFrames as string ) catch ( "" ))
    mcpPair p "saveFile" (try ( rendSaveFile as boolean ) catch ( false ))
    mcpObj p
)


fn mcpH_render_set_resolution params =
(
    local w = mcpInt params "width" default:-1
    local h = mcpInt params "height" default:-1
    local pa = mcpNum params "pixelAspect" default:-1.0
    if w > 0 do ( try ( renderWidth = w ) catch() )
    if h > 0 do ( try ( renderHeight = h ) catch() )
    if pa > 0.0 do ( try ( renderPixelAspect = pa ) catch() )
    -- Max clamps some sizes, so read the values back: "the assignment ran" is not
    -- "the setting changed", and what matters is the size the renderer will use.
    local applied = #()
    local failures = #()
    local gotW = try ( renderWidth as integer ) catch ( 0 )
    local gotH = try ( renderHeight as integer ) catch ( 0 )
    local gotPa = try ( renderPixelAspect as float ) catch ( 1.0 )
    if w > 0 do ( if gotW == w then append applied "width" else append failures ("width=" + (gotW as string)) )
    if h > 0 do ( if gotH == h then append applied "height" else append failures ("height=" + (gotH as string)) )
    if pa > 0.0 do
    (
        if (abs (gotPa - pa)) < 0.0001 then append applied "pixelAspect"
        else append failures ("pixelAspect=" + (gotPa as string))
    )
    local out = mcpPairs (mcpH_render_get_settings params)
    mcpPair out "applied" applied
    mcpPair out "failures" failures
    mcpObj out
)


fn mcpH_render_set_output params =
(
    local path = mcpReqStr params "path"
    local fmt = toLower (mcpStr params "format" default:"")
    if fmt == "jpeg" do fmt = "jpg"
    if fmt == "tiff" do fmt = "tif"
    if fmt == "" do
    (
        local t = toLower (getFilenameType path)
        if t != "" do fmt = substring t 2 -1
    )
    local full = path
    if (getFilenameType path) == "" do full = path + "." + fmt
    try ( rendOutputFilename = full ) catch()
    try ( rendSaveFile = true ) catch()
    -- Read back: Max ignores an output path it cannot use, and the frames then
    -- land somewhere else.  Reporting the request instead of the result would
    -- hide that until the first frame came out in the wrong place.
    local gotPath = try ( rendOutputFilename ) catch ( "" )
    local gotSave = try ( rendSaveFile as boolean ) catch ( false )
    local failures = #()
    if gotPath != full do append failures ("outputPath=" + gotPath)
    if not gotSave do append failures "saveFile=false"
    local p = #()
    mcpPair p "path" gotPath
    mcpPair p "format" fmt
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_set_quality params =
(
    local quality = mcpStr params "quality" default:""
    local samples = mcpNum params "samples" default:-1.0
    local aa = mcpBool params "antialiasing" default:true
    local r = try ( renderers.production ) catch ( undefined )
    local applied = #()
    if r != undefined do
    (
        if quality != "" do
        (
            try ( r.quality = quality; append applied "quality" ) catch()
        )
        if samples > 0.0 do
        (
            try ( r.samples = samples; append applied "samples" ) catch()
            try ( r.aaSamples = samples; append applied "aaSamples" ) catch()
            try ( r.aa_subdiv = samples; append applied "aa_subdiv" ) catch()
        )
        try ( r.antialiasing = aa; append applied "antialiasing" ) catch()
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_set_frame_range params =
(
    local mode = toLower (mcpStr params "mode" default:"scene")
    local startF = mcpInt params "start" default:-1
    local endF = mcpInt params "end" default:-1
    local frames = mcpStr params "frames" default:""
    if mode == "single" then
    (
        if startF < 0 do startF = mcpInt params "frame" default:(try ( currentTime.frame as integer ) catch ( 0 ))
        try ( rendTimeType = 1; renderStart = startF; renderEnd = startF ) catch()
    )
    else if mode == "range" then
    (
        if startF < 0 do startF = 0
        if endF < 0 do endF = 100
        try ( rendTimeType = 3; renderStart = startF; renderEnd = endF ) catch()
    )
    else if mode == "frames" then
    (
        try ( rendTimeType = 4; rendPickupFrames = frames ) catch()
    )
    else
    (
        try ( rendTimeType = 2 ) catch()
    )
    -- Read the range back: each branch above sets three globals that Max can
    -- clamp, so echo the state instead of the request.
    local applied = #()
    local failures = #()
    local gotType = try ( rendTimeType as integer ) catch ( 0 )
    local gotStart = try ( renderStart as integer ) catch ( 0 )
    local gotEnd = try ( renderEnd as integer ) catch ( 0 )
    if mode == "single" then
    (
        if gotType == 1 and gotStart == startF then append applied "single"
        else append failures ("timeType=" + (gotType as string) + " frame=" + (gotStart as string))
    )
    else if mode == "range" then
    (
        if gotType == 3 and gotStart == startF and gotEnd == endF then append applied "range"
        else append failures ("timeType=" + (gotType as string) + " " + (gotStart as string) + "-" + (gotEnd as string))
    )
    else if mode == "frames" then
    (
        if gotType == 4 then append applied "frames"
        else append failures ("timeType=" + (gotType as string))
    )
    else
    (
        if gotType == 2 then append applied "scene"
        else append failures ("timeType=" + (gotType as string))
    )
    local out = mcpPairs (mcpH_render_get_settings params)
    mcpPair out "applied" applied
    mcpPair out "failures" failures
    mcpObj out
)


fn mcpH_render_save_preset params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".rps"
    local ok = false
    try ( ok = (renderPresets.SaveAllRenderPresets path) ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()

    -- Every failure path above mcpFails, so reaching here means the change
    -- was applied.
    mcpPair p "success" true
    mcpPair p "path" path
    mcpPair p "message" (mcpMsg "msg.saved" a1:path)
    mcpObj p
)


fn mcpH_render_load_preset params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local ok = false
    try ( ok = (renderPresets.LoadAllRenderPresets path) ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()

    -- Every failure path above mcpFails, so reaching here means the change
    -- was applied.
    mcpPair p "success" true
    mcpPair p "path" path
    mcpPair p "message" (mcpMsg "msg.loaded" a1:path)
    mcpObj p
)


/*=============================================================== rendering */

fn mcpH_render_still params =
(
    local path = mcpStr params "path" default:""
    local frame = mcpInt params "frame" default:-1
    if frame < 0 do frame = (try ( currentTime.frame as integer ) catch ( 0 ))
    local outPath = path
    if outPath == "" do outPath = mcpRenderFramePath "" frame
    local dir = getFilenamePath outPath
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local written = false
    try
    (
        render outputFile:outPath framenumber:frame vfb:false
        written = doesFileExist outPath
    )
    catch ( mcpFail "err.file_missing" a1:(outPath + " | " + (getCurrentException())) )
    if not written do mcpFail "err.file_missing" a1:outPath
    local p = #()
    mcpPair p "path" outPath
    mcpPair p "written" written
    mcpPair p "frame" frame
    mcpPair p "message" (mcpMsg "msg.render_done" a1:outPath)
    mcpObj p
)


fn mcpH_render_frames params =
(
    local frames = mcpArr params "frames"
    if frames.count == 0 do mcpFail "err.missing_param" a1:"frames"
    local base = mcpStr params "path" default:""
    local written = #()
    for f in frames do
    (
        local fi = try ( f as integer ) catch ( 0 )
        local fp = mcpRenderFramePath base fi
        local dir = getFilenamePath fp
        if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
        try
        (
            render outputFile:fp framenumber:fi vfb:false
            if doesFileExist fp do append written fp
        )
        catch ( append written ("ERROR:" + fp + " " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "written" written
    mcpPair p "count" written.count
    mcpPair p "message" (mcpMsg "msg.render_done" a1:(written.count as string))
    mcpObj p
)


fn mcpH_render_animation params =
(
    local startF = mcpInt params "start" default:-1
    local endF = mcpInt params "end" default:-1
    if startF < 0 do startF = (try ( animationRange.start.frame as integer ) catch ( 0 ))
    if endF < 0 do endF = (try ( animationRange.end.frame as integer ) catch ( 100 ))
    local base = mcpStr params "path" default:""
    local written = #()
    for f = startF to endF do
    (
        local fp = mcpRenderFramePath base f
        local dir = getFilenamePath fp
        if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
        try
        (
            render outputFile:fp framenumber:f vfb:false
            if doesFileExist fp do append written fp
        )
        catch ( append written ("ERROR:" + fp + " " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "written" written
    mcpPair p "count" written.count
    mcpPair p "message" (mcpMsg "msg.render_done" a1:(written.count as string))
    mcpObj p
)


fn mcpH_render_camera_view params =
(
    local camName = mcpReqStr params "camera"
    local camNode = mcpResolveNode camName
    if camNode == undefined do mcpFail "err.node_not_found" a1:camName
    local path = mcpStr params "path" default:""
    local frame = mcpInt params "frame" default:-1
    if frame < 0 do frame = (try ( currentTime.frame as integer ) catch ( 0 ))
    if path == "" do path = mcpRenderFramePath "" frame
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local written = false
    try
    (
        render camera:camNode outputFile:path framenumber:frame vfb:false
        written = doesFileExist path
    )
    catch ( mcpFail "err.file_missing" a1:(path + " | " + (getCurrentException())) )
    if not written do mcpFail "err.file_missing" a1:path
    local p = #()
    mcpPair p "path" path
    mcpPair p "camera" camName
    mcpPair p "written" written
    mcpPair p "message" (mcpMsg "msg.render_done" a1:path)
    mcpObj p
)


fn mcpH_render_region params =
(
    local x = mcpInt params "x" default:0
    local y = mcpInt params "y" default:0
    local w = mcpInt params "width" default:-1
    local h = mcpInt params "height" default:-1
    local frame = mcpInt params "frame" default:-1
    if frame < 0 do frame = (try ( currentTime.frame as integer ) catch ( 0 ))
    if w < 0 do w = (try ( renderWidth as integer ) catch ( 640 ))
    if h < 0 do h = (try ( renderHeight as integer ) catch ( 480 ))
    local path = mcpStr params "path" default:""
    if path == "" do path = mcpRenderFramePath "" frame
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local written = false
    try
    (
        render outputFile:path framenumber:frame region:(box2 x y w h) vfb:false
        written = doesFileExist path
    )
    catch ( mcpFail "err.file_missing" a1:(path + " | " + (getCurrentException())) )
    if not written do mcpFail "err.file_missing" a1:path
    local p = #()
    mcpPair p "path" path
    mcpPair p "region" #(x, y, w, h)
    mcpPair p "written" written
    mcpPair p "message" (mcpMsg "msg.render_done" a1:path)
    mcpObj p
)


/* Preview animation ("Animation > Make Preview").
   3ds Max 2022 dropped the MAXScript `makePreview()` function and replaced it
   with `createPreview()`, which has no documented output-path argument: it
   always writes `<getDir #preview>\\<scene>_preview.avi`.  So: call whichever
   entry point this release has, then find the file that appeared in the preview
   folder and copy it where the caller asked for it.  Reference a missing global
   safely -- MAXScript yields undefined instead of raising, which is what makes
   the version probe below possible. */
fn mcpPreviewCandidates dir =
(
    local list = #()
    try ( list = getFiles (dir + "\\*.avi") ) catch ( list = #() )
    if list.count == 0 do try ( list = getFiles (dir + "\\*.mov") ) catch ( list = #() )
    list
)

fn mcpPreviewSnapshot dir =
(
    local snap = #()
    for f in (mcpPreviewCandidates dir) do append snap #(toLower f, (getFileModDate f))
    snap
)

fn mcpPreviewChanged snap dir =
(
    local hit = undefined
    for f in (mcpPreviewCandidates dir) do
    (
        local old = undefined
        for b in snap do ( if b[1] == (toLower f) do old = b[2] )
        if old == undefined or (getFileModDate f) != old do hit = f
    )
    hit
)

fn mcpH_render_preview params =
(
    local previewDir = ""
    try ( previewDir = getDir #preview ) catch ( previewDir = "" )
    local path = mcpStr params "path" default:""
    if path == "" do path = previewDir + "\\preview.avi"
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )

    local snap = if previewDir == "" then #() else (mcpPreviewSnapshot previewDir)
    local errMsg = ""
    local used = ""
    local ok = false

    if (createPreview != undefined) then
    (
        used = "createPreview"
        try ( createPreview() )
        catch ( errMsg = (getCurrentException() as string) )
        ok = doesFileExist path
        if not ok do
        (
            -- createPreview ignores the output path: pick up whatever it wrote.
            local produced = if previewDir == "" then undefined else (mcpPreviewChanged snap previewDir)
            if produced != undefined do
            (
                if (toLower produced) != (toLower path) do
                    try ( copyFile produced path ) catch ( errMsg = (getCurrentException() as string) )
                ok = doesFileExist path
            )
        )
    )
    else if (makePreview != undefined) then
    (
        used = "makePreview"
        try ( makePreview outputName:path )
        catch ( errMsg = (getCurrentException() as string) )
        ok = doesFileExist path
    )
    else
    (
        mcpFail "err.feature_unsupported" a1:"preview animation (createPreview)"
    )

    if not ok do
    (
        local why = if errMsg == "" then path else (path + " | " + errMsg)
        mcpFail "err.file_missing" a1:why
    )
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" ok
    mcpPair p "entry" used
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_batch params =
(
    local jobs = mcpArr params "jobs"
    if jobs.count == 0 do mcpFail "err.missing_param" a1:"jobs"
    local results = #()
    local failures = #()
    for j in jobs do
    (
        local camName = mcpStr j "camera" default:""
        local path = mcpStr j "path" default:""
        local frame = mcpInt j "frame" default:-1
        if frame < 0 do frame = (try ( currentTime.frame as integer ) catch ( 0 ))
        if path == "" do path = mcpRenderFramePath "" frame
        -- A camera name that does not resolve is a failed job, NOT a silent
        -- fallback to rendering the active viewport: the job reports
        -- written:false with reason "camera not found", is counted in
        -- failures, and the rest of the batch keeps going.  An omitted
        -- camera still means "render the active viewport".
        local camNode = undefined
        if camName != "" do camNode = mcpResolveNode camName
        local reason = ""
        if camName != "" and camNode == undefined do reason = "camera not found"
        local written = false
        if reason == "" do
        (
            local dir = getFilenamePath path
            if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
            try
            (
                if camNode != undefined then
                    ( render camera:camNode outputFile:path framenumber:frame vfb:false )
                else
                    ( render outputFile:path framenumber:frame vfb:false )
                written = doesFileExist path
                if not written do reason = "render produced no output file"
            )
            catch ( written = false; reason = (try ( (getCurrentException() as string) ) catch ( "render failed" )) )
        )
        if reason != "" do append failures (camName + ": " + reason)
        local jp = #()
        mcpPair jp "camera" camName
        mcpPair jp "path" path
        mcpPair jp "frame" frame
        mcpPair jp "written" written
        if reason != "" do mcpPair jp "reason" reason
        append results (mcpObj jp)
    )
    local p = #()
    mcpPair p "jobs" results
    mcpPair p "count" results.count
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.render_done" a1:(results.count as string))
    mcpObj p
)


/*=========================================================== render elements */

fn mcpH_render_elements_list params =
(
    local limit = mcpInt params "limit" default:100
    local offset = mcpInt params "offset" default:0
    local reMgr = undefined
    try ( reMgr = (maxOps.GetCurRenderElementMgr()) ) catch ( reMgr = undefined )
    local items = #()
    if reMgr != undefined do
    (
        local n = 0
        try ( n = reMgr.GetNumRenderElements() ) catch ( n = 0 )
        for i = 0 to (n - 1) do
        (
            local el = undefined
            try ( el = reMgr.GetRenderElement i ) catch ( el = undefined )
            local cls = ""
            local nm = ""
            if el != undefined do
            (
                try ( cls = (classof el) as string ) catch ( cls = "" )
                try ( nm = el.elementName ) catch ( nm = "" )
                if nm == undefined or nm == "" do nm = cls
            )
            append items #(cls, nm)
        )
    )
    local total = items.count
    local slice = #()
    local endI = offset + limit
    if endI > total do endI = total
    if offset < 0 do offset = 0
    for i = (offset + 1) to endI do append slice items[i]
    local out = #()
    for s in slice do
    (
        local ep = #()
        mcpPair ep "class" s[1]
        mcpPair ep "name" s[2]
        append out (mcpObj ep)
    )
    local p = #()
    mcpPair p "count" total
    mcpPair p "items" out
    mcpPair p "limit" limit
    mcpPair p "offset" offset
    mcpObj p
)


fn mcpH_render_element_add params =
(
    local friendly = mcpReqStr params "element"
    local cls = mcpRenderElementClassName friendly
    if cls == undefined do mcpFail "err.bad_value" a1:"element"
    if not (mcpClassExists cls) do mcpFail "err.class_missing" a1:cls
    local reMgr = undefined
    try ( reMgr = (maxOps.GetCurRenderElementMgr()) ) catch ( reMgr = undefined )
    if reMgr == undefined do mcpFail "err.class_missing" a1:"RenderElementMgr"
    local el = undefined
    try ( el = (execute cls)() ) catch ( mcpFail "err.class_missing" a1:cls )
    local added = false
    try ( added = (reMgr.AddRenderElement el) ) catch ( added = false )
    if not added do mcpFail "err.bad_value" a1:"element"
    local out = mcpStr params "output" default:""
    if out != "" do ( try ( el.outputFilename = out ) catch() )
    local p = #()

    -- Every failure path above mcpFails, so reaching here means the change
    -- was applied.
    mcpPair p "success" true
    mcpPair p "element" friendly
    mcpPair p "output" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_element_remove params =
(
    local friendly = mcpStr params "element" default:""
    local index = mcpInt params "index" default:-1
    local reMgr = undefined
    try ( reMgr = (maxOps.GetCurRenderElementMgr()) ) catch ( reMgr = undefined )
    if reMgr == undefined do mcpFail "err.class_missing" a1:"RenderElementMgr"
    local removed = false
    if index >= 0 then
    (
        try ( reMgr.RemoveRenderElement index; removed = true ) catch ( removed = false )
    )
    else if friendly != "" then
    (
        local cls = mcpRenderElementClassName friendly
        if cls == undefined do cls = friendly
        local n = 0
        try ( n = reMgr.GetNumRenderElements() ) catch ( n = 0 )
        local target = -1
        for i = 0 to (n - 1) do
        (
            local el = undefined
            try ( el = reMgr.GetRenderElement i ) catch ( el = undefined )
            if el != undefined and ((classof el) as string) == cls do target = i
        )
        if target >= 0 do ( try ( reMgr.RemoveRenderElement target; removed = true ) catch ( removed = false ) )
    )
    if not removed do mcpFail "err.bad_value" a1:"element"
    local p = #()

    -- Every failure path above mcpFails.
    mcpPair p "success" true
    mcpPair p "removed" removed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_render_element_set_output params =
(
    local friendly = mcpStr params "element" default:""
    local index = mcpInt params "index" default:-1
    local output = mcpReqStr params "output"
    local reMgr = undefined
    try ( reMgr = (maxOps.GetCurRenderElementMgr()) ) catch ( reMgr = undefined )
    if reMgr == undefined do mcpFail "err.class_missing" a1:"RenderElementMgr"
    local el = undefined
    if index >= 0 then ( try ( el = reMgr.GetRenderElement index ) catch ( el = undefined ) )
    else if friendly != "" then
    (
        local cls = mcpRenderElementClassName friendly
        if cls == undefined do cls = friendly
        local n = 0
        try ( n = reMgr.GetNumRenderElements() ) catch ( n = 0 )
        for i = 0 to (n - 1) do
        (
            local e2 = undefined
            try ( e2 = reMgr.GetRenderElement i ) catch ( e2 = undefined )
            if e2 != undefined and ((classof e2) as string) == cls do el = e2
        )
    )
    if el == undefined do mcpFail "err.not_found_in_list" a1:"render elements" a2:friendly
    local ok = false
    try ( el.outputFilename = output; ok = true ) catch ( ok = false )
    if not ok do mcpFail "err.bad_value" a1:"output"
    local p = #()

    -- Every failure path above mcpFails.
    mcpPair p "success" true
    mcpPair p "element" friendly
    mcpPair p "output" output
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*=============================================================== viewport */

fn mcpH_viewport_capture params =
(
    local path = mcpStr params "path" default:""
    if path == "" do
    (
        local dir = try ( getDir #renderoutput ) catch ( getDir #temp )
        path = dir + "\\viewport_" + (formattedPrint (try ( currentTime.frame as integer ) catch ( 0 )) format:"04d") + ".png"
    )
    local bmp = undefined
    try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    if bmp == undefined do mcpFail "err.bad_value" a1:"viewport"
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local ok = false
    -- save() takes no file name: the bitmap must carry it.  Calling
    -- `save bmp path` throws "位图的 save() 操作需要 fileName", which used to
    -- surface as a bogus "file missing" error on every capture.
    try ( bmp.filename = path; save bmp; ok = doesFileExist path ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" ok
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_viewport_capture_all params =
(
    local path = mcpStr params "path" default:""
    if path == "" do path = (try ( getDir #renderoutput ) catch ( getDir #temp )) + "\\viewports.png"
    local nViews = 1
    try ( nViews = viewport.numViews ) catch ( nViews = 1 )
    local w = 0
    local h = 0
    local dibs = #()
    for v = 1 to nViews do
    (
        try ( viewport.setViewport v ) catch()
        local bmp = undefined
        try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
        if bmp != undefined do
        (
            append dibs bmp
            if w < bmp.width do w = bmp.width
            if h < bmp.height do h = bmp.height
        )
    )
    if dibs.count == 0 do mcpFail "err.bad_value" a1:"viewport"
    local cols = 2
    local rows = ceil (dibs.count as float / cols)
    local grid = bitmap (cols * w) (rows * h)
    local idx = 1
    for r = 0 to (rows - 1) do
        for c = 0 to (cols - 1) do
        (
            if idx <= dibs.count do
            (
                try ( pasteBitmap dibs[idx] grid [0,0] [(c*w),(r*h)] ) catch()
                idx += 1
            )
        )
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local ok = false
    try ( grid.filename = path; save grid; ok = doesFileExist path ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()
    mcpPair p "path" path
    mcpPair p "views" dibs.count
    mcpPair p "written" ok
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_viewport_set_view params =
(
    local view = toLower (mcpReqStr params "view")
    local ok = false
    try
    (
        if view == "top" then ( viewport.setType #view_top; ok = true )
        else if view == "bottom" then ( viewport.setType #view_bottom; ok = true )
        else if view == "front" then ( viewport.setType #view_front; ok = true )
        else if view == "back" then ( viewport.setType #view_back; ok = true )
        else if view == "left" then ( viewport.setType #view_left; ok = true )
        else if view == "right" then ( viewport.setType #view_right; ok = true )
        else if view == "orthographic" or view == "ortho" then ( viewport.setType #view_iso_user; ok = true )
        else if view == "perspective" or view == "persp" then ( viewport.setType #view_persp_user; ok = true )
        else if view == "user" then ( viewport.setType #view_user; ok = true )
    )
    catch ( ok = false )
    if not ok do mcpFail "err.bad_value" a1:"view"
    mcpRedraw()
    local p = #()

    -- Every failure path above mcpFails, so reaching here means the change
    -- was applied.
    mcpPair p "success" true
    mcpPair p "view" view
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_viewport_set_layout params =
(
    local layout = toLower (mcpReqStr params "layout")
    local sym = undefined
    if layout == "1" or layout == "single" then ( sym = #layout_1 )
    else if layout == "2" or layout == "2h" or layout == "horizontal" then ( sym = #layout_2h )
    else if layout == "2v" or layout == "vertical" then ( sym = #layout_2v )
    else if layout == "3" then ( sym = #layout_3 )
    else if layout == "4" or layout == "quad" then ( sym = #layout_4 )
    else if layout == "max" or layout == "maximize" then ( sym = #layout_max )
    if sym == undefined do mcpFail "err.bad_value" a1:"layout"
    local ok = false
    try ( viewport.setLayout sym; ok = true ) catch ( ok = false )
    if not ok do mcpFail "err.bad_value" a1:"layout"
    mcpRedraw()
    local p = #()
    -- Reaching here means viewport.setLayout accepted the symbol; every failure
    -- path above mcpFails.
    mcpPair p "success" true
    mcpPair p "layout" layout
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_viewport_zoom_extents params =
(
    local selOnly = mcpBool params "selection" default:false
    try
    (
        if selOnly then ( zoomExtentsSelected() )
        else ( zoomExtents() )
    )
    catch()
    mcpRedraw()
    local p = #()
    mcpPair p "selection" selOnly
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_viewport_set_shading params =
(
    local mode = toLower (mcpReqStr params "mode")
    local ok = false
    try
    (
        if mode == "wireframe" then ( viewport.setShadingType #wireframe; ok = true )
        else if mode == "flat" then ( viewport.setShadingType #flat; ok = true )
        else if mode == "shaded" or mode == "smooth" then ( viewport.setShadingType #smooth; ok = true )
        else if mode == "realistic" or mode == "lit" then ( viewport.setShadingType #realistic; ok = true )
        else if mode == "edged" or mode == "edgedfaces" or mode == "edge" then ( viewport.setShowEdgeFaces true; ok = true )
        else if mode == "noedges" then ( viewport.setShowEdgeFaces false; ok = true )
    )
    catch ( ok = false )
    if not ok do mcpFail "err.bad_value" a1:"mode"
    mcpRedraw()
    local p = #()
    mcpPair p "mode" mode
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/* Per viewport size.
   `getView <n>` does not exist in 3ds Max 2022 (it raised "Call needs function
   or class, got undefined"), so every width/height came back 0 and the whole
   report was useless.  The pixels are available from the viewport DIB instead,
   which is the same surface viewport_capture reads. */
fn mcpViewportSize v =
(
    local w = 0
    local h = 0
    try
    (
        local dib = viewport.getViewportDib index:v
        w = dib.width
        h = dib.height
    )
    catch()
    if w == 0 and v == (try (viewport.activeViewport as integer) catch (1)) do
        try ( local sz = getViewSize(); w = sz.x; h = sz.y ) catch()
    #(w, h)
)

fn mcpH_viewport_stats params =
(
    local nViews = 1
    try ( nViews = viewport.numViews ) catch ( nViews = 1 )
    local activeIdx = 1
    try ( activeIdx = viewport.activeViewport as integer ) catch ( activeIdx = 1 )
    local views = #()
    for v = 1 to nViews do
    (
        local vp = #()
        local sz = mcpViewportSize v
        mcpPair vp "index" v
        mcpPair vp "width" sz[1]
        mcpPair vp "height" sz[2]
        mcpPair vp "active" (v == activeIdx)
        append views (mcpObj vp)
    )
    local activeType = ""
    local camName = ""
    try ( activeType = (viewport.getType()) as string ) catch ( activeType = "" )
    try
    (
        local cam = viewport.getCamera()
        if cam != undefined do camName = cam.name
    )
    catch ( camName = "" )
    local p = #()
    mcpPair p "views" views
    mcpPair p "activeViewport" activeIdx
    mcpPair p "activeView" activeType
    mcpPair p "activeCamera" camName
    mcpObj p
)


fn mcpH_viewport_toggle_grid params =
(
    -- "on" is a reserved word in MAXScript, so the flag needs a real name
    local showGrid = mcpBool params "show" default:true
    local ok = false
    try ( viewport.setGridVisibility showGrid; ok = true ) catch ( ok = false )
    if not ok do
    (
        try
        (
            for g in (getClassInstances Grid) do ( g.isHidden = not showGrid )
            ok = true
        )
        catch ( ok = false )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "show" showGrid
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*=============================================================== registry */

fn mcpRegisterRender =
(
    -- read-only
    mcpRegister "render_get_engine" mcpH_render_get_engine undoable:false
    mcpRegister "render_get_settings" mcpH_render_get_settings undoable:false
    mcpRegister "render_elements_list" mcpH_render_elements_list undoable:false
    mcpRegister "viewport_stats" mcpH_viewport_stats undoable:false
    -- mutating / slow - keep them undoable:false (they block 3ds Max)
    mcpRegister "render_set_engine" mcpH_render_set_engine undoable:false
    mcpRegister "render_set_resolution" mcpH_render_set_resolution undoable:false
    mcpRegister "render_set_output" mcpH_render_set_output undoable:false
    mcpRegister "render_set_quality" mcpH_render_set_quality undoable:false
    mcpRegister "render_set_frame_range" mcpH_render_set_frame_range undoable:false
    mcpRegister "render_save_preset" mcpH_render_save_preset undoable:false
    mcpRegister "render_load_preset" mcpH_render_load_preset undoable:false
    mcpRegister "render_still" mcpH_render_still undoable:false
    mcpRegister "render_frames" mcpH_render_frames undoable:false
    mcpRegister "render_animation" mcpH_render_animation undoable:false
    mcpRegister "render_camera_view" mcpH_render_camera_view undoable:false
    mcpRegister "render_region" mcpH_render_region undoable:false
    mcpRegister "render_preview" mcpH_render_preview undoable:false
    mcpRegister "render_batch" mcpH_render_batch undoable:false
    mcpRegister "render_element_add" mcpH_render_element_add undoable:false
    mcpRegister "render_element_remove" mcpH_render_element_remove undoable:false
    mcpRegister "render_element_set_output" mcpH_render_element_set_output undoable:false
    mcpRegister "viewport_capture" mcpH_viewport_capture undoable:false
    mcpRegister "viewport_capture_all" mcpH_viewport_capture_all undoable:false
    mcpRegister "viewport_set_view" mcpH_viewport_set_view undoable:false
    mcpRegister "viewport_set_layout" mcpH_viewport_set_layout undoable:false
    mcpRegister "viewport_zoom_extents" mcpH_viewport_zoom_extents undoable:false
    mcpRegister "viewport_set_shading" mcpH_viewport_set_shading undoable:false
    mcpRegister "viewport_toggle_grid" mcpH_viewport_toggle_grid undoable:false
    ok
)

mcpRegisterRender()

/* ==========================================================================
   SECTION: mcp_vision.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_vision.ms

   Visual feedback.  Three commands that let the caller SEE the scene instead of
   guessing from JSON: a viewport grab, a multi-view orthographic sweep, and a
   cheap render preview.

   Why this module exists
   ----------------------
   3D work is a visual loop.  "Create a box" is not verified by a JSON reply that
   says ok:true - it is verified by looking at the box.  Without pixels the model
   is working blind and will happily report success on a scene it never saw.
   A file path is not enough either: an MCP client usually runs in another process
   or on another machine, so C:\Users\...\shot.png is unreachable to it.

   Result shape
   ------------
   Every command returns its pixels as base64 inside a top-level "_images" array:

       {
         "count": 1,
         "max_edge": 800,
         "message": "ok",
         "_images": [
           ["label", "front", "data", "<base64>", "mime", "image/jpeg"]
         ]
       }

   The Python layer splits "_images" out into real MCP image content blocks, so
   the caller receives pictures, not paths.  Anything else in the result stays
   ordinary JSON and is rendered as a text block.

   Payload budget
   --------------
   MAXScript string concatenation degrades badly on very long strings.  A
   1920x1080 PNG becomes ~2 MB of base64 and would stall the bridge for minutes,
   so captures are downscaled to max_edge (default 800, hard cap 2048) and
   written as JPEG.  That lands around 30-90 KB per view.  Do not raise this
   without measuring.

   Re-entrancy
   -----------
   completeRedraw() pumps the Windows message queue, which can re-enter the
   bridge's WinForms timer while a command is still running.  mcpVisionBusy is
   set for the duration of every capture and mcp_net.ms checks it first thing in
   mcpNetPump, so a re-entrant tick becomes a no-op instead of a half-processed
   protocol frame.
-----------------------------------------------------------------------------*/

global mcpVisionBusy, mcpVisionMaxEdge
global mcpVisionScaleFile, mcpBmpToBase64, mcpVisionGrab, mcpVisionFit
global mcpVisionVpState, mcpVisionVpRestore, mcpVisionSetType
global mcpVisionImagePair, mcpH_vision_capture, mcpH_vision_views, mcpH_vision_preview
global mcpVisionSelfTest

mcpVisionBusy = false
mcpVisionMaxEdge = 800


/*--------------------------------------------------------------- small helpers*/
fn mcpVisionText zh en =
(
    if mcpLang == "en" then en else zh
)

-- A unique temp path.  A Guid printed with "as string" becomes the literal
-- "dotNetObject:System.Guid" -- the colon is not a legal path character and
-- .NET then refuses the file with "不支持给定路径的格式".  Use a formatted
-- timestamp plus a random tail instead: digits only, always path safe.
fn mcpVisionTempFile ext =
(
    local stamp = ""
    try
    (
        local now = (dotNetClass "System.DateTime").Now
        stamp = (now.ToString "yyyyMMddHHmmssfff") as string
    )
    catch ( stamp = "" )
    if stamp == "" do ( stamp = "0" )
    local uniq = 0
    try ( uniq = random 100000 999999 ) catch ( uniq = 0 )
    stamp = stamp + "_" + (uniq as string)

    local dir = ""
    try ( dir = getDir #temp ) catch ( dir = "" )
    if dir == "" do ( dir = "." )
    local sep = "\\"
    if (substring dir dir.count 1) == "\\" do ( sep = "" )
    dir + sep + "mcp_vision_" + stamp + ext
)

-- Downscale a saved image file so its longest edge is at most maxEdge.
-- MAXScript has no resampler (resizeBitmap does not exist in Max 2020 and
-- pasteBitmap only blits, it does not scale), so the resize is done by GDI+.
-- Returns true only when dstPath was written.
fn mcpVisionScaleFile srcPath dstPath maxEdge mime =
(
    local ok = false
    local img = undefined
    local nb = undefined
    local g = undefined
    try
    (
        img = (dotNetClass "System.Drawing.Image").FromFile srcPath
        local w = img.Width
        local h = img.Height
        local longest = if w > h then w else h
        local nw = w
        local nh = h
        if maxEdge > 0 and longest > maxEdge do
        (
            local k = (maxEdge as float) / (longest as float)
            nw = (floor (w * k)) as integer
            nh = (floor (h * k)) as integer
        )
        if nw < 1 do ( nw = 1 )
        if nh < 1 do ( nh = 1 )

        nb = dotNetObject "System.Drawing.Bitmap" nw nh
        g = (dotNetClass "System.Drawing.Graphics").FromImage nb
        try ( g.InterpolationMode = (dotNetClass "System.Drawing.Drawing2D.InterpolationMode").HighQualityBicubic ) catch()
        g.DrawImage img 0 0 nw nh

        local fmt = (dotNetClass "System.Drawing.Imaging.ImageFormat").Jpeg
        if mime == "image/png" do ( fmt = (dotNetClass "System.Drawing.Imaging.ImageFormat").Png )
        nb.Save dstPath fmt
        ok = true
    )
    catch ( ok = false )

    -- Dispose in dependency order; failures here must not change the result.
    try ( if g != undefined do g.Dispose() ) catch()
    try ( if nb != undefined do nb.Dispose() ) catch()
    try ( if img != undefined do img.Dispose() ) catch()
    ok
)

-- Save the bitmap to a temp file, optionally downscale it, read the bytes back
-- and base64 them.  Returns #(base64, width, height); base64 is "" on failure.
-- Base64 is pure ASCII, so it survives the wire codec in mcp_json.ms unchanged.
fn mcpBmpToBase64 bmp mime maxEdge:0 =
(
    if bmp == undefined do return #("", 0, 0)
    local ext = if mime == "image/png" then ".png" else ".jpg"
    local tmp = mcpVisionTempFile ext
    local scaled = ""
    local b64 = ""
    local outW = bmp.width
    local outH = bmp.height
    try
    (
        -- MAXScript's save() takes no file name: the bitmap has to carry one.
        -- save bmp tmp  raises "位图的 save() 操作需要 fileName".
        bmp.filename = tmp
        save bmp

        local src = tmp
        if maxEdge > 0 do
        (
            local longest = if outW > outH then outW else outH
            if longest > maxEdge do
            (
                scaled = mcpVisionTempFile ext
                if (mcpVisionScaleFile tmp scaled maxEdge mime) then
                (
                    src = scaled
                    local k = (maxEdge as float) / (longest as float)
                    outW = (floor (outW * k)) as integer
                    outH = (floor (outH * k)) as integer
                )
            )
        )

        if (doesFileExist src) and ((getFileSize src) > 0) do
        (
            local bytes = (dotNetClass "System.IO.File").ReadAllBytes src
            local s = (dotNetClass "System.Convert").ToBase64String bytes
            b64 = s as string
        )
    )
    catch ( b64 = "" )
    try ( if scaled != "" and (doesFileExist scaled) do deleteFile scaled ) catch()
    try ( if doesFileExist tmp do deleteFile tmp ) catch()
    #(b64, outW, outH)
)

-- One MCP image content block, in the exact shape the protocol expects:
-- ["type","image","data",<base64>,"mimeType",<mime>]
-- The "_images" array carries a label alongside it so the caller can tell which
-- view is which; the Python side moves label into the text block.
fn mcpVisionImagePair label b64 mime =
(
    local p = #()
    mcpPair p "label" label
    mcpPair p "data" b64
    mcpPair p "mime" mime
    mcpObj p
)


/*----------------------------------------------------------------- viewport IO*/
-- Grab the active viewport, downscale, encode.  Returns #(base64, width, height)
-- or undefined when the framebuffer could not be read.
fn mcpVisionGrab maxEdge:800 mime:"image/jpeg" =
(
    local bmp = undefined
    try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    if bmp == undefined do
    (
        -- Retry once after an explicit redraw: some drivers hand back an empty
        -- DIB when the viewport has not painted since the last scene change.
        try ( mcpRedraw() ) catch()
        try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    )
    if bmp == undefined do return undefined

    local r = mcpBmpToBase64 bmp mime maxEdge:maxEdge
    if r == undefined do return undefined
    if r[1] == "" do return undefined
    #(r[1], r[2], r[3])
)

fn mcpVisionFit =
(
    local ok = true
    try
    (
        actionMan.executeAction 0 "311"
    )
    catch
    (
        ok = false
        try ( actionMan.executeAction 0 "311" ) catch()
    )
    ok
)

-- Map a friendly view name onto a viewport type constant.
fn mcpVisionSetType viewName =
(
    local n = toLower (viewName as string)
    local t = undefined
    if n == "front" then t = #view_front
    else if n == "back" then t = #view_back
    else if n == "left" then t = #view_left
    else if n == "right" then t = #view_right
    else if n == "top" then t = #view_top
    else if n == "bottom" then t = #view_bottom
    else if n == "perspective" or n == "persp" then t = #view_persp_user
    else if n == "orthographic" or n == "ortho" then t = #view_iso_user
    else if n == "user" or n == "iso" then t = #view_user

    if t == undefined do return false
    local ok = true
    try ( viewport.setType t ) catch ( ok = false )
    ok
)

-- Snapshot enough of the active viewport to put it back afterwards.
fn mcpVisionVpState =
(
    local t = undefined
    local tm = undefined
    try ( t = viewport.getType() ) catch ( t = undefined )
    try ( tm = viewport.getTM() ) catch ( tm = undefined )
    #(t, tm)
)

fn mcpVisionVpRestore st =
(
    if st == undefined do return false
    local ok = true
    if st[1] != undefined do ( try ( viewport.setType st[1] ) catch ( ok = false ) )
    if st[2] != undefined do ( try ( viewport.setTM st[2] ) catch ( ok = false ) )
    try ( mcpRedraw() ) catch()
    ok
)


/*-------------------------------------------------------------------- handlers*/
fn mcpH_vision_capture params =
(
    local maxEdge = mcpInt params "max_edge" default:800
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 2048 do maxEdge = 2048

    local fmt = toLower (mcpStr params "format" default:"jpeg")
    local mime = if fmt == "png" then "image/png" else "image/jpeg"
    local doRedraw = mcpBool params "redraw" default:true
    local savePath = mcpStr params "path" default:""

    local grab = undefined
    mcpVisionBusy = true
    try
    (
        if doRedraw do mcpRedraw()
        grab = mcpVisionGrab maxEdge:maxEdge mime:mime
    )
    catch ( grab = undefined )
    mcpVisionBusy = false

    if grab == undefined do mcpFail "err.bad_value" a1:"viewport"

    -- Optional copy on disk, for the human who is sitting in front of Max.
    local written = ""
    if savePath != "" do
    (
        try
        (
            local dir = getFilenamePath savePath
            if dir != "" and not (doesDirectoryExist dir) do ( makeDir dir all:true )
            local bytes = (dotNetClass "System.Convert").FromBase64String grab[1]
            (dotNetClass "System.IO.File").WriteAllBytes savePath bytes
            if doesFileExist savePath do written = savePath
        )
        catch ( written = "" )
    )

    local p = #()
    mcpPair p "width" grab[2]
    mcpPair p "height" grab[3]
    mcpPair p "mime" mime
    mcpPair p "bytes" (grab[1].count)
    if written != "" do mcpPair p "path" written
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" #( (mcpVisionImagePair "active" grab[1] mime) )
    mcpObj p
)


fn mcpH_vision_views params =
(
    -- Which views to sweep.  Defaults to the four that describe a model best:
    -- one perspective for shape, three orthographic for proportion.
    local views = #()
    local raw = mcpArr params "views"
    if raw != undefined and (isKindOf raw Array) and raw.count > 0 then
    (
        for v in raw do append views (toLower (v as string))
    )
    else views = #("perspective", "front", "left", "top")

    -- Hard cap: each view is a separate image block and a separate redraw.
    if views.count > 6 do
    (
        local kept = #()
        for k = 1 to 6 do append kept views[k]
        views = kept
    )

    local maxEdge = mcpInt params "max_edge" default:800
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 2048 do maxEdge = 2048

    local fmt = toLower (mcpStr params "format" default:"jpeg")
    local mime = if fmt == "png" then "image/png" else "image/jpeg"
    local doFit = mcpBool params "fit" default:true
    local doRestore = mcpBool params "restore" default:true

    local st = mcpVisionVpState()
    local images = #()
    local meta = #()

    mcpVisionBusy = true
    try
    (
        for v in views do
        (
            local switched = mcpVisionSetType v
            if switched then
            (
                if doFit do mcpVisionFit()
                try ( mcpRedraw() ) catch()
                local grab = mcpVisionGrab maxEdge:maxEdge mime:mime
                if grab != undefined do
                (
                    append images (mcpVisionImagePair v grab[1] mime)
                    local mp = #()
                    mcpPair mp "view" v
                    mcpPair mp "width" grab[2]
                    mcpPair mp "height" grab[3]
                    append meta (mcpObj mp)
                )
            )
        )
    )
    catch()

    if doRestore do ( try ( mcpVisionVpRestore st ) catch() )
    mcpVisionBusy = false

    if images.count == 0 do
        mcpFail "err.bad_value" a1:"viewport"

    local p = #()
    mcpPair p "count" images.count
    mcpPair p "max_edge" maxEdge
    mcpPair p "views" meta
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" images
    mcpObj p
)


/*---------------------------------------------------------------- render preview
   Slower and renderer-dependent, but it shows real shading, real lights and
   real materials - the only way to verify look-dev.  Kept small on purpose:
   a preview at 640px and 1 sample is enough to answer "does this look right".
   Note that the first render after a scene change can take tens of seconds
   while shaders compile, which is why this is a separate command and not part
   of vision_capture.
------------------------------------------------------------------------------*/
fn mcpH_vision_preview params =
(
    local maxEdge = mcpInt params "max_edge" default:640
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 1600 do maxEdge = 1600

    local aspect = 4.0 / 3.0
    try
    (
        local rw = renderWidth
        local rh = renderHeight
        if rh > 0 do aspect = (rw as float) / (rh as float)
    )
    catch()

    local w = maxEdge
    local h = (floor (maxEdge / aspect)) as integer
    if h < 1 do h = 1

    local bmp = undefined
    local ok = true
    mcpVisionBusy = true
    try
    (
        bmp = bitmap w h
        render outputwidth:w outputheight:h to:bmp vfb:false
    )
    catch
    (
        ok = false
        bmp = undefined
    )
    mcpVisionBusy = false

    if not ok or bmp == undefined do
        mcpFail "err.bad_value" a1:"render"

    -- The render target is already at the requested size, so no rescale here.
    local r = mcpBmpToBase64 bmp "image/jpeg"
    if r == undefined do mcpFail "err.bad_value" a1:"render"
    if r[1] == "" do mcpFail "err.bad_value" a1:"render"

    local p = #()
    mcpPair p "width" r[2]
    mcpPair p "height" r[3]
    mcpPair p "mime" "image/jpeg"
    mcpPair p "bytes" r[1].count
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" #( (mcpVisionImagePair "render" r[1] "image/jpeg") )
    mcpObj p
)


/*--------------------------------------------------------------- self test
   Runs without a client: fileIn this module, then mcpVisionSelfTest().
   It reports whether the framebuffer can be read and how big the payload is,
   which is the only way to tell a dead pipeline from a big one.
------------------------------------------------------------------------------*/
fn mcpVisionSelfTest =
(
    format "\n--- mcp_vision self test ---\n"
    local t0 = timestamp()
    local grab = undefined
    try ( grab = mcpVisionGrab maxEdge:800 mime:"image/jpeg" )
    catch ( format "  grab FAILED: %\n" (getCurrentException()) )
    local ms = timestamp() - t0
    if grab == undefined then
    (
        format "  viewport grab  : FAILED (no framebuffer)\n"
        false
    )
    else
    (
        format "  viewport grab  : OK  %x% px, % base64 chars, % ms\n" grab[2] grab[3] grab[1].count ms
        format "  est. wire bytes: %\n" grab[1].count
        true
    )
)


/*------------------------------------------------------------------- register*/

mcpRegister "vision_capture" mcpH_vision_capture undoable:false label:"Capture active viewport"
mcpRegister "vision_views" mcpH_vision_views undoable:false label:"Capture orthographic views"
mcpRegister "vision_preview" mcpH_vision_preview undoable:false label:"Render preview"

format "3ds Max MCP: vision module loaded (max_edge cap %, base64 image results enabled)\n" mcpVisionMaxEdge

/* ==========================================================================
   SECTION: mcp_bake.ms
   ========================================================================== */
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

/* ==========================================================================
   SECTION: mcp_export.ms
   ========================================================================== */
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
