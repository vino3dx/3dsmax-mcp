/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_net.ms
   TCP transport, request framing, dispatch and the main-thread pump.

   Why the pump exists
   -------------------
   MAXScript and the 3ds Max scene graph must only ever be touched from the main
   (UI) thread.  Instead of running a socket server on a background thread and
   hoping the scene API is thread safe, this bridge accepts sockets on the same
   thread as Max and drains them from a WinForms timer.  Every command therefore
   executes exactly like a user typing MAXScript into the Listener.

   Wire protocol
   -------------
   Newline delimited JSON, ASCII only (see mcp_json.ms for the encoding rules).

       -> {"id":1,"method":"create_box","params":{...},"lang":"zh"}\n
       <- {"id":1,"ok":true,"result":{...}}\n
-----------------------------------------------------------------------------*/

global mcpListener, mcpConns, mcpTimer, mcpPort, mcpRunning, mcpHost
global mcpNetStart, mcpNetStop, mcpNetPump, mcpOnTick, mcpNetStatus
global mcpProcessBuffer, mcpHandleLine, mcpHandleLineInner, mcpDispatch, mcpOkJson, mcpErrJson
global mcpRunLoop, mcpWritePortHint, mcpWriteStream, mcpBridgeLog, mcpIdJson

-- A connection is a plain 3 element array: #(tcpClient, networkStream, buffer)
mcpConns = #()
mcpHost = "127.0.0.1"
mcpPort = 8765
mcpRunning = false


/*-------------------------------------------------------------- response JSON*/
/* Echoing the request id back verbatim matters: clients match responses to
   requests with it.  Coercing straight to integer turned every string id into
   0 (the old behaviour), so the response could not be correlated at all. */
fn mcpIdJson id =
(
    local t = "0"
    if id == undefined do return t
    try
    (
        if (classof id) == String then
        (
            local esc = ""
            try ( esc = mcpJsonEscape id ) catch ( esc = id )
            t = "\"" + esc + "\""
        )
        else
        (
            t = ((id as integer) as string)
        )
    )
    catch ( t = "0" )
    t
)

/* Both builders are total functions: whatever they are handed, they return one
   line of JSON.  A failure inside the *error* path used to raise again and take
   the connection down, which hid the original problem completely. */
fn mcpOkJson id result =
(
    local idTxt = "0"
    local body = "null"
    local why = ""
    try ( idTxt = mcpIdJson id ) catch ( idTxt = "0" )
    try ( body = mcpJsonStringify result )
    catch
    (
        local etxt = ""
        try ( etxt = (getCurrentException() as string) ) catch ( etxt = "unprintable" )
        local ctxt = ""
        try ( ctxt = (classof result) as string ) catch ( ctxt = "?" )
        why = "<unserializable " + ctxt + ">"
        body = "\"<unserializable>\""
        try ( mcpBridgeLog ("net: result not serializable (" + ctxt + ") -> " + etxt) ) catch()
    )
    "{\"id\":" + idTxt + ",\"ok\":true,\"result\":" + body + "}\n"
)

fn mcpErrJson id kind message =
(
    local idTxt = "0"
    local kindTxt = "error"
    local msgTxt = "\"error\""
    local msg = ""
    try ( idTxt = mcpIdJson id ) catch ( idTxt = "0" )
    try ( kindTxt = (kind as string) ) catch ( kindTxt = "error" )
    msg = ""
    try ( msg = (message as string) ) catch ( msg = "unprintable error value" )
    try ( msgTxt = mcpJsonStringify msg ) catch ( msgTxt = "\"error\"" )
    "{\"id\":" + idTxt + ",\"ok\":false,\"error\":{\"kind\":\"" + kindTxt + "\",\"message\":" + msgTxt + "}}\n"
)


/*------------------------------------------------------------------- dispatch*/
fn mcpDispatch method params =
(
    local entry = mcpFindEntry method
    if entry == undefined do throw (mcpMsg "err.unknown_method" a1:method)
    local handler = entry[2]

    -- per request override of the registered undo behaviour
    local wantUndo = entry[3]
    if (mcpGet params "undo") != undefined do wantUndo = mcpBool params "undo" default:wantUndo
    if not wantUndo do return (handler params)

    local label = mcpEntryLabel method
    local customLabel = mcpStr params "undo_label"
    if customLabel != "" do label = customLabel

    local began = mcpHoldBegin()
    local result = undefined
    local failure = undefined
    try ( result = handler params )
    catch ( failure = getCurrentException() )

    if began do
    (
        if failure == undefined then mcpHoldAccept label
        else mcpHoldCancel()
    )
    if failure != undefined do throw failure
    result
)

