﻿/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_core.ms
   Shared infrastructure: bilingual message table, handler registry, node
   resolution helpers, version probing and small utilities.

   The message table is the in-Max half of the language switch.  Every string
   the bridge hands back to the AI client goes through `mcpMsg`, so switching
   language in the MCP server changes the wording of Max side messages too.
-----------------------------------------------------------------------------*/

global mcpLang, mcpLangPinned
global mcpRegistry
global mcpVerbose

global mcpMsg, mcpFormat, mcpRegister, mcpFindHandler, mcpFindEntry, mcpSetLanguage, mcpGetLanguage
global mcpSetLanguageAuto, mcpIsLanguagePinned
global mcpEntryUndoable, mcpEntryLabel
global mcpFail, mcpTryCode, mcpHoldBegin, mcpHoldAccept, mcpHoldCancel
global mcpResolveNode, mcpResolveNodes, mcpRequireNode, mcpNodeInfo, mcpNodesInfo, mcpSelectionInfo
global mcpIsPoly, mcpIsMesh, mcpSuperclass, mcpRedraw
global mcpMaxMajor, mcpMaxYear, mcpVersionInfo, mcpClassExists, mcpEnsureClass
global mcpPoint3From, mcpColorFrom, mcpNameFrom
global mcpMessages, mcpCurrentRendererName

mcpLang = "zh"
mcpLangPinned = false
mcpVerbose = false
if mcpRegistry == undefined do mcpRegistry = #()


/*------------------------------------------------------------------- messages*/
-- Each entry is #(chinese, english); "%" is the positional placeholder.
global mcpMessages
mcpMessages = #(
    #("err.missing_param",        #("缺少必填参数：%",                          "Missing required parameter: %")),
    #("err.node_not_found",       #("找不到对象：%",                            "Object not found: %")),
    #("err.unknown_method",       #("未知命令：%",                              "Unknown command: %")),
    #("err.bad_value",            #("参数 % 的值不合法。",                       "Invalid value for parameter %.")),
    #("err.no_selection",         #("当前没有选中任何对象。",                    "Nothing is selected.")),
    #("err.class_missing",        #("当前 3ds Max 中不可用：%。请确认对应插件已安装并勾选启用。",
                                   "% is not available in this 3ds Max. Make sure the plugin is installed and enabled.")),
    #("err.render_engine",        #("无法切换到渲染器 %。",                       "Could not switch to renderer %.")),
    #("err.file_missing",         #("文件不存在：%",                             "File not found: %")),
    #("err.poly_required",        #("对象 % 必须是可编辑多边形（Editable Poly）。已尝试自动转换失败。",
                                   "Object % must be an Editable Poly; automatic conversion failed.")),
    #("err.not_found_in_list",    #("在 % 中找不到 %。",                          "% was not found in %.")),
    #("err.invalid_argument",     #("参数 % 无效：%",                            "Invalid argument %: %")),
    #("err.confirm_required",     #("危险操作：必须显式传入 confirm=true 才会执行 %。该操作不可撤销地修改场景。",
                                   "Dangerous operation: pass confirm=true explicitly to run %. It modifies the scene irreversibly.")),
    #("err.invalid_subobject_level", #("无效的子对象层级：%。应为 0-5 或 vert/edge/border/face/element。",
                                      "Invalid sub-object level: %. Expected 0-5 or vert/edge/border/face/element.")),
    #("err.element_api_missing",  #("当前 3ds Max 版本不支持元素（element）查询接口。",
                                   "This 3ds Max version does not support the element query interface.")),
    #("msg.ok",                   #("完成。",                                    "Done.")),
    #("msg.bridge_started",       #("MCP 桥接已启动，监听端口 %。",               "MCP bridge started, listening on port %.")),
    #("msg.bridge_stopped",       #("MCP 桥接已停止。",                          "MCP bridge stopped.")),
    #("msg.bridge_running",       #("MCP 桥接正在运行，端口 %。",                 "MCP bridge is running on port %.")),
    #("msg.undo_label",           #("MCP：%",                                    "MCP: %")),
    #("msg.created",              #("已创建 %。",                                "Created %.")),
    #("msg.hierarchy",            #("层级：%",                                   "Hierarchy: %")),
    #("msg.no_modifier",          #("对象 % 上没有该修改器：%。",                  "Object % has no modifier named %.")),
    #("msg.render_done",          #("渲染完成：%",                              "Render finished: %")),
    #("msg.bake_done",            #("烘焙完成：%",                              "Bake finished: %")),
    #("msg.export_done",          #("导出完成：%",                              "Export finished: %")),
    #("msg.import_done",          #("导入完成：%",                              "Import finished: %")),
    #("msg.saved",                #("已保存：%",                                "Saved: %")),
    #("msg.loaded",               #("已打开：%",                                "Opened: %")),
    #("msg.anim_baked",           #("动画已烘焙：%",                            "Animation baked: %")),
    #("msg.skin_added",           #("已添加蒙皮：%",                            "Skin added: %")),
    #("msg.feature_unsupported",  #("当前 3ds Max 版本（%）不支持该功能。",        "This feature is not supported on 3ds Max %."))
)

