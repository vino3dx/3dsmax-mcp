/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_events.ms
   Event layer for the built in client: what changed, and since when.

   Why this file exists
   --------------------
   Everything the bridge exposes is a request/response command: Python asks,
   Max answers.  That is enough to *read* the scene, but not enough to know
   whether the answer is still true.  This module keeps a cheap change ledger
   inside Max, so a client can ask "give me what changed since revision 41"
   instead of re-reading the whole scene on every call.

   What is measured, not assumed (3ds Max 2022, verified on the live bridge)
   -----------------------------------------------------------------------
   * callbacks.addScript <name> "<code>" works and fires SYNCHRONOUSLY, which
     is why the handlers here only set flags.  A handler that walked the scene
     would run inside every selection the user makes.
   * the id: argument must be a Name.  An integer raises
     "Callback script ID must be a name", so every registration below uses a
     #name id and can therefore be removed again on reload.
   * only 20 of the 55 compact notifications exist on this release
     (#selectionSetChanged, #nodeRenamed, #filePreSave, ... yes;
      #nodeAdded, #preSave, #preOpen, #preNew, #preMerge, #systemStartup,
      #layerChanged ... no).  The set differs between releases, so it is
     probed at startup and reported instead of being hardcoded as available.
   * NodeEventCallback takes a handler with EXACTLY TWO arguments
     (eventName:Name, nodes:Array).  MAXScript is strict about arity and the
     "argument count" error only reaches the Listener, never the bridge -- a
     wrong arity therefore looks exactly like "the event never fires".
     On this release it delivers added/deleted, but NOT selectionChanged,
     nameChanged or geometryChanged for scripted edits, so those keep using
     the general notifications above.

   What is deliberately NOT here
   -----------------------------
   No timer, no socket, no polling loop of its own.  The bridge already owns a
   25 ms WinForms pump; mcpCtxTick (mcp_context.ms) rides on it.  A second
   timer would compete with that pump and re-open the re-entrancy class of bug
   that mcpPumpBusy exists to prevent.
-----------------------------------------------------------------------------*/

global mcpEvRevision, mcpEvSeq, mcpEvLog, mcpEvLogCap, mcpEvClock
global mcpEvRunning, mcpEvNodeCb, mcpEvIds, mcpEvCaps, mcpEvStartTime
global mcpEventsStart, mcpEventsStop, mcpEventsStatus, mcpEventsLog, mcpEventsCaps
global mcpEvFire, mcpEvNodeAdded, mcpEvNodeDeleted, mcpEvAfterWrite
global mcpEvDomainsFor, mcpEvClockUpdate, mcpEvReset, mcpEvDirty
global mcpEvRendering, mcpEvRenderStart, mcpEvLastRender
-- Owned by mcp_context.ms; declared here so the guard below is a real global
-- read on every release instead of an implicit one.
global mcpCtxMarkDirty

-- Revision 0 means "nothing has happened yet".  It is preserved across a
-- module reload so a client that cached revision 41 does not suddenly see the
-- counter go backwards and re-read everything.
if mcpEvRevision == undefined do mcpEvRevision = 0
if mcpEvSeq == undefined do mcpEvSeq = 0
if mcpEvLog == undefined do mcpEvLog = #()
if mcpEvLogCap == undefined do mcpEvLogCap = 250
if mcpEvRunning == undefined do mcpEvRunning = false
if mcpEvIds == undefined do mcpEvIds = #()
if mcpEvCaps == undefined do mcpEvCaps = #()
if mcpEvStartTime == undefined do mcpEvStartTime = (timeStamp())
if mcpEvClock == undefined do mcpEvClock = ""
-- Render state: #preRender / #postRender are the only two render facts this
-- release reports, so they bracket a job instead of describing its progress.
if mcpEvRendering == undefined do mcpEvRendering = false
if mcpEvRenderStart == undefined do mcpEvRenderStart = 0
if mcpEvLastRender == undefined do mcpEvLastRender = 0


/*------------------------------------------------------------------ plumbing*/
-- One shared clock string, refreshed at most every 250 ms by the context tick.
-- Formatting a DateTime per event would run inside every user selection.
fn mcpEvClockUpdate =
(
    local st = ""
    try ( st = (dotNetClass "System.DateTime").Now.ToString "HH:mm:ss" ) catch ( st = "" )
    if st != "" do mcpEvClock = st
    mcpEvClock
)

fn mcpEvDomainsFor kind =
(
    local k = toLower (kind as string)
    case k of
    (
        "selectionsetchanged": #("selection")
        "selectionchanged":    #("selection")
        "noderenamed":         #("scene", "objects", "selection")
        "nodeadded":           #("scene", "objects")
        "nodedeleted":         #("scene", "objects", "selection", "assets")
        "added":               #("scene", "objects")
        "deleted":             #("scene", "objects", "selection", "assets")
        "layercreated":        #("scene", "objects")
        "layerdeleted":        #("scene", "objects")
        "layerchanged":        #("scene", "objects")
        "unitschange":         #("scene")
        "filepresave":         #("scene")
        "filepostsave":        #("scene")
        "filepreopen":         #("scene")
        "filepostopen":        #("scene", "objects", "selection", "materials", "assets", "animation", "rigging", "render", "project")
        "preimport":           #("scene", "objects", "assets")
        "postimport":          #("scene", "objects", "selection", "materials", "assets")
        "preexport":           #()
        "postexport":          #()
        "prerender":           #("render")
        "postrender":          #("render")
        "prerenderframe":      #("render")
        "postrenderframe":     #("render")
        "sceneundo":           #("scene", "objects", "selection", "materials", "assets", "animation", "rigging")
        "sceneredo":           #("scene", "objects", "selection", "materials", "assets", "animation", "rigging")
        "modpanelobjpostchange": #("selection")
        default:               #("scene")
    )
)

/* Every change ends up here.  O(1): bump the counter, append one log row,
   tell the context cache which domains went stale.  Nothing scans the scene. */
fn mcpEvFire kind detail:"" =
(
    mcpEvRevision += 1
    mcpEvSeq += 1

    local lk = toLower (kind as string)
    if lk == "prerender" do ( mcpEvRendering = true; mcpEvRenderStart = (timeStamp()) )
    if lk == "postrender" do
    (
        mcpEvRendering = false
        mcpEvLastRender = (timeStamp()) - mcpEvRenderStart
    )

    local domains = mcpEvDomainsFor kind
    local row = #()
    mcpPair row "seq" mcpEvSeq
    mcpPair row "revision" mcpEvRevision
    mcpPair row "at" (if mcpEvClock == "" then (mcpEvClockUpdate()) else mcpEvClock)
    mcpPair row "event" (kind as string)
    mcpPair row "domains" domains
    if detail != "" do mcpPair row "detail" detail
    append mcpEvLog (mcpObj row)

    -- Ring buffer: the newest mcpEvLogCap rows only.  Rebuilding the array is
    -- cheaper than an O(n) delete in a hot callback for these sizes.
    if mcpEvLog.count > mcpEvLogCap do
    (
        local keep = #()
        local first = mcpEvLog.count - mcpEvLogCap + 1
        for i = first to mcpEvLog.count do append keep mcpEvLog[i]
        mcpEvLog = keep
    )

    -- mcp_context.ms owns the caches; it may not be loaded (or may have failed
    -- to load) and that must not break the callback.
    if mcpCtxMarkDirty != undefined do
    (
        -- Wrapped: an exception escaping a callback is invisible to the bridge
        -- and would silently disable every later event.
        try ( mcpCtxMarkDirty domains ) catch()
    )
    mcpEvRevision
)

/* NodeEventCallback handlers -- exactly two arguments, see the header note. */
fn mcpEvNodeAdded ev nodes =
(
    local n = 0
    try ( n = nodes.count ) catch ( n = 0 )
    mcpEvFire (ev as string) detail:((n as string) + " node(s)")
)

fn mcpEvNodeDeleted ev nodes =
(
    local n = 0
    try ( n = nodes.count ) catch ( n = 0 )
    mcpEvFire (ev as string) detail:((n as string) + " node(s)")
)

/* Which context domains a write can invalidate, derived from the tool name.
   The catalog names tools `<prefix>_<verb><noun>`, so the prefix carries the
   meaning.  The first draft fell back to "scene + objects + selection" for
   everything, which invalidated three domains on every write and made
   incremental sync useless for the domains that matter most.  `scene` stays
   unconditional: it holds objectCount/selectionCount/currentFrame/modified and
   costs 0-1 ms to rebuild.
   `execute_maxscript` and any unknown prefix keep the broad, conservative set
   because an arbitrary script really can touch anything. */
fn mcpEvDomainsForMethod m =
(
    local n = toLower (m as string)
    local domains = #("scene")
    local p = n
    local cut = findString n "_"
    if cut != undefined and cut > 1 do p = substring n 1 (cut - 1)

    case p of
    (
        "select":     ( append domains "selection" )
        "deselect":   ( append domains "selection" )
        "obj":        ( append domains "objects"; append domains "selection" )
        "create":     ( append domains "objects"; append domains "selection" )
        "clone":      ( append domains "objects"; append domains "selection" )
        "array":      ( append domains "objects"; append domains "selection" )
        "delete":     ( append domains "objects"; append domains "selection"; append domains "assets" )
        "attach":     ( append domains "objects"; append domains "selection" )
        "detach":     ( append domains "objects"; append domains "selection" )
        "boolean":    ( append domains "objects"; append domains "selection" )
        "proboolean": ( append domains "objects"; append domains "selection" )
        "collapse":   ( append domains "objects"; append domains "selection" )
        "convert":    ( append domains "objects"; append domains "selection" )
        "mod":        ( append domains "objects"; append domains "selection" )
        "poly":       ( append domains "objects"; append domains "selection" )
        "model":      ( append domains "objects"; append domains "selection" )
        "spline":     ( append domains "objects"; append domains "selection" )
        "uvw":        ( append domains "objects" )
        "group":      ( append domains "objects"; append domains "selection" )
        "ungroup":    ( append domains "objects"; append domains "selection" )
        "open":       ( append domains "objects"; append domains "selection" )
        "close":      ( append domains "objects"; append domains "selection" )
        "parent":     ( append domains "objects"; append domains "selection" )
        "unparent":   ( append domains "objects"; append domains "selection" )
        "rename":     ( append domains "objects"; append domains "selection" )
        "layer":      ( append domains "objects" )
        "assign":     ( append domains "objects" )
        "move":       ( append domains "objects"; append domains "selection" )
        "transform":  ( append domains "objects"; append domains "selection" )
        "mirror":     ( append domains "objects"; append domains "selection" )
        "reset":      ( append domains "objects"; append domains "selection" )
        "snap":       ( append domains "objects"; append domains "selection" )
        "scatter":    ( append domains "objects"; append domains "selection" )
        "align":      ( append domains "selection" )
        "xform":      ( append domains "selection" )
        "hide":       ( append domains "objects"; append domains "selection" )
        "unhide":     ( append domains "objects"; append domains "selection" )
        "freeze":     ( append domains "objects"; append domains "selection" )
        "unfreeze":   ( append domains "objects"; append domains "selection" )
        "mat":        ( append domains "materials" )
        "map":        ( append domains "materials"; append domains "assets" )
        "tex":        ( append domains "materials"; append domains "assets" )
        "bake":       ( append domains "materials"; append domains "assets" )
        "relink":     ( append domains "assets"; append domains "materials" )
        "asset":      ( append domains "assets" )
        "env":        ( append domains "render"; append domains "materials" )
        "anim":       ( append domains "animation" )
        "key":        ( append domains "animation" )
        "ctrl":       ( append domains "animation" )
        "track":      ( append domains "animation" )
        "time":       ( append domains "animation" )
        "rig":        ( append domains "rigging"; append domains "objects" )
        "skin":       ( append domains "rigging" )
        "bone":       ( append domains "rigging"; append domains "objects" )
        "biped":      ( append domains "rigging"; append domains "objects" )
        "constraint": ( append domains "rigging"; append domains "objects" )
        "light":      ( append domains "render"; append domains "objects" )
        "cam":        ( append domains "render"; append domains "objects" )
        "render":     ( append domains "render"; append domains "project" )
        "import":     ( append domains "project"; append domains "assets"; append domains "objects"; append domains "materials" )
        "export":     ( append domains "project"; append domains "assets" )
        "file":       ( append domains "project"; append domains "assets" )
        "xref":       ( append domains "project"; append domains "assets" )
        "project":    ( append domains "project" )
        "unit":       ( append domains "scene" )
        "undo":       ( append domains "objects"; append domains "selection" )
        "redo":       ( append domains "objects"; append domains "selection" )
        -- Arbitrary code really can touch everything.
        "execute":    ( append domains "objects"; append domains "selection"; append domains "materials"
                        append domains "assets"; append domains "animation"; append domains "rigging"
                        append domains "render"; append domains "project" )
        -- Files, directories, viewport grabs: no context domain changes.
        "write":      ( )
        "make":       ( )
        "copy":       ( )
        "viewport":   ( )
        "bridge":     ( )
        "client":     ( )
        "context":    ( )
        "scene":      ( append domains "project"; append domains "objects"; append domains "selection"
                        append domains "materials"; append domains "assets"; append domains "animation"
                        append domains "rigging"; append domains "render" )
        default:      ( append domains "objects"; append domains "selection"; append domains "materials" )
    )

    -- De-duplicate: mcpCtxMarkDirty bumps a revision per entry, and a domain
    -- listed twice would look like two separate changes.
    local uniq = #()
    for d in domains do
    (
        local dup = false
        for u in uniq while not dup do ( if u == d do dup = true )
        if not dup do append uniq d
    )
    uniq
)

/* Called by mcpDispatch after a mutating command succeeded.  The Max side has
   no notification for "a script changed something", and every MCP write goes
   through the dispatcher, so this is the one place that sees them all. */
fn mcpEvAfterWrite method =
(
    local domains = mcpEvDomainsForMethod method

    mcpEvRevision += 1
    mcpEvSeq += 1
    local row = #()
    mcpPair row "seq" mcpEvSeq
    mcpPair row "revision" mcpEvRevision
    mcpPair row "at" (if mcpEvClock == "" then (mcpEvClockUpdate()) else mcpEvClock)
    mcpPair row "event" "tool"
    mcpPair row "domains" domains
    mcpPair row "detail" method
    append mcpEvLog (mcpObj row)
    if mcpEvLog.count > mcpEvLogCap do
    (
        local keep = #()
        local first = mcpEvLog.count - mcpEvLogCap + 1
        for i = first to mcpEvLog.count do append keep mcpEvLog[i]
        mcpEvLog = keep
    )
    if mcpCtxMarkDirty != undefined do ( try ( mcpCtxMarkDirty domains ) catch() )
    mcpEvRevision
)


/*------------------------------------------------------------ registration*/
/* The notifications this build actually offers.  Anything not in this table
   is either covered by NodeEventCallback (added/deleted) or has no
   notification at all on this release and is therefore detected by the
   identity check in mcpCtxTick (new / reset / merge). */
fn mcpEvWanted =
(
    #(
        #selectionSetChanged, #nodeRenamed,
        #filePreSave, #filePostSave, #filePreOpen, #filePostOpen,
        #preImport, #postImport, #preExport, #postExport,
        #preRender, #postRender, #preRenderFrame, #postRenderFrame,
        #sceneUndo, #sceneRedo, #unitsChange,
        #layerCreated, #layerDeleted, #modPanelObjPostChange
    )
)