fn mcpHandleLineInner line =
(
    local id = 0
    local req = undefined

    try ( req = mcpJsonParse line )
    catch ( return (mcpErrJson id "parse_error" (getCurrentException())) )

    if not (mcpIsObj req) do
        return (mcpErrJson id "parse_error" "request must be a JSON object")

    local idVal = mcpGet req "id"
    if idVal != undefined do ( id = idVal )

    local method = mcpStr req "method"
    local params = mcpGet req "params"
    if params == undefined do params = mcpObj #()
    if not (mcpIsObj params) do params = mcpObj #()

    local lang = mcpStr req "lang"
    if lang != "" do mcpSetLanguage lang

    local result = undefined
    local failure = undefined
    try ( result = mcpDispatch method params )
    catch ( failure = getCurrentException() )

    if failure != undefined do
    (
        local ftxt = "?"
        try ( ftxt = (failure as string) ) catch ( ftxt = "<non string exception: " + ((classof failure) as string) + ">" )
        try ( mcpBridgeLog ("net: dispatch failed for " + method + " -> " + ftxt) ) catch()
        return (mcpErrJson id "runtime_error" ftxt)
    )

    -- Serialising a result must never be able to drop the connection: a single
    -- unserialisable field would otherwise look like "the bridge died".
    local response = "null"
    try ( response = mcpOkJson id result )
    catch ( response = mcpErrJson id "serialize_error" (getCurrentException()) )
    response
)


/* A request handler must always produce a line of JSON.  Whenever a request
   killed the connection instead of answering it, the cause was an exception
   raised outside every inner try -- the client saw a reset and the reason was
   invisible.  This wrapper turns that class of failure into an error response
   and writes the reason to the log. */
fn mcpHandleLine line =
(
    local out = ""
    local err = ""
    local rcls = ""

    try ( out = mcpHandleLineInner line )
    catch
    (
        err = "unprintable"
        try ( err = (getCurrentException() as string) ) catch ( err = "unprintable" )
        try ( mcpBridgeLog ("net: handle raised -> " + err) ) catch()
        out = mcpErrJson 0 "runtime_error" err
    )

    rcls = "?"
    try ( rcls = (classof out) as string ) catch ( rcls = "?" )
    if rcls != "String" do
    (
        try ( mcpBridgeLog ("net: handle returned " + rcls + " instead of a string") ) catch()
        out = mcpErrJson 0 "runtime_error" "handler returned a non string response"
    )
    out
)


/*-------------------------------------------------------------------- framing*/
/* Writes one response.
   The obvious implementation -- ASCII.GetBytes then stream.Write bytes 0
   bytes.Length -- is fatal here: a .NET byte[] arrives in MAXScript as a plain
   array, so ".Length" raises "unknown property", the write never happens, the
   pump's catch drops the connection and the client only sees a reset.  A
   StreamWriter writes a string straight to the stream and sidesteps the array
   conversion entirely. */