fn mcpFormat template args =
(
    local out = ""
    local rest = template
    local idx = 1
    local p = findString rest "%"
    while p != undefined do
    (
        out += substring rest 1 (p - 1)
        local v = if idx <= args.count then args[idx] else undefined
        if v != undefined and v != unsupplied do
        (
            -- Never let one unprintable argument break message building: a
            -- failed "as string" inside a failure path used to take the whole
            -- response down with it.
            local vs = ""
            try ( vs = (v as string) ) catch ( vs = "<" + ((classof v) as string) + ">" )
            out += vs
        )
        rest = substring rest (p + 1) (rest.count - p)
        idx += 1
        p = findString rest "%"
    )
    out + rest
)

fn mcpMsg key a1:unsupplied a2:unsupplied a3:unsupplied =
(
    local pair = undefined
    for e in mcpMessages do ( if e[1] == key do ( pair = e[2]; exit ) )
    if pair == undefined then return key
    local template = if mcpLang == "en" then pair[2] else pair[1]
    mcpFormat template #(a1, a2, a3)
)

fn mcpSetLanguage lang =
(
    local l = toLower (lang as string)
    if l == "en" or l == "english" then ( mcpLang = "en"; mcpLangPinned = true )
    else if l == "zh" or l == "cn" or l == "chinese" then ( mcpLang = "zh"; mcpLangPinned = true )
    else if l == "auto" or l == "follow" or l == "default" then ( mcpSetLanguageAuto() )
    mcpLang
)

fn mcpGetLanguage = ( mcpLang )

-- True when someone pinned the language on purpose (via the .ini or a
-- set_language call). While it is false the bridge mirrors Max's UI language.
fn mcpIsLanguagePinned = ( mcpLangPinned )


/*-------------------------------------------------------------- auto language*/
-- 3ds Max ships one user configuration folder per UI language. The folder name
-- (ENU, CHS, CHT, JPN ...) is the most reliable signal available in MAXScript
-- and it works on every release from 2020 on, so we read it out of a path we
-- already know rather than trusting a single API.
--
-- getLanguage() exists too, but it only tells us "Chinese" - it cannot separate
-- Simplified from Traditional - so it is the fallback, not the primary source.

global mcpMaxLanguageCode, mcpDetectLanguage, mcpLanguageLabel