/* Probed but not required: recorded in the capability table so a different
   release can be diagnosed from the panel instead of from a bug report. */
fn mcpEvOptional =
(
    #(
        #nodeAdded, #nodeDeleted, #nodeCreated,
        #preSave, #postSave, #preOpen, #postOpen,
        #preNew, #postNew, #preReset, #postReset,
        #preMerge, #postMerge, #systemStartup, #systemShutdown,
        #timeUnitChange, #layerChanged, #postSceneLoad, #selectionChanged
    )
)

fn mcpEventsStop =
(
    local removed = 0
    for idName in mcpEvIds do
    (
        local ok = true
        try ( callbacks.removeScripts id:idName ) catch ( ok = false )
        if ok do removed += 1
    )
    mcpEvIds = #()

    -- NodeEventCallback has no destroy call; disabling it stops delivery and
    -- dropping the reference lets the callback be collected.
    if mcpEvNodeCb != undefined do ( try ( mcpEvNodeCb.enabled = false ) catch() )
    mcpEvNodeCb = undefined
    mcpEvRunning = false
    removed
)

fn mcpEventsStart silent:false =
(
    -- Idempotent by construction: always tear down first.  Loading the module
    -- twice (fileIn during development) must not stack duplicate handlers,
    -- which would multiply every event and every revision bump.
    try ( mcpEventsStop() ) catch()

    mcpEvClockUpdate()
    local caps = #()
    local registered = #()

    for note in (mcpEvWanted()) do
    (
        local idName = ("mcpEv_" + (note as string)) as name
        local code = "mcpEvFire #" + (note as string)
        local ok = true
        local err = ""
        try ( callbacks.addScript note code id:idName )
        catch ( ok = false; err = (getCurrentException() as string) )

        if ok then
        (
            append mcpEvIds idName
            append registered (note as string)
        )
        append caps #(note as string, ok, "wanted", err)
    )

    -- Optional probes: register, note whether this release knows the name,
    -- then remove again so they never interfere.
    for note in (mcpEvOptional()) do
    (
        local ok = true
        local err = ""
        local idName = ("mcpEvProbe_" + (note as string)) as name
        try ( callbacks.addScript note "ok" id:idName )
        catch ( ok = false; err = (getCurrentException() as string) )
        if ok do ( try ( callbacks.removeScripts id:idName ) catch() )
        append caps #(note as string, ok, "probe", err)
    )

    -- Node level events.  Two arguments, deliberately: see the header.
    local nodeOk = true
    local nodeErr = ""
    try ( mcpEvNodeCb = NodeEventCallback mouseUp:false delay:50 added:mcpEvNodeAdded deleted:mcpEvNodeDeleted )
    catch ( nodeOk = false; nodeErr = (getCurrentException() as string) )
    append caps #("NodeEventCallback(added,deleted)", nodeOk, "node", nodeErr)

    mcpEvCaps = caps
    mcpEvRunning = true
    mcpEvStartTime = (timeStamp())

    if not silent do
    (
        local missing = #()
        for c in caps do ( if c[3] == "wanted" and (not c[2]) do append missing c[1] )
        try
        (
            local note = "events: started, " + (registered.count as string) + " notifications, "
            if nodeOk then ( note += "node callback ok" ) else ( note += "node callback failed: " + nodeErr )
            if missing.count > 0 do note += ", unavailable: " + (mcpStringJoin missing ", ")
            mcpBridgeLog note
        )
        catch()
    )

    local p = #()
    mcpPair p "running" mcpEvRunning
    mcpPair p "registered" registered
    mcpPair p "revision" mcpEvRevision
    mcpObj p
)

