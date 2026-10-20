/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_bridge.ms   [ENTRY POINT]

   Run this file from the 3ds Max MAXScript Listener to start the bridge:

       fileIn @"C:\path\to\3dsmax-mcp\max\mcp_bridge.ms"

   Or copy the whole `max` folder into
       <Documents>\3ds Max 20XX\scripts\3dsmax-mcp\
   and place a one line loader in
       <Documents>\3ds Max 20XX\scripts\Startup\
   so the bridge starts together with Max (scripts/install.py does this for you).

   Compatibility: 3ds Max 2020 -> current.  Pure MAXScript, no Python and no
   native plugin, therefore identical behaviour on every release.
-----------------------------------------------------------------------------*/

global MCP_BRIDGE_DIR, MCP_BRIDGE_PORT, MCP_BRIDGE_LOADED, MCP_BRIDGE_AUTOSTART
global mcpBridgeModules, mcpBridgeRoot, mcpBridgeLoad, mcpBridgeStart, mcpBridgeStop
global mcpBridgeReadPort, mcpBridgeBanner, mcpBridgeLog, mcpBridgeLogPath, mcpBridgeLogDir

-- MAXScript only resolves a global in a file that declares it, so every symbol
-- this file reads from the modules is listed here.  Without this the boot
-- block saw "mcpNetStart == undefined" and reported INIT_FAILED even when
-- mcp_net.ms had loaded perfectly.
global mcpNetStart, mcpNetStop, mcpNetStatus, mcpNetPump, mcpRunLoop
global mcpRunning, mcpListener, mcpHost, mcpPort, mcpTimer, mcpConns
global mcpRegistry, mcpLang, mcpMaxYear, mcpMaxMajor, mcpMaxLanguageCode
global mcpIsLanguagePinned, mcpSetLanguage, mcpSetLanguageAuto

MCP_BRIDGE_PORT = 8765
MCP_BRIDGE_AUTOSTART = true
MCP_BRIDGE_LOADED = false
mcpBridgeRoot = undefined
MCP_BRIDGE_DIR = undefined
mcpBridgeLogDir = undefined