fn mcpMaxLanguageCode =
(
    local code = ""
    local known = #("ENU", "CHS", "CHT", "JPN", "KOR", "DEU", "FRA", "ESP", "ITA", "PTB", "RUS", "PLK", "CSY")
    local probes = #()

    try ( append probes (getMAXIniFile()) ) catch ( ok = false )
    try ( append probes (getDir #userScripts) ) catch ( ok = false )
    try ( append probes (getDir #userMacros) ) catch ( ok = false )
    try ( append probes (getDir #userIcons) ) catch ( ok = false )

    for pr in probes while code == "" do
    (
        if pr != undefined and (pr as string) != "" do
        (
            local up = toUpper (pr as string)
            for k in known while code == "" do
            (
                if (findString up ("\\" + k + "\\")) != undefined do code = k
            )
        )
    )

    if code == "" do
    (
        try
        (
            local nm = toUpper ((getLanguage()) as string)
            if (findString nm "CHIN") != undefined then code = "CHS"
            else if (findString nm "ENGL") != undefined then code = "ENU"
            else if nm != "" then code = nm
        )
        catch ( ok = false )
    )
    code
)

fn mcpLanguageLabel code =
(
    local c = toUpper (code as string)
    if c == "CHS" or c == "CHT" then "Chinese"
    else if c == "" then "English"
    else (code as string)
)

-- Resolve to the language the bridge actually serves: "zh" or "en".
-- Traditional Chinese readers get Simplified, which is far closer than English.
fn mcpDetectLanguage =
(
    local code = mcpMaxLanguageCode()
    if code == "CHS" or code == "CHT" then "zh"
    else if code == "ENU" or code == "ENA" or code == "ENG" then "en"
    else if code == "" then "en"
    else
    (
        -- Unknown code (Japanese, German, ...): no strings for it, serve English.
        local up = toUpper (code as string)
        if (findString up "CHIN") != undefined then "zh" else "en"
    )
)

-- Follow this Max installation's language. Used when the .ini says "auto" or
-- says nothing at all, which is the default the installer writes.
fn mcpSetLanguageAuto =
(
    mcpLangPinned = false
    mcpLang = mcpDetectLanguage()
    mcpLang
)


/*------------------------------------------------------------------- registry*/
-- Each entry is #(method, handler, undoable, label).
fn mcpRegister method handler undoable:true label:"" =
(
    local e = mcpFindEntry method
    if e == undefined then
    (
        append mcpRegistry #(method, handler, undoable, label)
    )
    else
    (
        -- Replace in place instead of refusing.  A module can be reloaded with
        -- fileIn during development; if the old handler stayed in the registry
        -- the reload would silently change nothing and the caller would keep
        -- hitting the stale function.
        e[2] = handler
        e[3] = undoable
        e[4] = label
        try ( mcpBridgeLog ("registry: replaced handler " + method) ) catch()
    )
    ok
)

fn mcpFindEntry method =
(
    for e in mcpRegistry do ( if e[1] == method then return e )
    undefined
)

fn mcpFindHandler method =
(
    local e = mcpFindEntry method
    if e == undefined then undefined else e[2]
)

fn mcpEntryUndoable method =
(
    local e = mcpFindEntry method
    if e == undefined then false else e[3]
)

fn mcpEntryLabel method =
(
    local e = mcpFindEntry method
    if e == undefined or e[4] == "" then method else e[4]
)

fn mcpFail key a1:unsupplied a2:unsupplied =
(
    throw (mcpMsg key a1:a1 a2:a2)
)

-- Evaluates a MAXScript code string; returns #(succeeded, valueOrError).
fn mcpTryCode code =
(
    local r = #(true, undefined)
    try ( r = #(true, execute code) )
    catch ( r = #(false, getCurrentException()) )
    r
)


/*------------------------------------------------------------------ undo/hold*/
fn mcpHoldBegin =
(
    local ok = true
    try ( theHold.Begin() ) catch ( ok = false )
    ok
)

fn mcpHoldAccept label =
(
    local ok = true
    try ( theHold.Accept label ) catch ( ok = false )
    ok
)

fn mcpHoldCancel =
(
    local ok = true
    try ( theHold.Cancel() ) catch ( ok = false )
    ok
)

fn mcpRedraw =
(
    try ( redrawViews() ) catch()
    try ( completeRedraw() ) catch()
    ok
)


/*-------------------------------------------------------------------- version*/
fn mcpMaxMajor =
(
    local v = 0
    try ( v = ((maxVersion())[1]) / 1000 ) catch ( v = 0 )
    v as integer
)

fn mcpMaxYear = ( mcpMaxMajor() + 1998 )

fn mcpVersionInfo =
(
    local pairs = #()
    mcpPair pairs "year" (mcpMaxYear())
    mcpPair pairs "major" (mcpMaxMajor())
    mcpPair pairs "product" (try ( maxVersion() as string ) catch ( "" ))
    mcpPair pairs "build" (try ( ((maxVersion())[2]) as integer ) catch ( 0 ))
    mcpPair pairs "language" (try ( (getLanguage() as string) ) catch ( "" ))
    mcpPair pairs "languageCode" (mcpMaxLanguageCode())
    mcpPair pairs "systemLanguage" (try ( (getSystemLanguage() as string) ) catch ( "" ))
    mcpPair pairs "units" (try ( (units.SystemType as string) ) catch ( "" ))
    mcpPair pairs "metricScale" (try ( (units.SystemScale as float) ) catch ( 1.0 ))
    mcpPair pairs "renderEngine" (mcpCurrentRendererName())
    mcpObj pairs
)

global mcpCurrentRendererName
fn mcpCurrentRendererName =
(
    local out = ""
    try ( out = (classof renderers.production) as string ) catch ( out = "" )
    out
)

fn mcpClassExists clsName =
(
    local ok = false
    try ( local c = execute clsName; ok = (c != undefined) ) catch ( ok = false )
    ok
)

fn mcpEnsureClass clsName =
(
    if not (mcpClassExists clsName) do mcpFail "err.class_missing" a1:clsName
    true
)


/*------------------------------------------------------------- node resolving*/
fn mcpResolveNode spec =
(
    if spec == undefined then return undefined

    if isKindOf spec Number then
    (
        local n = undefined
        try ( n = getNodeByHandle (spec as integer) ) catch ( n = undefined )
        return n
    )

    if mcpIsObj spec then
    (
        local s = mcpStr spec "name"
        if s == "" then return undefined
        return (mcpResolveNode s)
    )

    if isKindOf spec String then
    (
        local t = spec
        if t == "" then return undefined
        if t == "sel" or t == "selection" or t == "selected" then
            return ( if selection.count > 0 then selection[1] else undefined )
        if (substring t 1 1) == "$" and t.count > 1 then t = substring t 2 (t.count - 1)

        local n = undefined
        try ( n = getNodeByName t ) catch ( n = undefined )
        if n != undefined then return n

        local h = 0
        try ( h = t as integer ) catch ( h = 0 )
        if h > 0 do
        (
            try ( n = getNodeByHandle h ) catch ( n = undefined )
            if n != undefined then return n
        )
        return undefined
    )
    undefined
)

fn mcpRequireNode spec =
(
    local n = mcpResolveNode spec
    if n == undefined do mcpFail "err.node_not_found" a1:(spec as string)
    n
)

-- Resolve a list of names; falls back to the current selection when asked to.
fn mcpResolveNodes values fallbackToSelection:false silent:false =
(
    local out = #()
    if values == undefined or (isKindOf values Array and values.count == 0) then
    (
        if fallbackToSelection then
        (
            for i = 1 to selection.count do append out selection[i]
            if out.count == 0 and not silent do mcpFail "err.no_selection"
        )
        return out
    )
    if isKindOf values String then values = #(values)
    if not (isKindOf values Array) then values = #(values)

    local missing = #()
    for v in values do
    (
        local n = mcpResolveNode v
        if n == undefined then append missing v
        else append out n
    )
    if missing.count > 0 and not silent do
        mcpFail "err.node_not_found" a1:(mcpStringJoin (for m in missing collect (m as string)) ", ")
    out
)


/*--------------------------------------------------------------- node to JSON*/
fn mcpSuperclass n =
(
    local s = ""
    try ( s = (superclassof n) as string ) catch ( s = "" )
    s
)

fn mcpIsPoly n =
(
    local r = false
    try ( r = (classof n.baseObject == Editable_Poly) ) catch ( r = false )
    r
)

fn mcpIsMesh n =
(
    local r = false
    try ( r = (classof n.baseObject == Editable_Mesh) ) catch ( r = false )
    r
)

fn mcpNodeInfo n =
(
    if n == undefined then return undefined
    local pairs = #()

    mcpPair pairs "name" (try ( n.name ) catch ( "" ))
    mcpPair pairs "handle" (try ( (getHandleByAnim n) as integer ) catch ( 0 ))
    mcpPair pairs "class" (try ( (classof n) as string ) catch ( "" ))
    mcpPair pairs "baseClass" (try ( (classof n.baseObject) as string ) catch ( "" ))
    mcpPair pairs "superClass" (mcpSuperclass n)
    mcpPair pairs "position" (try ( n.position ) catch ( [0,0,0] ))
    mcpPair pairs "rotation" (try ( (n.rotation as eulerAngles) ) catch ( (eulerAngles 0 0 0) ))
    mcpPair pairs "scale" (try ( n.scale ) catch ( [1,1,1] ))
    mcpPair pairs "isHidden" (try ( n.isHidden ) catch ( false ))
    mcpPair pairs "isFrozen" (try ( n.isFrozen ) catch ( false ))
    mcpPair pairs "parent" (try ( if n.parent != undefined then n.parent.name else "" ) catch ( "" ))
    mcpPair pairs "childCount" (try ( n.children.count ) catch ( 0 ))
    mcpPair pairs "material" (try ( if n.material != undefined then n.material.name else "" ) catch ( "" ))
    mcpPair pairs "layer" (try ( n.layer.name ) catch ( "" ))
    mcpPair pairs "wirecolor" (try ( n.wirecolor ) catch ( (color 0 0 0) ))
    mcpPair pairs "renderable" (try ( n.renderable ) catch ( false ))
    mcpPair pairs "vertexCount" (try ( (getPolygonCount n)[2] ) catch ( 0 ))
    mcpPair pairs "faceCount" (try ( (getPolygonCount n)[1] ) catch ( 0 ))

    local mods = #()
    try ( for m in n.modifiers do append mods ((classof m) as string) ) catch()
    mcpPair pairs "modifiers" mods

    mcpObj pairs
)

fn mcpNodesInfo nodes =
(
    local out = #()
    for n in nodes do append out (mcpNodeInfo n)
    mcpObj #(#("count", nodes.count), #("objects", out))
)

fn mcpSelectionInfo =
(
    local nodes = #()
    for i = 1 to selection.count do append nodes selection[i]
    mcpNodesInfo nodes
)


/*------------------------------------------------------------------ converters*/
fn mcpPoint3From value default:[0,0,0] =
(
    if value == undefined then return default
    if isKindOf value Point3 then return value
    if isKindOf value Array then
    (
        if value.count >= 3 then return (point3 (value[1] as float) (value[2] as float) (value[3] as float))
        if value.count == 2 then return (point3 (value[1] as float) (value[2] as float) 0.0)
        if value.count == 1 then return (point3 (value[1] as float) 0.0 0.0)
        return default
    )
    if mcpIsObj value then
    (
        if (mcpHas value "x") then return (point3 (mcpNum value "x") (mcpNum value "y") (mcpNum value "z"))
    )
    if isKindOf value String then
    (
        local parts = mcpStringSplit value ","
        local nums = #()
        for p in parts do
        (
            local f = 0.0
            try ( f = (trimLeft (trimRight p)) as float ) catch ( f = 0.0 )
            append nums f
        )
        return (mcpPoint3From nums default:default)
    )
    default
)

fn mcpColorFrom value default:(color 128 128 128) =
(
    if value == undefined then return default
    if isKindOf value Color then return value
    if isKindOf value Array then
    (
        if value.count >= 3 then return (color (value[1] as integer) (value[2] as integer) (value[3] as integer))
        return default
    )
    if isKindOf value String then
    (
        local h = value
        if (substring h 1 1) == "#" then h = substring h 2 (h.count - 1)
        if h.count == 6 then
        (
            local r = mcpHexToInt (substring h 1 2)
            local g = mcpHexToInt (substring h 3 2)
            local b = mcpHexToInt (substring h 5 2)
            return (color r g b)
        )
        return default
    )
    default
)

fn mcpNameFrom value =
(
    if value == undefined then return undefined
    if isKindOf value String then
    (
        if value == "" then return undefined
        return (value as name)
    )
    if mcpIsObj value then return (mcpNameFrom (mcpStr value "name"))
    try ( return (value as name) ) catch ( return undefined )
)
