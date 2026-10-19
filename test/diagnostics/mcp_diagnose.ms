/*-----------------------------------------------------------------------------
   mcp_diagnose.ms  --  standalone diagnostics for the 3ds Max MCP bridge.

   Run it once from the MAXScript Listener:

       fileIn @"D:\Workspace\Dev\3dsmax-mcp\test\mcp_diagnose.ms"

   Deliberately self contained: it does not assume any bridge function exists,
   so it can report *why* the bridge failed instead of failing with it.

   Every stage is appended to a log file and echoed to the Listener as a line
   starting with "MCPDIAG|".  No Chinese text is used anywhere in this file, so
   the ANSI/UTF-8 question cannot corrupt it.

   Log location (first writable wins):
       <temp>\3dsmax-mcp\diag.log
       <userScripts>\3dsmax-mcp\diag.log
       D:\Workspace\Dev\3dsmax-mcp\test\diag.log

   Reading the outcome
       no diag.log at all    -> the script was never executed
       RESULT: LISTENING     -> bridge is up
       RESULT: NOT_LISTENING -> modules loaded, the socket never bound
       RESULT: INIT_FAILED   -> a module (or the entry point) raised

   NOTE ON MAXScript SYNTAX: a member can NOT be read off the result of a
   method call ("a.B().C" is a syntax error), so every dotNet object is bound
   to a local first and members are read from that local.
-----------------------------------------------------------------------------*/

global MCPDIAG_LOG, MCPDIAG_BRIDGE, MCPDIAG_PORT, MCPDIAG_STARTUP

-- Declared here on purpose: it makes every bridge symbol a known global for this
-- file, so the probe still compiles when the bridge has never been loaded.
global mcpRunning, mcpListener, mcpHost, mcpPort, mcpTimer, mcpRegistry, mcpLang
global mcpBridgeLoad, mcpBridgeStart, mcpSelfTest, mcpJsonStringify
global mcpNetStart, mcpNetStop, mcpNetStatus, mcpRunLoop, mcpNetPump

MCPDIAG_LOG = undefined
MCPDIAG_PORT = 8765
MCPDIAG_BRIDGE = @"C:\Users\Vino\AppData\Local\Autodesk\3dsMax\2020 - 64bit\CHS\scripts\3dsmax-mcp\mcp_bridge.ms"
MCPDIAG_STARTUP = @"C:\Users\Vino\AppData\Local\Autodesk\3dsMax\2020 - 64bit\CHS\scripts\startup\3dsmax-mcp-bridge.ms"


/*-------------------------------------------------------------- small helpers*/

fn mcpDiagStamp =
(
    local s = ""
    local cls = undefined
    local t = undefined
    try
    (
        cls = dotNetClass "System.DateTime"
        t = cls.Now
        s = t.ToString()
    )
    catch ( s = (timestamp() as string) )
    s
)

fn mcpDiagS v =
(
    local s = "<undefined>"
    if v != undefined do s = (v as string)
    s
)

