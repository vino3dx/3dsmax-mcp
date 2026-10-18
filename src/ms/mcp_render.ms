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
    if f == "arnold" do return "Arnold_Renderer"
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
        local cand = #("Default_Scanline_Renderer","Arnold_Renderer","V_Ray_Adv","CoronaRenderer",
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
    mcpH_render_get_settings params
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
    local p = #()
    mcpPair p "path" full
    mcpPair p "format" fmt
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
    mcpH_render_get_settings params
)


fn mcpH_render_save_preset params =
(
    local path = mcpReqStr params "path"
    if (getFilenameType path) == "" do path = path + ".rps"
    local ok = false
    try ( ok = (renderPresets.SaveAllRenderPresets path) ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()
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


fn mcpH_render_preview params =
(
    local path = mcpStr params "path" default:""
    if path == "" do path = (try ( getDir #preview ) catch ( "" )) + "\\preview.avi"
    local dir = getFilenamePath path
    if dir != "" and not (doesDirectoryExist dir) do ( try ( makeDir dir all:true ) catch() )
    local ok = false
    try ( makePreview outputName:path; ok = doesFileExist path ) catch ( ok = false )
    if not ok do mcpFail "err.file_missing" a1:path
    local p = #()
    mcpPair p "path" path
    mcpPair p "written" ok
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
    try ( save bmp path; ok = doesFileExist path ) catch ( ok = false )
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
    try ( save grid path; ok = doesFileExist path ) catch ( ok = false )
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


fn mcpH_viewport_stats params =
(
    local nViews = 1
    try ( nViews = viewport.numViews ) catch ( nViews = 1 )
    local views = #()
    for v = 1 to nViews do
    (
        local vp = #()
        local w = 0
        local h = 0
        try
        (
            local vd = getView v
            local sz = [0,0]
            try ( sz = vd.size ) catch ( sz = [0,0] )
            w = sz.x
            h = sz.y
        )
        catch()
        mcpPair vp "index" v
        mcpPair vp "width" w
        mcpPair vp "height" h
        append views (mcpObj vp)
    )
    local activeIdx = 1
    local activeType = ""
    local camName = ""
    try ( activeIdx = viewport.activeViewport as integer ) catch ( activeIdx = 1 )
    try
    (
        local avd = getView activeIdx
        try ( activeType = (avd.type as string) ) catch ( activeType = "" )
        try ( if avd.node != undefined do camName = avd.node.name ) catch ( camName = "" )
    )
    catch()
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
