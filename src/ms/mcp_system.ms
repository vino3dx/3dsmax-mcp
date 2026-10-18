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

fn mcpH_bridge_stop params =
(
    mcpNetStop()
    local p = #()
    mcpPair p "running" false
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

    local raw = undefined
    local failure = undefined
    try ( raw = python.Execute code )
    catch ( failure = getCurrentException() )
    if failure != undefined do throw failure

    local p = #()
    mcpPair p "available" true
    mcpPair p "pythonVersion" (pyVersion as string)
    mcpPair p "result" (mcpResultToJson raw)
    mcpPair p "resultText" (try ( raw as string ) catch ( "" ))
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

    if displayType == "metric" then ( try ( units.DisplayType = #Metric ) catch() )
    else if displayType == "us" then ( try ( units.DisplayType = #US ) catch() )
    else if displayType == "generic" then ( try ( units.DisplayType = #Generic ) catch() )

    mcpH_get_units params
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