fn mcpWriteStream stream text =
(
    local ok = true
    local err = ""
    local sw = undefined
    try
    (
        sw = dotNetObject "System.IO.StreamWriter" stream
        sw.Write text
        sw.Flush()
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if not ok do
    (
        try ( mcpBridgeLog ("net: response write failed -> " + err) ) catch()
    )
    ok
)

-- Drains every complete line out of the connection buffer and answers it.
fn mcpProcessBuffer cn =
(
    local buf = cn[3]
    local idx = findString buf "\n"
    local rounds = 0

    while idx != undefined and rounds < 256 do
    (
        rounds += 1
        local line = substring buf 1 (idx - 1)
        buf = substring buf (idx + 1) (buf.count - idx)

        if line.count > 0 and (substring line line.count 1) == "\r" do
            line = substring line 1 (line.count - 1)

        if line.count > 0 do
        (
            local response = mcpHandleLine line
            if response != undefined do mcpWriteStream cn[2] response
        )
        idx = findString buf "\n"
    )
    cn[3] = buf
    ok
)


/*------------------------------------------------------------------------ pump*/
fn mcpNetPump =
(
    if mcpListener == undefined then return 0

    -- A vision capture calls completeRedraw(), which pumps the Windows message
    -- queue and can re-enter this timer while the current request is still being
    -- handled.  Bailing out here stops one tick from consuming half a frame.
    local busy = false
    try ( busy = (mcpVisionBusy == true) ) catch ( busy = false )
    if busy then return 0

    local served = 0

    -- 1) accept pending connections (bounded so Max stays responsive)
    local guard = 0
    local accepting = true
    while accepting and guard < 16 do
    (
        guard += 1
        local pending = false
        try ( pending = mcpListener.Pending() ) catch ( pending = false )
        if pending then
        (
            local client = mcpListener.AcceptTcpClient()
            try ( client.NoDelay = true ) catch()
            local st = client.GetStream()
            -- MAXScript cannot marshal anything into a byte[] parameter: both
            -- "System.Byte[]" and Array.CreateInstance arrive at NetworkStream
            -- as null ("value cannot be null, parameter name: buffer").  Text
            -- level I/O is the only reliable path in this language.
            try ( st.ReadTimeout = 2000 ) catch()
            /* No StreamReader here on purpose.  A StreamReader pulls ahead: it
               reads the whole available byte run into its own buffer, so a
               client that sends two requests in one segment leaves DataAvailable
               at 0 for the second one and the request is never dispatched --
               with bufferSize:1 it still reads everything (measured: position
               12/12 after one ReadLine of "aaa\nbbb\nccc\n").  Reading single
               bytes only while DataAvailable is true cannot block and cannot
               over-read, and mcpProcessBuffer already does the line framing. */
            append mcpConns #(client, st, "", undefined)
            try ( mcpBridgeLog ("net: accepted client, open=" + (mcpConns.count as string)) ) catch()
        )
        else accepting = false
    )

    -- 2) service every open connection
    local dead = #()
    local selRead = (dotNetClass "System.Net.Sockets.SelectMode").SelectRead
    for k = 1 to mcpConns.count do
    (
        local cn = mcpConns[k]
        local drop = false
        try
        (
            -- Drain every byte that is already waiting, then let the line
            -- framing in mcpProcessBuffer answer every complete request.  One
            -- ReadByte per available byte never blocks and never over-reads.
            local more = true
            local bytes = 0
            while more and cn[2].DataAvailable and (bytes < 262144) do
            (
                bytes += 1
                local b = -1
                try ( b = cn[2].ReadByte() ) catch ( b = -1 )
                if b < 0 then
                (
                    more = false
                )
                else
                (
                    cn[3] = cn[3] + (bit.intAsChar b)
                )
            )

            -- Guard against a client that never sends a newline.
            if (cn[3].count > 1048576) do
            (
                drop = true
                try ( mcpBridgeLog "net: request buffer over 1 MB without a newline, dropping" ) catch()
            )

            if not drop do
            (
                mcpProcessBuffer cn
                if bytes > 0 do ( served += 1 )
            )

            -- A peer that closed shows up as "readable, zero bytes".  Without
            -- this probe a dropped client stayed in mcpConns for the lifetime
            -- of the Max session.
            if not drop do
            (
                local sk = cn[1].Client
                local readable = false
                try ( readable = sk.Poll 0 selRead ) catch ( readable = false )
                local avail = -1
                try ( avail = sk.Available ) catch ( avail = -1 )
                if readable and (avail == 0) do
                (
                    drop = true
                    try ( mcpBridgeLog "net: peer closed, dropping connection" ) catch()
                )
            )
        )
        catch
        (
            drop = true
            -- Without this the only visible symptom of a failing handler is a
            -- client that gets its connection reset with no explanation.
            try ( mcpBridgeLog ("net: connection error -> " + (getCurrentException() as string)) ) catch()
        )
        if drop do append dead k
    )

    -- 3) prune broken connections
    if dead.count > 0 do
    (
        local rebuilt = #()
        for j = 1 to mcpConns.count do
        (
            local isDead = false
            for k in dead do ( if k == j do isDead = true )
            if isDead then ( try ( mcpConns[j][1].Close() ) catch() )
            else append rebuilt mcpConns[j]
        )
        mcpConns = rebuilt
    )

    served
)

fn mcpOnTick sender args =
(
    try ( mcpNetPump() ) catch()
)

-- Headless / batch helper: pump for N seconds instead of relying on the UI timer.
fn mcpRunLoop seconds:60 =
(
    local deadline = (timeStamp()) + (seconds * 1000)
    while (timeStamp()) < deadline do
    (
        mcpNetPump()
        sleep 10
    )
    ok
)