/*------------------------------------------------------------------------- log
   Every startup decision lands in a file, because the MAXScript Listener is
   not observable once Max is running unattended.  dotNet is a hard requirement
   of this bridge anyway (TcpListener), so it is a fair dependency for logging;
   each write is a separate AppendAllText, which flushes and closes.
-----------------------------------------------------------------------------*/
fn mcpBridgeLogPath =
(
    if mcpBridgeLogDir != undefined do return (mcpBridgeLogDir + "\\bridge.log")

    local cands = #()
    local probe = ""
    local ok = false

    try ( append cands ((getDir #temp) + "\\3dsmax-mcp") ) catch()
    try ( append cands ((getDir #userScripts) + "\\3dsmax-mcp") ) catch()

    for d in cands while mcpBridgeLogDir == undefined do
    (
        probe = d + "\\.write_test"
        ok = false
        try ( makeDir d all:true ) catch()
        try
        (
            (dotNetClass "System.IO.File").WriteAllText probe "ok"
            ok = (dotNetClass "System.IO.File").Exists probe
        )
        catch ( ok = false )
        if ok do
        (
            try ( (dotNetClass "System.IO.File").Delete probe ) catch()
            mcpBridgeLogDir = d
        )
    )
    if mcpBridgeLogDir == undefined then undefined else (mcpBridgeLogDir + "\\bridge.log")
)

fn mcpBridgeLog msg =
(
    local text = if msg == undefined then "undefined" else (msg as string)
    local p = undefined
    local stamp = ""

    format "3ds Max MCP: %\n" text

    -- Logging must never be the thing that breaks startup.
    try ( p = mcpBridgeLogPath() ) catch ( p = undefined )
    if p == undefined do return false

    try ( stamp = (dotNetClass "System.DateTime").Now.ToString "yyyy-MM-dd HH:mm:ss.fff" )
    catch ( stamp = (timestamp() as string) )
    try ( (dotNetClass "System.IO.File").AppendAllText p (stamp + "  " + text + "\r\n") )
    catch ( return false )
    true
)

mcpBridgeModules = #(
    "mcp_json.ms",
    "mcp_core.ms",
    "mcp_net.ms",
    "mcp_system.ms",
    "mcp_scene.ms",
    "mcp_objects.ms",
    "mcp_poly.ms",
    "mcp_modifiers.ms",
    "mcp_modeling_ext.ms",
    "mcp_shading.ms",
    "mcp_lights.ms",
    "mcp_animation.ms",
    "mcp_rigging.ms",
    "mcp_render.ms",
    "mcp_vision.ms",
    "mcp_bake.ms",
    "mcp_export.ms",
    "mcp_selftest.ms"
)


/*------------------------------------------------------------ locate the files*/
fn mcpBridgeRoot =
(
    if MCP_BRIDGE_DIR != undefined and doesFileExist (MCP_BRIDGE_DIR + "mcp_json.ms") do
        return MCP_BRIDGE_DIR

    local candidates = #()
    if MCP_BRIDGE_DIR != undefined do append candidates MCP_BRIDGE_DIR

    local self = ""
    try ( self = getSourceFileName() ) catch ( self = "" )
    if self != "" and self != undefined do append candidates (getFilenamePath self)

    try ( append candidates ((getDir #userScripts) + "\\3dsmax-mcp\\") ) catch()
    try ( append candidates ((getDir #scripts) + "\\3dsmax-mcp\\") ) catch()
    try ( append candidates ((getDir #maxRoot) + "\\scripts\\3dsmax-mcp\\") ) catch()

    for c in candidates do
    (
        if c != undefined and c != "" and doesFileExist (c + "mcp_json.ms") do
        (
            MCP_BRIDGE_DIR = c
            return c
        )
    )
    undefined
)

fn mcpBridgeLoad =
(
    -- getSourceFileName() is not guaranteed to be callable here (it can raise
    -- when the caller has no source file), and an unprotected call would abort
    -- the whole load, so it only ever *adds* a candidate directory.
    local dir = ""
    local root = undefined
    local loaded = #()
    local failed = #()
    local errors = #()
    local path = ""
    local ok = true
    local err = ""

    try ( dir = getFilenamePath (getSourceFileName()) ) catch ( dir = "" )
    if dir != undefined and dir != "" do MCP_BRIDGE_DIR = dir

    root = mcpBridgeRoot()
    if root == undefined do
    (
        mcpBridgeLog "load: cannot locate the bridge files (mcp_json.ms)"
        return false
    )

    for f in mcpBridgeModules do
    (
        path = root + f
        if doesFileExist path then
        (
            ok = true
            err = ""
            try ( fileIn path )
            catch ( ok = false; err = (getCurrentException() as string) )
            if ok then append loaded f
            else
            (
                append failed f
                append errors #(f, err)
                mcpBridgeLog ("load: module failed: " + f + " -> " + err)
            )
        )
        else
        (
            append failed (f + " (missing)")
            append errors #(f, "<file missing>")
            mcpBridgeLog ("load: module missing: " + path)
        )
    )

    MCP_BRIDGE_LOADED = (failed.count == 0)
    #(root, loaded, failed, errors)
)


/*--------------------------------------------------------------- port and ini*/
fn mcpBridgeReadPort =
(
    local port = MCP_BRIDGE_PORT

    -- 1) environment variable, set before launching 3ds Max
    local env = ""
    try ( env = (dotNetClass "System.Environment").GetEnvironmentVariable "MAXMCP_PORT" ) catch ( env = "" )
    if env != undefined and env != "" do ( try ( port = env as integer ) catch() )

    -- 2) the ini written next to the bridge modules by scripts/install.py,
    --    then the historical plugcfg location
    local iniCandidates = #()
    if MCP_BRIDGE_DIR != undefined do append iniCandidates (MCP_BRIDGE_DIR + "3dsmax-mcp.ini")
    try ( append iniCandidates ((getDir #plugcfg) + "\\3dsmax-mcp.ini") ) catch()

    for iniFile in iniCandidates do
    (
        if iniFile != undefined and iniFile != "" and doesFileExist iniFile do
        (
            local v = ""
            try ( v = getINISetting iniFile "bridge" "port" ) catch ( v = "" )
            if v != undefined and v != "" do ( try ( port = v as integer ) catch() )

            local lang = ""
            try ( lang = getINISetting iniFile "bridge" "language" ) catch ( lang = "" )
            if lang != undefined and lang != "" then
            (
                -- "auto" asks the bridge to mirror this Max installation's UI
                -- language; anything else is an explicit pin by the user.
                local l = toLower (lang as string)
                if l != "auto" and l != "follow" and l != "default" do mcpSetLanguage l
            )

            local auto = ""
            try ( auto = getINISetting iniFile "bridge" "autostart" ) catch ( auto = "" )
            if auto != undefined and auto != "" do
                ( try ( if (auto as integer) == 0 do MCP_BRIDGE_AUTOSTART = false ) catch() )
        )
    )
    -- A non-numeric env/ini value coerces to undefined (not an exception),
    -- so fall back to the default instead of returning undefined.
    if port == undefined do port = MCP_BRIDGE_PORT
    port
)


/*----------------------------------------------------------------- start / stop*/
fn mcpBridgeStart port:0 =
(
    local r = undefined
    local iniPort = 0
    local p = 0
    local attempts = 0
    local started = undefined
    local lastError = ""
    local ok = true
    local res = undefined

    if not MCP_BRIDGE_LOADED do
    (
        r = mcpBridgeLoad()
        if r == false do return false
    )

    -- Calling start twice (startup loader + manual, or two fileIns) must not
    -- drop a live socket or stack a second pump timer on top of the first one.
    if mcpRunning == true and mcpListener != undefined do
    (
        mcpBridgeLog ("start: already listening on " + mcpHost + ":" + (mcpPort as string))
        mcpBridgeBanner()
        return (mcpNetStatus())
    )

    iniPort = mcpBridgeReadPort()
    p = if port == 0 or port == undefined then iniPort else port

    -- The .ini did not pin a language, so mirror this Max installation's UI
    -- language. Re-derived on every start, which keeps a restart predictable.
    if not (mcpIsLanguagePinned()) do mcpSetLanguageAuto()

    -- Fall back to the next free port when the preferred one is taken.
    while attempts < 10 and started == undefined do
    (
        ok = true
        res = undefined
        try ( res = mcpNetStart port:(p + attempts) )
        catch ( ok = false; lastError = (getCurrentException() as string) )
        if ok then started = res
        else
        (
            -- Swallowing this used to leave "the bridge did not start" with no
            -- reason at all; the bind error is the whole diagnosis.
            mcpBridgeLog ("start: port " + ((p + attempts) as string) + " failed: " + lastError)
            attempts += 1
        )
    )

    if started == undefined do
    (
        mcpBridgeLog ("start: could not bind any port in " + (p as string) + ".." + ((p + 9) as string))
        return false
    )

    MCP_BRIDGE_PORT = p + attempts
    mcpBridgeLog ("start: listening on " + mcpHost + ":" + (mcpPort as string))
    mcpBridgeBanner()
    started
)

fn mcpBridgeStop =
(
    mcpNetStop()
    format "3ds Max MCP: bridge stopped.\n"
    ok
)

fn mcpBridgeBanner =
(
    format "\n"
    format "========================================================\n"
    format "  3ds Max MCP bridge\n"
    format "  ----------------------------------------------------\n"
    format "  Status      : listening\n"
    format "  Address     : %:%\n" mcpHost mcpPort
    format "  3ds Max     : % (major %)\n" (mcpMaxYear()) (mcpMaxMajor())
    format "  Commands    : %\n" mcpRegistry.count
    format "  Language    : % (%)\n" mcpLang (if (mcpIsLanguagePinned()) then "pinned" else ("auto: " + mcpMaxLanguageCode()))
    format "  Pump timer  : %\n" (mcpTimer != undefined)
    format "  ----------------------------------------------------\n"
    format "  Stop with   : mcpBridgeStop()\n"
    format "  Diagnose    : mcpSelfTest()\n"
    format "========================================================\n\n"
    ok
)


/*------------------------------------------------------------------------ boot
   Every branch below reports through mcpBridgeLog so that a failed autostart
   can be reconstructed from disk afterwards.  Nothing is swallowed silently:
   the log always ends with the state the bridge is actually in.
-----------------------------------------------------------------------------*/
(
    local began = timestamp()
    local self = ""
    local srcDir = "<unknown>"
    local ver = "?"
    local logFile = "?"
    local result = false
    local loaded = #()
    local failed = #()
    local netReady = false
    local chosenPort = 0
    local r = undefined

    try ( self = getSourceFileName() ) catch ( self = "" )
    if self != undefined and self != "" do MCP_BRIDGE_DIR = getFilenamePath self
    if MCP_BRIDGE_DIR != undefined do srcDir = (MCP_BRIDGE_DIR as string)

    mcpBridgeLog ("boot: executing mcp_bridge.ms from " + srcDir)

    -- Both probes are best effort: a broken mcp_core.ms must not stop the
    -- module report below from being written.
    try ( ver = (mcpMaxYear() as string) ) catch ( ver = "?" )
    try ( logFile = (mcpBridgeLogPath() as string) ) catch ( logFile = "?" )
    mcpBridgeLog ("boot: max " + ver + ", log " + logFile)

    try ( result = mcpBridgeLoad() )
    catch (
        result = false
        mcpBridgeLog ("boot: load raised: " + (getCurrentException() as string))
    )

    if result == false then
        mcpBridgeLog "boot: state=MODULES_NOT_FOUND"
    else
    (
        loaded = result[2]
        failed = result[3]
        mcpBridgeLog ("boot: modules loaded " + (loaded.count as string) + ", failed " + (failed.count as string))
        for f in failed do mcpBridgeLog ("boot: failed module: " + (f as string))

        -- A partially loaded bridge is the dangerous case: it looks alive but
        -- the first request dies on an undefined symbol.  Refuse to pretend.
        try ( netReady = (mcpNetStart != undefined) ) catch ( netReady = false )
        if not netReady then
            mcpBridgeLog "boot: state=INIT_FAILED (mcpNetStart undefined, mcp_net.ms did not load)"
        else
        (
            chosenPort = MCP_BRIDGE_PORT
            try ( chosenPort = mcpBridgeReadPort() )
            catch ( mcpBridgeLog ("boot: readPort raised: " + (getCurrentException() as string)) )

            if MCP_BRIDGE_AUTOSTART then
            (
                r = undefined
                try ( r = mcpBridgeStart port:chosenPort )
                catch ( r = false; mcpBridgeLog ("boot: start raised: " + (getCurrentException() as string)) )
                if r == false then mcpBridgeLog "boot: state=NOT_LISTENING"
                else mcpBridgeLog ("boot: state=LISTENING port=" + (mcpPort as string) + " timer=" + ((mcpTimer != undefined) as string))
            )
            else mcpBridgeLog "boot: state=LOADED_ONLY (autostart=0 in 3dsmax-mcp.ini)"
        )
    )
    mcpBridgeLog ("boot: finished in " + ((timestamp() - began) as string) + " ms")
)
