/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_system.ms
   Consolidated system, bridge control, scene session, layers, assets, file IO,
   MAXScript introspection, and in-Max self-test diagnostics.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_system.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_system.ms
   Bridge / environment / scripting escape hatch commands.

   Category: system
-----------------------------------------------------------------------------*/

global mcpH_bridge_status, mcpH_bridge_ping, mcpH_bridge_stop, mcpH_bridge_restart
global mcpH_bridge_capabilities, mcpH_set_language, mcpH_get_language
global mcpH_get_max_version, mcpH_get_paths, mcpH_get_system_info, mcpH_list_render_engines
global mcpH_execute_maxscript, mcpH_execute_python
global mcpH_undo_last, mcpH_redo_last, mcpH_begin_undo, mcpH_end_undo, mcpH_cancel_undo
global mcpH_hold_scene, mcpH_fetch_scene, mcpH_release_scene
global mcpH_set_units, mcpH_get_units, mcpH_set_time_config, mcpH_get_time_config
global mcpResultToJson


/*----------------------------------------------------------------- bridge ops*/
fn mcpH_bridge_status params =
(
    local p = #()
    mcpPair p "running" mcpRunning
    mcpPair p "host" mcpHost
    mcpPair p "port" mcpPort
    mcpPair p "clients" mcpConns.count
    mcpPair p "timerActive" (mcpTimer != undefined)
    mcpPair p "language" mcpLang
    mcpPair p "maxLanguage" (mcpMaxLanguageCode())
    mcpPair p "languagePinned" (mcpIsLanguagePinned())
    mcpPair p "handlerCount" mcpRegistry.count
    mcpPair p "maxVersion" (mcpVersionInfo())
    mcpPair p "sceneName" (try ( maxFileName ) catch ( "" ))
    mcpPair p "scenePath" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "selectionCount" (try ( selection.count ) catch ( 0 ))
    mcpObj p
)

fn mcpH_bridge_ping params =
(
    local p = #()
    mcpPair p "pong" true
    mcpPair p "timeStamp" (timeStamp())
    mcpPair p "language" mcpLang
    mcpPair p "maxYear" (mcpMaxYear())
    mcpObj p
)

/* Not exposed as an MCP tool any more (see catalog/core.py): the socket the
   reply would travel on is the one this closes, so an AI client that calls it
   loses the channel for good.  It stays registered for the panel and for the
   Listener, and it prints the recovery line to the Listener, because the
   response body itself can never be delivered. */
fn mcpH_bridge_stop params =
(
    mcpNetStop()
    try
    (
        format "3ds Max MCP: bridge stopped. Recover with mcpBridgeStart() in this Listener,\nor press \"Start bridge\" in the Vino 3dsMax MCP panel.\n"
    )
    catch()
    local p = #()
    mcpPair p "running" false
    mcpPair p "recovery" "mcpBridgeStart() in the MAXScript Listener, or Start bridge in the Max panel"
    mcpPair p "message" (mcpMsg "msg.bridge_stopped")
    mcpObj p
)

fn mcpH_bridge_restart params =
(
    local p = mcpInt params "port" default:mcpPort
    mcpNetStart port:p
)

fn mcpH_bridge_capabilities params =
(
    local names = #()
    local groups = #()
    local prefixes = #()

    for e in mcpRegistry do
    (
        local n = e[1]
        append names n
        local us = findString n "_"
        local prefix = if us == undefined then n else (substring n 1 (us - 1))
        local idx = 0
        for k = 1 to prefixes.count while idx == 0 do ( if prefixes[k] == prefix do idx = k )
        if idx == 0 then
        (
            append prefixes prefix
            append groups #(prefix, #(n))
        )
        else append groups[idx][2] n
    )

    local grouped = #()
    for g in groups do
    (
        local gp = #()
        mcpPair gp "prefix" g[1]
        mcpPair gp "commands" g[2]
        append grouped (mcpObj gp)
    )

    local p = #()
    mcpPair p "count" names.count
    mcpPair p "commands" names
    mcpPair p "groups" grouped
    mcpObj p
)

fn mcpH_set_language params =
(
    local lang = mcpStr params "language"
    if lang == "" do lang = mcpStr params "lang"
    if lang == "" do mcpFail "err.missing_param" a1:"language"
    mcpSetLanguage lang
    local p = #()
    mcpPair p "language" mcpLang
    mcpPair p "pinned" (mcpIsLanguagePinned())
    mcpPair p "maxLanguage" (mcpMaxLanguageCode())
    mcpPair p "message" (if mcpLang == "en" then "Language switched to English." else "语言已切换为简体中文。")
    mcpObj p
)