fn mcpEventsStatus =
(
    local p = #()
    mcpPair p "running" mcpEvRunning
    mcpPair p "revision" mcpEvRevision
    mcpPair p "events" mcpEvSeq
    mcpPair p "logSize" mcpEvLog.count
    mcpPair p "uptimeMs" ((timeStamp()) - mcpEvStartTime)
    mcpPair p "notificationCount" mcpEvIds.count
    mcpPair p "nodeCallback" (mcpEvNodeCb != undefined)
    mcpPair p "clock" mcpEvClock
    mcpPair p "capabilities" mcpEvCaps
    mcpObj p
)

fn mcpEventsCaps =
(
    local used = #()
    local missing = #()
    local probed = #()
    for c in mcpEvCaps do
    (
        if c[3] == "wanted" then ( if c[2] then append used c[1] else append missing c[1] )
        else if c[3] == "probe" and c[2] do append probed c[1]
    )
    local p = #()
    mcpPair p "registered" used
    mcpPair p "unavailableHere" missing
    mcpPair p "alsoAvailable" probed
    mcpPair p "note" "availability is measured on the running build, not assumed from a version number"
    mcpObj p
)

-- Newest first, capped, for the panel and for context_events.
fn mcpEventsLog limit:50 =
(
    local lim = limit
    if lim < 1 do lim = 1
    local out = #()
    local i = mcpEvLog.count
    while i >= 1 and out.count < lim do
    (
        append out mcpEvLog[i]
        i -= 1
    )
    local p = #()
    mcpPair p "count" out.count
    mcpPair p "total" mcpEvSeq
    mcpPair p "revision" mcpEvRevision
    mcpPair p "events" out
    mcpObj p
)

fn mcpEvReset =
(
    mcpEvLog = #()
    mcpEvSeq = 0
    mcpEvRevision += 1
    mcpEvRevision
)