/*--------------------------------------------------------------- start / stop*/
fn mcpWritePortHint port =
(
    local dir = (getDir #temp) + "\\3dsmax-mcp"
    local wrote = false
    local f = undefined
    local pid = 0
    local stamp = ""
    local body = ""
    local proc = undefined

    try ( makeDir dir all:true ) catch()
    f = createFile (dir + "\\bridge.json")
    if f == undefined then
    (
        -- A missing marker is not fatal (the MCP server scans the port range),
        -- but it must not pass silently either.
        try ( mcpBridgeLog ("hint: cannot write " + dir + "\\bridge.json") ) catch()
        return ok
    )
    -- MAXScript cannot read a member off the result of a method call
    -- ("a.B().C" is a syntax error), so the process object is bound first.
    try
    (
        proc = (dotNetClass "System.Diagnostics.Process").GetCurrentProcess()
        pid = proc.Id
    )
    catch ( pid = 0 )
    try ( stamp = (dotNetClass "System.DateTime").Now.ToString "yyyy-MM-dd HH:mm:ss" ) catch ( stamp = "" )
    body = "{\"port\":" + (port as string)
    body += ",\"maxYear\":" + (mcpMaxYear() as string)
    body += ",\"language\":\"" + mcpLang + "\""
    body += ",\"pid\":" + (pid as string)
    body += ",\"timer\":" + ((mcpTimer != undefined) as string)
    body += ",\"stamp\":\"" + stamp + "\"}"
    format "%" body to:f
    close f
    wrote = doesFileExist (dir + "\\bridge.json")
    try ( mcpBridgeLog ("hint: " + (dir + "\\bridge.json") + " written=" + (wrote as string)) ) catch()
    ok
)

fn mcpNetStart port:8765 host:"127.0.0.1" =
(
    mcpNetStop()

    local ip = (dotNetClass "System.Net.IPAddress").Parse host
    local lst = dotNetObject "System.Net.Sockets.TcpListener" ip port

    -- Bind failures used to be swallowed by the caller's retry loop, which left
    -- "the bridge never started" with no reason.  Surface the socket error.
    local bindError = ""
    local ok = true
    try ( lst.Start() )
    catch ( ok = false; bindError = (getCurrentException() as string) )
    if not ok do
    (
        try ( lst.Stop() ) catch()
        throw ("cannot listen on " + host + ":" + (port as string) + " : " + bindError)
    )

    mcpListener = lst
    mcpHost = host
    mcpPort = port
    mcpRunning = true
    mcpConns = #()

    local timerOk = false
    try
    (
        dotNet.loadAssembly "System.Windows.Forms"
        local t = dotNetObject "System.Windows.Forms.Timer"
        t.Interval = 25
        dotNet.addEventHandler t "Tick" mcpOnTick
        t.Start()
        mcpTimer = t
        timerOk = true
    )
    catch ( mcpTimer = undefined; timerOk = false )

    if not timerOk do
    (
        try ( mcpBridgeLog "net: pump timer could not be created (System.Windows.Forms.Timer)" ) catch()
    )

    mcpWritePortHint port

    local p = #()
    mcpPair p "ok" true
    mcpPair p "port" port
    mcpPair p "host" host
    mcpPair p "timer" timerOk
    mcpPair p "message" (mcpMsg "msg.bridge_started" a1:port)
    mcpObj p
)

fn mcpNetStop =
(
    if mcpTimer != undefined do
    (
        try ( mcpTimer.Stop() ) catch()
        mcpTimer = undefined
    )
    for cn in mcpConns do ( try ( cn[1].Close() ) catch() )
    mcpConns = #()
    if mcpListener != undefined do
    (
        try ( mcpListener.Stop() ) catch()
        mcpListener = undefined
    )
    mcpRunning = false
    mcpMsg "msg.bridge_stopped"
)

fn mcpNetStatus =
(
    local pairs = #()
    mcpPair pairs "running" mcpRunning
    mcpPair pairs "host" mcpHost
    mcpPair pairs "port" mcpPort
    mcpPair pairs "clients" mcpConns.count
    mcpPair pairs "timerActive" (mcpTimer != undefined)
    mcpPair pairs "language" mcpLang
    mcpPair pairs "handlerCount" mcpRegistry.count
    mcpPair pairs "maxYear" (mcpMaxYear())
    mcpObj pairs
)