fn mcpH_get_language params =
(
    local p = #()
    mcpPair p "language" mcpLang
    mcpPair p "pinned" (mcpIsLanguagePinned())
    mcpPair p "maxLanguage" (mcpMaxLanguageCode())
    mcpObj p
)


/*----------------------------------------------------------------- environment*/
fn mcpH_get_max_version params = ( mcpVersionInfo() )

fn mcpH_get_paths params =
(
    local p = #()
    mcpPair p "maxRoot" (try ( getDir #maxRoot ) catch ( "" ))
    mcpPair p "scripts" (try ( getDir #scripts ) catch ( "" ))
    mcpPair p "userScripts" (try ( getDir #userScripts ) catch ( "" ))
    mcpPair p "startupScripts" (try ( getDir #startupScripts ) catch ( "" ))
    mcpPair p "scene" (try ( getDir #scene ) catch ( "" ))
    mcpPair p "export" (try ( getDir #export ) catch ( "" ))
    mcpPair p "import" (try ( getDir #import ) catch ( "" ))
    mcpPair p "renderOutput" (try ( getDir #renderoutput ) catch ( "" ))
    mcpPair p "temp" (try ( getDir #temp ) catch ( "" ))
    mcpPair p "autoback" (try ( getDir #autoback ) catch ( "" ))
    mcpPair p "pluginCfg" (try ( getDir #plugcfg ) catch ( "" ))
    mcpPair p "materialLib" (try ( getDir #matlib ) catch ( "" ))
    mcpPair p "maxLanguage" (try ( getLanguage() as string ) catch ( "" ))
    mcpObj p
)

fn mcpH_get_system_info params =
(
    local p = #()
    mcpPair p "maxYear" (mcpMaxYear())
    mcpPair p "major" (mcpMaxMajor())
    mcpPair p "version" (try ( maxVersion() as string ) catch ( "" ))
    mcpPair p "renderer" (mcpCurrentRendererName())
    mcpPair p "units" (try ( (units.SystemType) as string ) catch ( "" ))
    mcpPair p "unitScale" (try ( (units.SystemScale) as float ) catch ( 1.0 ))
    mcpPair p "displayUnits" (try ( (units.DisplayType) as string ) catch ( "" ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "animationStart" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "animationEnd" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "selectionCount" (try ( selection.count ) catch ( 0 ))
    mcpPair p "sceneName" (try ( maxFileName ) catch ( "" ))
    mcpPair p "scenePath" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "language" mcpLang
    mcpPair p "systemLanguage" (try ( getSystemLanguage() as string ) catch ( "" ))
    mcpObj p
)

fn mcpH_list_render_engines params =
(
    local found = #()
    local candidates = #(
        "Default_Scanline_Renderer", "Arnold_Renderer", "V_Ray_Adv", "CoronaRenderer",
        "FStormRender", "Redshift_Renderer", "ART_Renderer", "Quicksilver_Hardware_Renderer"
    )
    for c in candidates do ( if mcpClassExists c do append found c )
    local p = #()
    mcpPair p "current" (mcpCurrentRendererName())
    mcpPair p "available" found
    mcpObj p
)


/*-------------------------------------------------------------- scripting API*/
fn mcpResultToJson value =
(
    if value == undefined then return undefined
    if classof value == BooleanClass then return value
    if isKindOf value Number then return value
    if isKindOf value String then return value
    if isKindOf value Point3 then return value
    if isKindOf value Color then return value
    if isKindOf value Array then
    (
        if value.count > 512 then
        (
            local head = #()
            for i = 1 to 512 do append head (mcpResultToJson value[i])
            local p = #()
            mcpPair p "count" value.count
            mcpPair p "truncated" true
            mcpPair p "items" head
            return (mcpObj p)
        )
        local out = #()
        for v in value do append out (mcpResultToJson v)
        return out
    )
    try ( return (value as string) ) catch ( return undefined )
)

fn mcpH_execute_maxscript params =
(
    local code = mcpStr params "code"
    if code == "" do code = mcpStr params "command"
    if code == "" do mcpFail "err.missing_param" a1:"code"
    local useUndo = mcpBool params "asOneUndo" default:false
    local label = mcpStr params "label" default:"MAXScript"

    local began = false
    if useUndo do began = mcpHoldBegin()

    local raw = undefined
    local failure = undefined
    try ( raw = execute code )
    catch ( failure = getCurrentException() )

    if began do
    (
        if failure == undefined then mcpHoldAccept (mcpMsg "msg.undo_label" a1:label)
        else mcpHoldCancel()
    )
    if failure != undefined do throw failure

    local p = #()
    -- The script threw above if it failed, so reaching here means it ran to the
    -- end.  Saying so explicitly keeps reliability mode from calling a finished
    -- script a failure just because MAXScript returns no verdict of its own.
    mcpPair p "success" true
    mcpPair p "result" (mcpResultToJson raw)
    mcpPair p "resultText" (try ( raw as string ) catch ( "" ))
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_execute_python params =
(
    local code = mcpStr params "code"
    if code == "" do mcpFail "err.missing_param" a1:"code"

    local pyVersion = ""
    local available = true
    local probe = "import sys, platform; sys.version.split()[0] + ' / ' + platform.python_implementation()"
    try ( pyVersion = python.Execute probe )
    catch ( available = false )

    if not available do
    (
        local p = #()
        mcpPair p "available" false
        mcpPair p "message" (if mcpLang == "en" then
            "Python is not available in this 3ds Max installation (3ds Max 2020 ships Python 2.7 only; 2021 and later ship Python 3)."
            else "当前 3ds Max 未启用 Python。3ds Max 2020 出厂仅随附 Python 2.7，2021 及以后版本随附 Python 3。")
        return (mcpObj p)
    )

    -- python.Execute() answers "success" for any statement block and never
    -- surfaces print() output, which made this tool useless for real Python
    -- work.  Run the code through a small driver instead: it captures stdout,
    -- tracebacks and the exit status, then hands the text back through a file.
    local tmpDir = (try ( getDir #temp ) catch ( "C:/Temp" )) + "\\3dsmax-mcp"
    try ( makeDir tmpDir all:true ) catch()
    local codePath = tmpDir + "\\mcp_py_code.py"
    local outPath = tmpDir + "\\mcp_py_out.txt"
    local drvPath = tmpDir + "\\mcp_py_driver.py"

    local io = (dotNetClass "System.IO.File")
    try ( io.WriteAllText codePath code (dotNetClass "System.Text.Encoding").UTF8 )
    catch ( mcpFail "err.bad_value" a1:"code" )

    local drvText = "import io, sys, traceback\n"
    drvText += "cp = r\"" + (substituteString codePath "\\" "/") + "\"\n"
    drvText += "op = r\"" + (substituteString outPath "\\" "/") + "\"\n"
    drvText += "buf = io.StringIO()\n"
    drvText += "old = sys.stdout\n"
    drvText += "sys.stdout = buf\n"
    drvText += "status = 'OK'\n"
    drvText += "try:\n"
    drvText += "    src = io.open(cp, 'r', encoding='utf-8-sig').read()\n"
    drvText += "    exec(compile(src, cp, 'exec'), {'__name__': '__main__'})\n"
    drvText += "except Exception:\n"
    drvText += "    status = 'ERR'\n"
    drvText += "    buf.write(traceback.format_exc())\n"
    drvText += "finally:\n"
    drvText += "    sys.stdout = old\n"
    drvText += "f = io.open(op, 'w', encoding='utf-8')\n"
    drvText += "f.write(status + '\\n' + buf.getvalue())\n"
    drvText += "f.close()\n"
    try ( io.WriteAllText drvPath drvText (dotNetClass "System.Text.Encoding").UTF8 )
    catch ( mcpFail "err.bad_value" a1:"driver" )
    try ( io.Delete outPath ) catch()

    local failure = undefined
    try ( python.ExecuteFile drvPath )
    catch ( failure = getCurrentException() )
    if failure != undefined do throw failure

    local text = ""
    try ( if io.Exists outPath do text = io.ReadAllText outPath (dotNetClass "System.Text.Encoding").UTF8 )
    catch ( text = "" )

    local status = ""
    local body = text
    local nl = findString text "\n"
    if nl != undefined do
    (
        status = substring text 1 (nl - 1)
        body = substring text (nl + 1) -1
    )

    local p = #()
    mcpPair p "available" true
    mcpPair p "pythonVersion" (pyVersion as string)
    mcpPair p "ok" (status != "ERR")
    mcpPair p "output" body
    mcpPair p "result" (mcpResultToJson status)
    mcpPair p "resultText" body
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------------------- undo*/
fn mcpH_undo_last params =
(
    local steps = mcpInt params "steps" default:1
    local done = 0
    for i = 1 to steps do
    (
        local ok = true
        try ( actionMan.executeAction 0 "40005" ) catch ( ok = false )
        if ok then done += 1 else exit
    )
    local p = #()
    mcpPair p "steps" done
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_redo_last params =
(
    local steps = mcpInt params "steps" default:1
    local done = 0
    for i = 1 to steps do
    (
        local ok = true
        try ( actionMan.executeAction 0 "40006" ) catch ( ok = false )
        if ok then done += 1 else exit
    )
    local p = #()
    mcpPair p "steps" done
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_begin_undo params =
(
    local label = mcpStr params "label" default:"MCP"
    local ok = mcpHoldBegin()
    local p = #()
    mcpPair p "open" ok
    mcpPair p "label" label
    mcpObj p
)

fn mcpH_end_undo params =
(
    local label = mcpStr params "label" default:"MCP"
    local p = #()
    mcpPair p "accepted" (mcpHoldAccept label)
    mcpObj p
)

fn mcpH_cancel_undo params =
(
    local p = #()
    mcpPair p "cancelled" (mcpHoldCancel())
    mcpObj p
)


/*------------------------------------------------------------- scene holding*/
fn mcpH_hold_scene params =
(
    holdMaxFile()
    local p = #()
    mcpPair p "held" true
    mcpObj p
)

fn mcpH_fetch_scene params =
(
    fetchMaxFile quiet:true
    local p = #()
    mcpPair p "fetched" true
    mcpObj p
)

fn mcpH_release_scene params =
(
    try ( acceptMaxFile() ) catch()
    local p = #()
    mcpPair p "released" true
    mcpObj p
)


/*----------------------------------------------------------------------- units*/
fn mcpH_set_units params =
(
    local systemType = toLower (mcpStr params "systemType" default:"")
    local displayType = toLower (mcpStr params "displayType" default:"")
    local scale = mcpNum params "scale" default:-1.0

    local known = #(
        #("millimeters", #Millimeters), #("centimeters", #Centimeters), #("meters", #Meters),
        #("kilometers", #Kilometers), #("inches", #Inches), #("feet", #Feet), #("miles", #Miles)
    )
    for k in known do
    (
        if systemType == k[1] do
        (
            local ok = true
            try ( units.SystemType = k[2] ) catch ( ok = false )
            if not ok do mcpFail "err.bad_value" a1:"systemType"
        )
    )
    if scale > 0.0 do ( try ( units.SystemScale = scale ) catch() )

    if displayType != "" then
    (
        if displayType == "metric" then ( try ( units.DisplayType = #Metric ) catch() )
        else if displayType == "us" then ( try ( units.DisplayType = #US ) catch() )
        else if displayType == "generic" then ( try ( units.DisplayType = #Generic ) catch() )
        else ( mcpFail "err.bad_value" a1:("displayType=" + displayType) )
    )

    -- Read the scale back: Max clamps it, and a wrong scale makes every later
    -- dimension wrong without anything looking broken.  Display type has no
    -- portable read-back across versions, so it is reported as requested but
    -- unverified rather than assumed to have worked.
    local failures = #()
    local gotScale = try ( units.SystemScale as float ) catch ( -1.0 )
    if scale > 0.0 and (abs (gotScale - scale)) > 0.000001 do
        append failures ("systemScale=" + (gotScale as string))
    local out = mcpPairs (mcpH_get_units params)
    mcpPair out "failures" failures
    mcpObj out
)

fn mcpH_get_units params =
(
    local p = #()
    mcpPair p "systemType" (try ( (units.SystemType) as string ) catch ( "" ))
    mcpPair p "systemScale" (try ( (units.SystemScale) as float ) catch ( 1.0 ))
    mcpPair p "displayType" (try ( (units.DisplayType) as string ) catch ( "" ))
    mcpPair p "metricType" (try ( (units.MetricType) as string ) catch ( "" ))
    mcpObj p
)


/*------------------------------------------------------------------ time setup*/
fn mcpH_set_time_config params =
(
    local applied = #()

    if (mcpGet params "frameRate") != undefined do
    (
        local fr = mcpInt params "frameRate"
        try ( frameRate = fr; append applied "frameRate" ) catch()
    )
    if (mcpGet params "startFrame") != undefined and (mcpGet params "endFrame") != undefined do
    (
        local s = mcpInt params "startFrame"
        local e = mcpInt params "endFrame"
        try ( animationRange = interval s e; append applied "animationRange" ) catch()
    )
    if (mcpGet params "playbackSpeed") != undefined do
    (
        local sp = mcpNum params "playbackSpeed"
        try ( timeConfiguration.playbackSpeed = sp; append applied "playbackSpeed" ) catch()
    )

    local out = mcpH_get_time_config params
    mcpPair out "applied" applied
    out
)

fn mcpH_get_time_config params =
(
    local p = #()
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "currentFrame" (try ( currentTime.frame as integer ) catch ( 0 ))
    mcpPair p "currentTime" (try ( currentTime as string ) catch ( "" ))
    mcpObj p
)


/*------------------------------------------------------------------- registry*/
fn mcpRegisterSystem =
(
    mcpRegister "bridge_status" mcpH_bridge_status undoable:false
    mcpRegister "bridge_ping" mcpH_bridge_ping undoable:false
    mcpRegister "bridge_stop" mcpH_bridge_stop undoable:false
    mcpRegister "bridge_restart" mcpH_bridge_restart undoable:false
    mcpRegister "bridge_capabilities" mcpH_bridge_capabilities undoable:false
    mcpRegister "set_language" mcpH_set_language undoable:false
    mcpRegister "get_language" mcpH_get_language undoable:false
    mcpRegister "get_max_version" mcpH_get_max_version undoable:false
    mcpRegister "get_paths" mcpH_get_paths undoable:false
    mcpRegister "get_system_info" mcpH_get_system_info undoable:false
    mcpRegister "list_render_engines" mcpH_list_render_engines undoable:false
    mcpRegister "execute_maxscript" mcpH_execute_maxscript undoable:false label:"Execute MAXScript"
    mcpRegister "execute_python" mcpH_execute_python undoable:false label:"Execute Python"
    mcpRegister "undo_last" mcpH_undo_last undoable:false
    mcpRegister "redo_last" mcpH_redo_last undoable:false
    mcpRegister "begin_undo" mcpH_begin_undo undoable:false
    mcpRegister "end_undo" mcpH_end_undo undoable:false
    mcpRegister "cancel_undo" mcpH_cancel_undo undoable:false
    mcpRegister "hold_scene" mcpH_hold_scene undoable:false
    mcpRegister "fetch_scene" mcpH_fetch_scene undoable:false
    mcpRegister "release_scene" mcpH_release_scene undoable:false
    mcpRegister "set_units" mcpH_set_units undoable:false label:"Set Units"
    mcpRegister "get_units" mcpH_get_units undoable:false
    mcpRegister "set_time_config" mcpH_set_time_config undoable:false label:"Set Time Configuration"
    mcpRegister "get_time_config" mcpH_get_time_config undoable:false
    ok
)

mcpRegisterSystem()

/* ==========================================================================
   SECTION: mcp_scene.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_scene.ms
   Scene session management, layers, external assets, file IO and MAXScript
   introspection.

   Categories: scene, files, system (introspection)
-----------------------------------------------------------------------------*/

global mcpH_scene_info, mcpH_scene_statistics, mcpH_scene_new, mcpH_scene_reset
-- Owned by mcp_context.ms, which loads after this module; declared here so the
-- lookup in mcpSceneSuperKind reads a real global instead of a new local.
global mcpCtxSuperKind, mcpSceneSuperKind
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

fn mcpSceneSuperKind o =
(
    /* Prefer the shared classifier in mcp_context.ms so statistics and the
       context layer can never disagree.  It is loaded after this module, so the
       lookup happens at call time, and the local rules below are the same ones
       -- kept as a degraded path rather than falling back to "other", which is
       exactly the bug this replaces. */
    if mcpCtxSuperKind != undefined do
    (
        local k = "other"
        try ( k = mcpCtxSuperKind o ) catch ( k = "other" )
        return k
    )

    local v = ""
    try ( v = toLower ((superclassof o) as string) ) catch ( v = "" )
    local cls = ""
    try ( cls = (classof o) as string ) catch ( cls = "" )
    if cls == "BoneGeometry" do return "bone"
    if cls == "Biped_Object" do return "bone"
    if cls == "CATBone" do return "bone"
    if (findString v "spacewarp") != undefined do return "spacewarp"
    if (findString v "geometry") != undefined do return "geometry"
    if (findString v "shape") != undefined do return "shape"
    if (findString v "spline") != undefined do return "shape"
    if (findString v "light") != undefined do return "light"
    if (findString v "camera") != undefined do return "camera"
    if (findString v "helper") != undefined do return "helper"
    if (findString v "system") != undefined do return "system"
    if (findString v "particle") != undefined do return "particle"
    "other"
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
    local systemCount = 0
    local boneCount = 0
    local particleCount = 0
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
            case (mcpSceneSuperKind o) of
            (
                "geometry":   geometryCount += 1
                "shape":      shapeCount += 1
                "light":      lightCount += 1
                "camera":     cameraCount += 1
                "helper":     helperCount += 1
                "spacewarp":  spacewarpCount += 1
                "system":     systemCount += 1
                "bone":       boneCount += 1
                "particle":   particleCount += 1
                default:      otherCount += 1
            )
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
    -- `systems` used to be fed from the bone counter; systems and bones are
    -- different things and neither could ever match, so both stayed 0.
    mcpPair p "systems" systemCount
    mcpPair p "bones" boneCount
    mcpPair p "particles" particleCount
    mcpPair p "other" otherCount
    mcpPair p "hidden" hiddenCount
    mcpPair p "frozen" frozenCount
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "materials" materialCount
    mcpPair p "bitmaps" bitmapCount
    mcpPair p "classification" "superclassof normalised via mcpSceneSuperKind"
    mcpObj p
)


/*=============================================================== scene session*/
fn mcpH_scene_new params =
(
    -- keepScene used to be advertised but never read: every call reset the units,
    -- frame rate and render size along with the objects.  Remember the session
    -- settings first, then put them back after the reset.
    local keep = mcpBool params "keepScene" default:false
    local unitsType = undefined
    local unitsScale = 1.0
    local fps = 0
    local rw = 0
    local rh = 0
    if keep do
    (
        try ( unitsType = units.SystemType ) catch ( unitsType = undefined )
        try ( unitsScale = units.SystemScale as float ) catch ( unitsScale = 1.0 )
        try ( fps = frameRate as integer ) catch ( fps = 0 )
        try ( rw = renderWidth as integer ) catch ( rw = 0 )
        try ( rh = renderHeight as integer ) catch ( rh = 0 )
    )

    resetMaxFile #noPrompt

    local kept = #()
    if keep do
    (
        if unitsType != undefined do
            ( try ( units.SystemType = unitsType; append kept "units" ) catch() )
        try ( units.SystemScale = unitsScale; append kept "scale" ) catch()
        if fps > 0 do ( try ( frameRate = fps; append kept "frameRate" ) catch() )
        if rw > 0 and rh > 0 do
            ( try ( renderWidth = rw; renderHeight = rh; append kept "resolution" ) catch() )
    )

    mcpRedraw()
    local p = #()
    -- `created` is a boolean here, while other tools use the same key as a list
    -- of names; the runtime reads that key as an enumeration, so say it plainly.
    mcpPair p "success" true
    mcpPair p "created" true
    mcpPair p "kept" kept
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
    -- Overwriting an existing scene destroys work with no undo; require the
    -- caller to say so explicitly instead of doing it on a typo.
    if (doesFileExist path) and not (mcpBool params "confirm" default:false) do
        mcpFail "err.confirm_required" a1:"scene_save_as"

    local oldDir = ""
    local oldName = ""
    try ( oldDir = maxFilePath ) catch ( oldDir = "" )
    try ( oldName = maxFileName ) catch ( oldName = "" )

    try ( makeDir (getFilenamePath path) all:true ) catch()
    saveMaxFile path quiet:true clearNeedSaveFlag:true

    -- keepPath=false means "write this copy but stay on the original scene".
    local keepPath = mcpBool params "keepPath" default:true
    if not keepPath do
    (
        try ( maxFilePath = oldDir ) catch()
        try ( maxFileName = oldName ) catch()
    )

    local p = #()
    mcpPair p "saved" path
    mcpPair p "pathKept" (if keepPath then false else true)
    mcpPair p "message" (mcpMsg "msg.saved" a1:path)
    mcpObj p
)

fn mcpH_scene_merge params =
(
    local path = mcpReqStr params "path"
    if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
    local names = mcpArr params "objects"
    local quiet = mcpBool params "quiet" default:true

    local beforeHandles = for o in objects collect (getHandleByAnim o)
    local ok = true
    local mode = "full"
    if names.count > 0 then
    (
        try ( mergeMAXFile path names #noPrompt quiet:quiet; mode = "selected" )
        catch ( mergeMAXFile path #noPrompt quiet:quiet; mode = "full (selective merge failed)" )
    )
    else mergeMAXFile path #noPrompt quiet:quiet

    local addedObjects = #()
    for o in objects do
    (
        if (findItem beforeHandles (getHandleByAnim o)) == 0 do append addedObjects o.name
    )

    mcpRedraw()
    local p = #()
    mcpPair p "merged" path
    mcpPair p "mode" mode
    mcpPair p "addedObjects" addedObjects
    mcpPair p "addedCount" addedObjects.count
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
    local failures = #()

    if (mcpGet params "hidden") != undefined do
    (
        local wantH = mcpBool params "hidden" default:false
        try
        (
            lay.isHidden = wantH
            if lay.isHidden == wantH then append applied "hidden"
            else append failures ("hidden: kept " + (lay.isHidden as string))
        )
        catch ( append failures ("hidden: " + (getCurrentException() as string)) )
    )
    if (mcpGet params "frozen") != undefined do
    (
        local wantF = mcpBool params "frozen" default:false
        try
        (
            lay.isFrozen = wantF
            if lay.isFrozen == wantF then append applied "frozen"
            else append failures ("frozen: kept " + (lay.isFrozen as string))
        )
        catch ( append failures ("frozen: " + (getCurrentException() as string)) )
    )
    if (mcpGet params "color") != undefined do
    (
        local wantC = mcpColorFrom (mcpGet params "color")
        try
        (
            lay.wireColor = wantC
            if lay.wireColor == wantC then append applied "color"
            else append failures ("color: kept " + (lay.wireColor as string))
        )
        catch ( append failures ("color: " + (getCurrentException() as string)) )
    )
    if (mcpGet params "renderable") != undefined do
    (
        local wantR = mcpBool params "renderable" default:true
        try
        (
            lay.renderable = wantR
            if lay.renderable == wantR then append applied "renderable"
            else append failures ("renderable: kept " + (lay.renderable as string))
        )
        catch ( append failures ("renderable: " + (getCurrentException() as string)) )
    )

    local p = #()
    mcpPair p "success" (failures.count == 0 and applied.count > 0)
    mcpPair p "layer" name
    mcpPair p "applied" applied
    mcpPair p "failures" failures
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
/* MAXScript exposes a per superclass class registry: <SuperClass>.classes.
   Only the *superclass class values* have it -- the lowercase listener
   shortcuts ("geometry", "lights", "materials", ...) are node collections and
   raise "unknown property: classes", which is why the previous bucket list
   enumerated almost nothing and a search for "Box" came back empty.
   Measured on 3ds Max 2022: GeometryClass 127, Shape 43, Light 25, Camera 9,
   Helper 181, System 8, SpacewarpObject 33, Material 53, TextureMap 337,
   Modifier 151, Filter 13, Atmospheric 9, ReferenceTarget 241.
   Controller / Renderer / Effect have no .classes on this release. */
fn mcpClassBuckets =
(
    #(
        "GeometryClass", "Shape", "Light", "Camera", "Helper", "System",
        "SpacewarpObject", "Material", "TextureMap", "Modifier", "Filter",
        "Atmospheric", "ReferenceTarget"
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

    -- mcpClassBuckets is a FUNCTION; iterating the symbol itself made Max
    -- try to "map" the function value ("no map function for mcpClassBuckets").
    for bucketName in (mcpClassBuckets()) do
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

/* ==========================================================================
   SECTION: mcp_selftest.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_selftest.ms
   In-Max diagnostics.  Because the bridge deliberately avoids Python, structs
   and closures, the only meaningful way to prove the environment is healthy is
   to exercise it from inside Max.

   Call it from the Listener      : mcpSelfTest()
   Or through MCP                : bridge_selftest
-----------------------------------------------------------------------------*/

global mcpSelfTest, mcpH_bridge_selftest, mcpSelfTestLines

mcpSelfTestLines = #()

fn mcpStPush name ok detail =
(
    append mcpSelfTestLines (mcpObj #(#("check", name), #("ok", ok), #("detail", (detail as string))))
    ok
)

fn mcpSelfTest echoText:"" =
(
    mcpSelfTestLines = #()
    local checks = #()
    local failures = 0

    local stamp = mcpStPush "handlerRegistry" (mcpRegistry.count > 0) (mcpRegistry.count as string)
    if not stamp do failures += 1

    -- 1. object marker discrimination
    local o = mcpObj #(#("a", 1))
    local arr = #("a", 1)
    local ok1 = (mcpIsObj o) and (not (mcpIsObj arr)) and (not (mcpIsObj #())) and (not (mcpIsObj 5))
    if not (mcpStPush "jsonObjectMarker" ok1 ((mcpIsObj o) as string)) do failures += 1

    -- 2. JSON round trip incl. nesting
    local src = "{\"a\":1,\"b\":[1,2,3],\"c\":{\"d\":\"e\"},\"f\":true,\"g\":null,\"h\":1.5}"
    local parsed = mcpJsonParse src
    local hasBool = (mcpBool parsed "f" default:false) == true
    local hasNull = (mcpGet parsed "g") == undefined
    local ok2 = (mcpInt parsed "a" == 1) and ((mcpArr parsed "b").count == 3) and (mcpStr (mcpGet parsed "c") "d" == "e") and hasBool and hasNull and ((mcpNum parsed "h") == 1.5)
    if not (mcpStPush "jsonParse" ok2 src) do failures += 1

    local ok3 = false
    local detail3 = ""
    try (
        local again = mcpJsonStringify parsed
        local reparse = mcpJsonParse again
        ok3 = (mcpInt reparse "a" == 1) and ((mcpArr reparse "b").count == 3)
        detail3 = again
    ) catch ( detail3 = getCurrentException() )
    if not (mcpStPush "jsonStringify" ok3 detail3) do failures += 1

    -- 3. empty object / empty array
    local ok4 = (mcpObjCount (mcpJsonParse "{}") == 0) and ((mcpJsonParse "[]").count == 0)
    if not (mcpStPush "jsonEmpty" ok4 "") do failures += 1

    -- 4. non ASCII round trip (the \u00XX byte escaping scheme)
    local zh = "模型材质测试"
    local ok5 = false
    local detail5 = ""
    try (
        local wire = mcpJsonStringify (mcpObj #(#("n", zh)))
        local back = mcpStr (mcpJsonParse wire) "n"
        ok5 = (back == zh)
        detail5 = "wire=" + wire + " back=" + back
    ) catch ( detail5 = getCurrentException() )
    if not (mcpStPush "unicodeRoundTrip" ok5 detail5) do failures += 1

    -- 5. echo of the caller supplied text (end to end codepage check)
    local ok6 = true
    local detail6 = echoText
    if echoText != "" then
    (
        local wire = mcpJsonStringify (mcpObj #(#("n", echoText)))
        local back = mcpStr (mcpJsonParse wire) "n"
        ok6 = (back == echoText)
        detail6 = "sent=" + echoText + " back=" + back
    )
    if not (mcpStPush "echoText" ok6 detail6) do failures += 1

    -- 6. number formatting must stay valid JSON
    local ok7 = false
    local detail7 = ""
    try (
        detail7 = (mcpJsonNumber 10) + "," + (mcpJsonNumber 1.5) + "," + (mcpJsonNumber 0.000001) + "," + (mcpJsonNumber 100000000000000000000.0)
        local lower = toLower detail7
        ok7 = ((findString lower "e") == undefined)
    ) catch ( detail7 = getCurrentException() )
    if not (mcpStPush "numberFormat" ok7 detail7) do failures += 1

    -- 7. object creation / inspection / deletion
    local ok8 = false
    local detail8 = ""
    local probe = undefined
    try (
        probe = Box length:12 width:8 height:5 name:"__mcp_selftest_box"
        local info = mcpNodeInfo probe
        ok8 = (mcpStr info "name" == "__mcp_selftest_box") and (mcpInt info "handle" != 0)
        detail8 = mcpStr info "class" + " / " + (mcpStr info "superClass")
    ) catch ( detail8 = getCurrentException() )
    if not (mcpStPush "sceneCreate" ok8 detail8) do failures += 1
    if probe != undefined do ( try ( delete probe ) catch() )

    -- 8. node resolution helper
    local ok9 = false
    local detail9 = ""
    local probe2 = undefined
    try (
        probe2 = Sphere radius:3 name:"__mcp_selftest_sphere"
        local n1 = mcpResolveNode "__mcp_selftest_sphere"
        local n2 = mcpResolveNode "$__mcp_selftest_sphere"
        ok9 = (n1 == probe2) and (n2 == probe2)
        detail9 = "resolved=" + ((n1 != undefined) as string)
    ) catch ( detail9 = getCurrentException() )
    if not (mcpStPush "nodeResolve" ok9 detail9) do failures += 1
    if probe2 != undefined do ( try ( delete probe2 ) catch() )

    -- 9. the hold stack (what every mutating command relies on)
    local ok10 = false
    local detail10 = ""
    local probe3 = undefined
    try (
        mcpHoldBegin()
        probe3 = Cylinder radius:2 height:6 name:"__mcp_selftest_cyl"
        mcpHoldAccept "mcp self test"
        ok10 = (probe3 != undefined)
        detail10 = "accepted"
    ) catch ( detail10 = getCurrentException() )
    if not (mcpStPush "holdStack" ok10 detail10) do failures += 1
    if probe3 != undefined do ( try ( delete probe3 ) catch() )

    -- 10. socket layer
    local ok11 = false
    local detail11 = ""
    try (
        local ip = (dotNetClass "System.Net.IPAddress").Parse "127.0.0.1"
        local lst = dotNetObject "System.Net.Sockets.TcpListener" ip 8799
        lst.Start()
        ok11 = (lst.Pending() == false)
        lst.Stop()
        detail11 = "bind ok"
    ) catch ( detail11 = getCurrentException() )
    if not (mcpStPush "tcpListener" ok11 detail11) do failures += 1

    -- 11. pump timer
    local ok12 = (mcpTimer != undefined)
    if not (mcpStPush "pumpTimer" ok12 ((mcpTimer != undefined) as string)) do failures += 1

    -- 12. version probe
    local ok13 = (mcpMaxYear() >= 2020)
    if not (mcpStPush "version" ok13 ((mcpMaxYear()) as string)) do failures += 1

    local p = #()
    mcpPair p "ok" (failures == 0)
    mcpPair p "failures" failures
    mcpPair p "checks" mcpSelfTestLines
    mcpPair p "maxYear" (mcpMaxYear())
    mcpPair p "language" mcpLang
    mcpPair p "port" mcpPort
    mcpObj p
)

fn mcpH_bridge_selftest params =
(
    local echo = mcpStr params "echoText"
    mcpSelfTest echoText:echo
)

fn mcpRegisterSelftest =
(
    mcpRegister "bridge_selftest" mcpH_bridge_selftest undoable:false
    ok
)

mcpRegisterSelftest()