fn mcpDiagResolveLog =
(
    local cands = #()
    local cls = undefined
    local f = ""
    local d = ""
    local ok = false

    if MCPDIAG_LOG == undefined then
    (
        try ( append cands ((getDir #temp) + "\\3dsmax-mcp") ) catch()
        try ( append cands ((getDir #userScripts) + "\\3dsmax-mcp") ) catch()
        try ( append cands @"D:\Workspace\Dev\3dsmax-mcp\test" ) catch()

        try ( cls = dotNetClass "System.IO.File" ) catch ( cls = undefined )

        if cls != undefined then
        (
            for d in cands do
            (
                if MCPDIAG_LOG == undefined then
                (
                    f = d + "\\diag.log"
                    ok = false
                    try ( makeDir d all:true ) catch()
                    try ( cls.AppendAllText f "" ) catch()
                    try ( ok = cls.Exists f ) catch ( ok = false )
                    if ok do MCPDIAG_LOG = f
                )
            )
        )
    )
    MCPDIAG_LOG
)

fn mcpDiag msg =
(
    local text = "<undefined>"
    local p = undefined
    local cls = undefined
    local line = ""

    if msg != undefined do text = (msg as string)
    format "MCPDIAG| %\n" text

    p = mcpDiagResolveLog()
    if p != undefined then
    (
        try
        (
            cls = dotNetClass "System.IO.File"
            line = (mcpDiagStamp()) + "  " + text + "\r\n"
            cls.AppendAllText p line
        )
        catch()
    )
    ok
)


/*------------------------------------------------------------------- the probe*/

(
    local began = 0
    local ok = true
    local val = undefined
    local err = ""
    local cls = undefined
    local proc = undefined
    local ver = undefined
    local enc = undefined
    local ip = undefined
    local ip2 = undefined
    local lst = undefined
    local lst2 = undefined
    local pend = false
    local running = false
    local loadedEntry = false
    local nowRunning = false
    local hint = ""
    local bridgeLog = ""
    local loaderLog = ""
    local res = undefined

    began = timestamp()

    mcpDiag "============================================================"
    mcpDiag "S01  script start"
    mcpDiag ("     log file     = " + (mcpDiagS (mcpDiagResolveLog())))
    mcpDiag ("     time         = " + (mcpDiagS (mcpDiagStamp())))

    ok = true; val = undefined; err = ""
    try ( val = getSourceFileName() ) catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     source       = " + (mcpDiagS val)) else mcpDiag ("     source        RAISED " + err)

    mcpDiag ("     max version  = " + (mcpDiagS (maxVersion())))

    ok = true; val = undefined; err = ""
    try ( val = getLanguage() ) catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     ui language  = " + (mcpDiagS val)) else mcpDiag ("     ui language   RAISED " + err)

    ok = true; val = undefined; err = ""
    try ( val = getSystemLanguage() ) catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     sys language = " + (mcpDiagS val)) else mcpDiag ("     sys language  RAISED " + err)

    ok = true; val = undefined; err = ""
    try ( val = getDir #temp ) catch ( ok = false )
    if ok then mcpDiag ("     #temp        = " + (mcpDiagS val)) else mcpDiag "     #temp         = ?"

    ok = true; val = undefined; err = ""
    try ( val = getDir #userScripts ) catch ( ok = false )
    if ok then mcpDiag ("     #userScripts = " + (mcpDiagS val)) else mcpDiag "     #userScripts  = ?"


    mcpDiag "S02  dotNet runtime"
    ok = true; val = undefined; err = ""
    try
    (
        cls = dotNetClass "System.Environment"
        ver = cls.Version
        val = ver.ToString()
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     clr version  = " + (mcpDiagS val)) else mcpDiag ("     clr version   RAISED " + err)

    ok = true; val = undefined; err = ""
    try
    (
        cls = dotNetClass "System.Text.Encoding"
        enc = cls.Default
        val = enc.WebName
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     ansi codepage= " + (mcpDiagS val)) else mcpDiag ("     ansi codepage RAISED " + err)

    ok = true; val = undefined; err = ""
    try
    (
        dotNet.loadAssembly "System.Windows.Forms"
        cls = dotNetClass "System.Windows.Forms.Application"
        val = cls.ProductVersion
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     winforms     = " + (mcpDiagS val)) else mcpDiag ("     winforms      RAISED " + err)

    ok = true; val = undefined; err = ""
    try
    (
        cls = dotNetClass "System.Diagnostics.Process"
        proc = cls.GetCurrentProcess()
        val = proc.Id
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     max pid      = " + (mcpDiagS val)) else mcpDiag ("     max pid       RAISED " + err)


    mcpDiag "S03  bridge files"
    mcpDiag ("     entry point  = " + MCPDIAG_BRIDGE)
    mcpDiag ("     entry exists = " + (mcpDiagS (doesFileExist MCPDIAG_BRIDGE)))
    mcpDiag ("     json exists  = " + (mcpDiagS (doesFileExist ((getFilenamePath MCPDIAG_BRIDGE) + "mcp_json.ms"))))
    mcpDiag ("     loader       = " + MCPDIAG_STARTUP)
    mcpDiag ("     loader exists= " + (mcpDiagS (doesFileExist MCPDIAG_STARTUP)))

    ok = true; val = undefined; err = ""
    try ( val = getINISetting ((getFilenamePath MCPDIAG_BRIDGE) + "3dsmax-mcp.ini") "bridge" "port" )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     ini port     = " + (mcpDiagS val)) else mcpDiag ("     ini port      RAISED " + err)

    ok = true; val = undefined; err = ""
    try ( val = getINISetting ((getFilenamePath MCPDIAG_BRIDGE) + "3dsmax-mcp.ini") "bridge" "autostart" )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     ini autostart= " + (mcpDiagS val)) else mcpDiag ("     ini autostart RAISED " + err)


    mcpDiag "S04  raw socket preflight (independent of the bridge)"
    ok = true; val = ""; err = ""
    try
    (
        cls = dotNetClass "System.Net.IPAddress"
        ip = cls.Parse "127.0.0.1"
        lst = dotNetObject "System.Net.Sockets.TcpListener" ip 8765
        lst.Start()
        pend = lst.Pending()
        lst.Stop()
        val = "bind ok, pending=" + (mcpDiagS pend)
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     bind 8765    = " + val) else mcpDiag ("     bind 8765     RAISED " + err)

    ok = true; val = ""; err = ""
    try
    (
        cls = dotNetClass "System.Net.IPAddress"
        ip2 = cls.Parse "127.0.0.1"
        lst2 = dotNetObject "System.Net.Sockets.TcpListener" ip2 8766
        lst2.Start()
        lst2.Stop()
        val = "bind ok"
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     bind 8766    = " + val) else mcpDiag ("     bind 8766     RAISED " + err)


    mcpDiag "S05  current bridge state"
    try ( running = (mcpRunning == true) ) catch ( running = false )
    try ( loadedEntry = (mcpBridgeLoad != undefined) ) catch ( loadedEntry = false )
    mcpDiag ("     mcpRunning   = " + (mcpDiagS running))
    mcpDiag ("     entry loaded = " + (mcpDiagS loadedEntry))
    mcpDiag ("     fn mcpBridgeLoad  = " + (mcpDiagS (mcpBridgeLoad != undefined)))
    mcpDiag ("     fn mcpBridgeStart = " + (mcpDiagS (mcpBridgeStart != undefined)))
    mcpDiag ("     fn mcpNetStart    = " + (mcpDiagS (mcpNetStart != undefined)))
    mcpDiag ("     fn mcpNetStatus   = " + (mcpDiagS (mcpNetStatus != undefined)))


    mcpDiag "S06  execute the bridge entry point"
    if loadedEntry then
        mcpDiag "     skipped, mcp_bridge.ms already ran in this session"
    else if not (doesFileExist MCPDIAG_BRIDGE) then
        mcpDiag "     ABORT, entry point missing on disk"
    else
    (
        ok = true; err = ""
        try ( fileIn MCPDIAG_BRIDGE )
        catch ( ok = false; err = (getCurrentException() as string) )
        if ok then mcpDiag "     fileIn returned without raising"
        else mcpDiag ("     fileIn RAISED " + err)
        try ( loadedEntry = (mcpBridgeLoad != undefined) ) catch ( loadedEntry = false )
    )


    mcpDiag "S07  module load report"
    if not loadedEntry then
        mcpDiag "     mcpBridgeLoad is undefined: the entry point never ran"
    else
    (
        ok = true; val = false; err = ""
        try ( val = mcpBridgeLoad() ) catch ( ok = false; err = (getCurrentException() as string) )
        if not ok then
            mcpDiag ("     mcpBridgeLoad RAISED " + err)
        else if (val == false) then
            mcpDiag "     result = false (bridge directory not found)"
        else
        (
            mcpDiag ("     root         = " + (mcpDiagS (val[1])))
            mcpDiag ("     loaded       = " + (mcpDiagS (val[2].count)) + " module(s)")
            mcpDiag ("     failed       = " + (mcpDiagS (val[3].count)) + " module(s)")
            for f in val[3] do mcpDiag ("       FAILED: " + (mcpDiagS f))
            if (val.count >= 4) do
            (
                for e in val[4] do mcpDiag ("       ERROR: " + (mcpDiagS (e[1])) + " -> " + (mcpDiagS (e[2])))
            )
        )
    )


    mcpDiag "S08  start the listener"
    try ( running = (mcpRunning == true) ) catch ( running = false )
    if running then
        mcpDiag "     skipped, already listening"
    else
    (
        ok = true; val = undefined; err = ""
        if mcpBridgeStart == undefined then
        (
            mcpDiag "     mcpBridgeStart missing, falling back to mcpNetStart"
            if mcpNetStart == undefined then
                mcpDiag "     mcpNetStart missing as well, nothing to call"
            else
            (
                try ( val = mcpNetStart port:MCPDIAG_PORT )
                catch ( ok = false; err = (getCurrentException() as string) )
                if ok then mcpDiag ("     mcpNetStart returned " + (mcpDiagS val))
                else mcpDiag ("     mcpNetStart RAISED " + err)
            )
        )
        else
        (
            try ( val = mcpBridgeStart port:MCPDIAG_PORT )
            catch ( ok = false; err = (getCurrentException() as string) )
            if not ok then
                mcpDiag ("     mcpBridgeStart RAISED " + err)
            else if (val == false) then
                mcpDiag "     mcpBridgeStart returned false"
            else
                mcpDiag "     mcpBridgeStart returned an object"
        )
    )


    mcpDiag "S09  post state"
    try ( nowRunning = (mcpRunning == true) ) catch ( nowRunning = false )
    mcpDiag ("     mcpRunning   = " + (mcpDiagS nowRunning))

    ok = true; val = undefined
    try ( val = mcpHost ) catch ( ok = false )
    if ok then mcpDiag ("     mcpHost      = " + (mcpDiagS val)) else mcpDiag "     mcpHost      = ?"

    ok = true; val = undefined
    try ( val = mcpPort ) catch ( ok = false )
    if ok then mcpDiag ("     mcpPort      = " + (mcpDiagS val)) else mcpDiag "     mcpPort      = ?"

    ok = true; val = undefined
    try ( val = (mcpTimer != undefined) ) catch ( ok = false )
    if ok then mcpDiag ("     pump timer   = " + (mcpDiagS val)) else mcpDiag "     pump timer   = ?"

    ok = true; val = undefined
    try ( val = mcpRegistry.count ) catch ( ok = false )
    if ok then mcpDiag ("     handlers     = " + (mcpDiagS val)) else mcpDiag "     handlers     = ?"

    ok = true; val = undefined; err = ""
    try ( val = mcpListener.Pending() ) catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("     pending()    = " + (mcpDiagS val)) else mcpDiag ("     pending()     RAISED " + err)

    hint = (getDir #temp) + "\\3dsmax-mcp\\bridge.json"
    mcpDiag ("     bridge.json  = " + hint + " exists=" + (mcpDiagS (doesFileExist hint)))

    ok = true; val = undefined; err = ""
    try
    (
        cls = dotNetClass "System.IO.File"
        val = cls.ReadAllText hint
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if ok then mcpDiag ("       content    = " + (mcpDiagS val)) else mcpDiag ("       unreadable = " + err)

    bridgeLog = (getDir #temp) + "\\3dsmax-mcp\\bridge.log"
    mcpDiag ("     bridge.log   = " + bridgeLog + " exists=" + (mcpDiagS (doesFileExist bridgeLog)))

    loaderLog = (getDir #temp) + "\\3dsmax-mcp\\loader.log"
    mcpDiag ("     loader.log   = " + loaderLog + " exists=" + (mcpDiagS (doesFileExist loaderLog)))


    mcpDiag "S10  in-Max selftest"
    if nowRunning then
    (
        ok = true; val = undefined; err = ""
        try ( val = mcpSelfTest() ) catch ( ok = false; err = (getCurrentException() as string) )
        if ok then
        (
            try ( mcpDiag ("     selftest     = " + (mcpJsonStringify val)) )
            catch ( mcpDiag "     selftest     = <stringify raised>" )
        )
        else mcpDiag ("     selftest      RAISED " + err)
    )
    else mcpDiag "     skipped, bridge not listening"


    mcpDiag "S11  result"
    if nowRunning then
        mcpDiag "RESULT: LISTENING"
    else if not loadedEntry then
        mcpDiag "RESULT: INIT_FAILED (entry point never executed)"
    else
        mcpDiag "RESULT: NOT_LISTENING"

    mcpDiag ("     total " + (mcpDiagS (timestamp() - began)) + " ms")
    mcpDiag "============================================================"
    mcpDiag ("log file: " + (mcpDiagS (mcpDiagResolveLog())))
)
