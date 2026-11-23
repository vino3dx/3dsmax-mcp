/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_context.ms
   Consolidated scene-context plane: change event ledger, 9-domain incremental
   context store, and the in-Max client panel UI.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_events.ms
   ========================================================================== */
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
-- Shared with mcp_json.ms: every error string that reaches the wire or the log
-- is flattened and capped there, never raw from getCurrentException().
global mcpErrText
-- Owned by mcp_domains.ms (generated): the names a declared domain may use.
global mcpDomainNames
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
        -- `scene` travels with every selection change: mcpCtxBuildScene publishes
        -- selectionCount, so marking only `selection` left scene.selectionCount
        -- frozen at its first value while selection.count moved (Phase B F1).
        "selectionsetchanged": #("scene", "selection")
        "selectionchanged":    #("scene", "selection")
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
        -- Posted while the Modify panel edits an object: a spinner drag or a
        -- sub-object edit changes the geometry, which the objects domain
        -- reports (faces / verts / totals).  This is the only notification this
        -- release offers for those edits (Phase B F6).
        "modpanelobjpostchange": #("objects", "selection")
        default:               #("scene")
    )
)

/* Every change ends up here.  O(1): bump the counter, append one log row,
   tell the context cache which domains went stale.  Nothing scans the scene.

   `domains:` overrides the kind -> domains table.  The tick (mcpCtxTick) needs
   it: it detects a change that has no notification at all, so there is no kind
   to look up, yet the revision it moves must still be explainable in the log.
   Before this, the tick bumped mcpEvRevision directly and the event log had no
   row for the revision it produced, so a client that polled `revision` saw the
   number move with nothing to attribute it to (Phase B F5). */
fn mcpEvFire kind detail:"" domains:undefined =
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

    local dlist = domains
    if dlist == undefined do dlist = mcpEvDomainsFor kind
    local row = #()
    mcpPair row "seq" mcpEvSeq
    mcpPair row "revision" mcpEvRevision
    mcpPair row "at" (if mcpEvClock == "" then (mcpEvClockUpdate()) else mcpEvClock)
    mcpPair row "event" (kind as string)
    mcpPair row "domains" dlist
    if detail != "" do mcpPair row "detail" (mcpErrText detail maxLen:200)
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
        try ( mcpCtxMarkDirty dlist ) catch()
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
   because an arbitrary script really can touch anything.

   This table is a *fallback*: mcp_domains.ms is authoritative and answers for
   every registered command.  The rows that are known to be approximations are
   still corrected here (select / deselect carry `scene` because the scene
   section publishes selectionCount), so a bridge running on a stale table does
   not reintroduce a bug that was already fixed. */
fn mcpEvDomainsForMethod m =
(
    local n = toLower (m as string)
    -- Empty, not #("scene"): seeding scene here made every call -- including
    -- pure reads such as context_stats -- invalidate the scene domain, so a
    -- polling client never saw a cache hit and the event log filled with rows
    -- that claimed a change had happened.
    local domains = #()
    local p = n
    local cut = findString n "_"
    if cut != undefined and cut > 1 do p = substring n 1 (cut - 1)

    case p of
    (
        "select":     ( append domains "scene"; append domains "selection" )
        "deselect":   ( append domains "scene"; append domains "selection" )
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
        "mat":        ( append domains "materials"; append domains "assets" )
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
        "file":       ( append domains "project"; append domains "assets"; append domains "scene" )
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
        "scene":      ( append domains "scene"; append domains "project"; append domains "objects"; append domains "selection"
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

/* Called by mcpDispatch after a command succeeded.  Pass `domains:` with the
   declared set from mcp_domains.ms; when the argument is omitted the legacy
   prefix heuristic answers, which is only correct for commands that predate the
   declaration table (and those all have a row by now -- the contract test
   enforces it).

   Two things this must never do: bump the revision for a command that changed
   nothing (`domains` empty), and claim a domain that the table did not name. */
fn mcpEvAfterWrite method domains:undefined =
(
    local declared = (domains != undefined)
    local wanted = domains
    if wanted == undefined do wanted = mcpEvDomainsForMethod method

    -- De-duplicate and drop names this build does not know: a typo in the table
    -- would otherwise mark nothing and look like a successful write.
    local list = #()
    for d in wanted do
    (
        local name = ""
        try ( name = toLower (d as string) ) catch ( name = "" )
        if name != "" do
        (
            local known = true
            if mcpDomainNames != undefined do
            (
                known = false
                for k in mcpDomainNames do ( if k == name do known = true )
            )
            local dup = false
            for u in list while not dup do ( if u == name do dup = true )
            if known and (not dup) do append list name
        )
    )

    -- A read-only command maps to no domain at all.  Recording it would claim a
    -- change that did not happen and bump the revision the client uses for
    -- `since`.
    if list.count == 0 then return mcpEvRevision

    mcpEvRevision += 1
    mcpEvSeq += 1
    local row = #()
    mcpPair row "seq" mcpEvSeq
    mcpPair row "revision" mcpEvRevision
    mcpPair row "at" (if mcpEvClock == "" then (mcpEvClockUpdate()) else mcpEvClock)
    mcpPair row "event" "tool"
    mcpPair row "domains" list
    mcpPair row "source" (if declared then "declared" else "heuristic")
    mcpPair row "detail" (mcpErrText method maxLen:120)
    append mcpEvLog (mcpObj row)
    if mcpEvLog.count > mcpEvLogCap do
    (
        local keep = #()
        local first = mcpEvLog.count - mcpEvLogCap + 1
        for i = first to mcpEvLog.count do append keep mcpEvLog[i]
        mcpEvLog = keep
    )
    if mcpCtxMarkDirty != undefined do ( try ( mcpCtxMarkDirty list ) catch() )
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
        catch ( ok = false; err = (mcpErrText (getCurrentException())) )

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
        catch ( ok = false; err = (mcpErrText (getCurrentException())) )
        if ok do ( try ( callbacks.removeScripts id:idName ) catch() )
        append caps #(note as string, ok, "probe", err)
    )

    -- Node level events.  Two arguments, deliberately: see the header.
    local nodeOk = true
    local nodeErr = ""
    try ( mcpEvNodeCb = NodeEventCallback mouseUp:false delay:50 added:mcpEvNodeAdded deleted:mcpEvNodeDeleted )
    catch ( nodeOk = false; nodeErr = (mcpErrText (getCurrentException())) )
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

/* ==========================================================================
   SECTION: mcp_context.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_context.ms
   The scene context store: one place that answers "what is in this scene right
   now", with a revision so a caller can ask only for what changed.

   Why a cache instead of a scan per call
   --------------------------------------
   Measured on the live 65 object scene: building full node info for every
   object costs 7 ms inside Max, but list_objects costs 62 ms end to end.  The
   expensive half is serialising all that text, not reading the scene.  So the
   context never pushes everything: each domain is a bounded summary, rebuilt
   only when its revision moved, and the caller pages into the detail tools for
   the rest.

   Revision model
   --------------
   * mcpEvRevision (mcp_events.ms) is the global counter, bumped by every
     callback and by every mutating MCP command.
   * every domain keeps its own counter, so a material edit does not force the
     render section to be rebuilt.
   * a cache entry remembers the domain revision it was built from.  Stale
     entries are rebuilt on demand; nothing here runs on a timer.

   What this module does NOT do
   ----------------------------
   No polling of the scene graph on a timer, no watcher thread, no second
   socket.  mcpCtxTick rides the existing 25 ms bridge pump and does O(1) work
   (one clock string, one identity comparison every 8th tick).

   Data honesty rules (project principle 6/7/15)
   --------------------------------------------
   Every section carries `source`, `valid`, `supported`, `stale`, `revision`,
   `updatedAt` and, when a read failed, an `error` string -- never a fabricated
   zero.  `valid` is about this read, `supported` is about the API existing on
   this build, `stale` is about age; three different questions, three fields.
   A section whose underlying API is missing says `supported:false` and why.
-----------------------------------------------------------------------------*/

global mcpCtxDomains, mcpCtxRev, mcpCtxCache, mcpCtxBuilds, mcpCtxTickCount
global mcpCtxStamp, mcpCtxSent
global mcpCtxIdentity, mcpCtxLastError, mcpCtxLastFullScan, mcpCtxSlowMs
global mcpCtxMarkDirty, mcpCtxTick, mcpCtxDomainIndex, mcpCtxRevFor, mcpCtxPayload
global mcpCtxWrap, mcpCtxPayloadFull, mcpCtxCachedEntry, mcpCtxAnyEntry
global mcpCtxBuildScene, mcpCtxBuildSelection, mcpCtxBuildObjects, mcpCtxBuildMaterials
global mcpCtxBuildAssets, mcpCtxBuildAnimation, mcpCtxBuildRigging, mcpCtxBuildRender
global mcpCtxBuildProject, mcpCtxSuperKind, mcpCtxNodeRow, mcpCtxReset
global mcpH_context_get, mcpH_context_refresh, mcpH_context_stats, mcpH_context_events
global mcpContextGet, mcpContextRefresh, mcpContextStats, mcpContextSections
global mcpErrText, mcpToBool
global mcpCtxGeomFP, mcpCtxGeomCursor, mcpCtxGeomChanged, mcpCtxState
-- Owned by mcp_events.ms: the tick reports through it so every revision bump
-- has a log row (Phase B F5).
global mcpEvFire

if mcpCtxDomains == undefined do mcpCtxDomains = #(
    "scene", "selection", "objects", "materials", "assets",
    "animation", "rigging", "render", "project"
)
if mcpCtxRev == undefined do mcpCtxRev = #(0, 0, 0, 0, 0, 0, 0, 0, 0)
if mcpCtxStamp == undefined do mcpCtxStamp = #(0, 0, 0, 0, 0, 0, 0, 0, 0)
/* The changedAt value that was current when this domain last went out over the
   wire; -1 means "never sent".  Without it, a domain that has not changed since
   the engine started (changedAt 0) would be skipped for a caller that has never
   received it, which is a silent data gap, not an optimisation. */
if mcpCtxSent == undefined do mcpCtxSent = #(-1, -1, -1, -1, -1, -1, -1, -1, -1)
if mcpCtxCache == undefined do mcpCtxCache = #()
if mcpCtxBuilds == undefined do mcpCtxBuilds = 0
if mcpCtxTickCount == undefined do mcpCtxTickCount = 0
if mcpCtxIdentity == undefined do mcpCtxIdentity = #(-1, -1, "")
if mcpCtxLastError == undefined do mcpCtxLastError = ""
if mcpCtxLastFullScan == undefined do mcpCtxLastFullScan = 0
if mcpCtxSlowMs == undefined do mcpCtxSlowMs = 0
/* Geometry fingerprint, see mcpCtxGeomChanged: one row per object, #(handle,
   faces, verts).  `mcpCtxGeomCursor` walks the object list a slice at a time. */
if mcpCtxGeomFP == undefined do mcpCtxGeomFP = #()
if mcpCtxGeomCursor == undefined do mcpCtxGeomCursor = 0


/*---------------------------------------------------------------- revision API*/
fn mcpCtxDomainIndex domain =
(
    local d = toLower (domain as string)
    local idx = 0
    for i = 1 to mcpCtxDomains.count while idx == 0 do
        ( if mcpCtxDomains[i] == d do idx = i )
    idx
)

fn mcpCtxRevFor domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then 0 else mcpCtxRev[i]
)

/* Called from mcp_events.ms on every change.  Must stay O(domains): it runs
   inside synchronous callbacks such as #selectionSetChanged.

   Two counters per domain, on purpose:
     mcpCtxRev[i]   - the cache key.  Bumped so the cached copy is dropped.
     mcpCtxStamp[i] - the value of the *global* revision at the moment this
                      domain last changed.  This is what `since` compares
                      against.
   Comparing `since` (a global revision) with mcpCtxRev would silently lose
   updates: a domain that changed once has rev 1 while the global revision may
   already be 40, so `rev <= since` would call a real change "unchanged". */
fn mcpCtxMarkDirty domains =
(
    local touched = 0
    local stamp = 0
    if mcpEvRevision != undefined do stamp = mcpEvRevision
    for d in domains do
    (
        local i = mcpCtxDomainIndex d
        if i > 0 do
        (
            mcpCtxRev[i] = mcpCtxRev[i] + 1
            mcpCtxStamp[i] = stamp
            touched += 1
        )
    )
    if touched > 0 and mcpEvClock != undefined and mcpEvClock == "" do
        ( try ( mcpEvClockUpdate() ) catch() )
    touched
)

fn mcpCtxReset =
(
    mcpCtxCache = #()
    local stamp = 0
    if mcpEvRevision != undefined do stamp = mcpEvRevision
    for i = 1 to mcpCtxRev.count do
    (
        mcpCtxRev[i] = mcpCtxRev[i] + 1
        mcpCtxStamp[i] = stamp
        -- An explicit refresh means "re-read", so the next context_get sends
        -- everything again instead of trusting the caller's cursor.
        mcpCtxSent[i] = -1
    )
    mcpCtxLastError = ""
    mcpCtxCache.count
)


/*------------------------------------------------------------ classification*/
/* `superclassof` does not answer in one spelling: measured on 2022 it returns
   "GeometryClass" but "shape", "light", "camera", "helper" in lower case, so
   the old `sc == "Geometry"` comparisons in scene_statistics never matched and
   every object landed in "other".  Normalise once, here, and let both this
   module and the statistics tool use the same answer. */
fn mcpCtxSuperKind n =
(
    local v = ""
    try ( v = toLower ((superclassof n) as string) ) catch ( v = "" )
    local cls = ""
    try ( cls = (classof n) as string ) catch ( cls = "" )

    -- Early returns instead of a long if/else chain: MAXScript closes an
    -- `if ... then <expr>` statement at the end of the line, so a following
    -- `else` on its own line is a syntax error ("at else, expected <factor>").
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

/* Compact row for the selection section.  `mcpNodeInfo` is the full record used
   by get_object_info; this one is deliberately smaller because the selection
   section is rebuilt on every click. */
fn mcpCtxNodeRow n detail:"brief" =
(
    local p = #()
    mcpPair p "name" (try ( n.name ) catch ( "" ))
    mcpPair p "handle" (try ( (getHandleByAnim n) as integer ) catch ( 0 ))
    mcpPair p "class" (try ( (classof n) as string ) catch ( "" ))
    mcpPair p "kind" (mcpCtxSuperKind n)
    mcpPair p "parent" (try ( if n.parent != undefined then n.parent.name else "" ) catch ( "" ))
    mcpPair p "layer" (try ( n.layer.name ) catch ( "" ))
    mcpPair p "material" (try ( if n.material != undefined then n.material.name else "" ) catch ( "" ))
    mcpPair p "hidden" (try ( n.isHidden ) catch ( false ))
    mcpPair p "frozen" (try ( n.isFrozen ) catch ( false ))
    mcpPair p "modifierCount" (try ( n.modifiers.count ) catch ( 0 ))
    mcpPair p "faces" (try ( (getPolygonCount n)[1] ) catch ( 0 ))
    mcpPair p "verts" (try ( (getPolygonCount n)[2] ) catch ( 0 ))

    if detail == "full" do
    (
        mcpPair p "position" (try ( n.position ) catch ( [0,0,0] ))
        mcpPair p "rotation" (try ( (n.rotation as eulerAngles) ) catch ( (eulerAngles 0 0 0) ))
        mcpPair p "scale" (try ( n.scale ) catch ( [1,1,1] ))
        local mn = [0,0,0]
        local mx = [0,0,0]
        try
        (
            local bb = nodeGetBoundingBox n (matrix3 1)
            mn = bb[1]
            mx = bb[2]
        )
        catch()
        mcpPair p "bboxMin" mn
        mcpPair p "bboxMax" mx
        mcpPair p "size" (mx - mn)
        local mods = #()
        try ( for m in n.modifiers do append mods #((classof m) as string, (try (m.name) catch (""))) )
        catch()
        mcpPair p "modifiers" mods
        mcpPair p "wirecolor" (try ( n.wirecolor ) catch ( (color 0 0 0) ))
    )
    mcpObj p
)


/*------------------------------------------------------------------ builders*/
fn mcpCtxBuildScene =
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
    mcpPair p "systemUnits" (try ( (units.SystemType) as string ) catch ( "" ))
    -- Display units and the unit scale are two different numbers and tools
    -- routinely need both: SystemType is what geometry is stored in.
    mcpPair p "displayUnits" (try ( (units.DisplayType) as string ) catch ( "" ))
    mcpPair p "unitScale" (try ( units.SystemScale as float ) catch ( 0.0 ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "currentFrame" (try ( currentTime.frame as integer ) catch ( 0 ))
    mcpPair p "maxVersion" (mcpMaxYear())
    mcpPair p "openGroups" (try ( (for g in objects where (classof g) == GroupHead collect g.name) ) catch ( #() ))
    mcpObj p
)

fn mcpCtxBuildSelection detail:"brief" limit:50 =
(
    local nodes = #()
    try ( for i = 1 to selection.count do append nodes selection[i] ) catch()
    local shown = #()
    local n = 0
    for node in nodes do
    (
        n += 1
        if n <= limit do append shown (mcpCtxNodeRow node detail:detail)
    )
    local kinds = #()
    local kk = #()
    local totalFaces = 0
    local totalVerts = 0
    for node in nodes do
    (
        local k = mcpCtxSuperKind node
        local idx = 0
        for i = 1 to kk.count while idx == 0 do ( if kk[i] == k do idx = i )
        if idx == 0 then ( append kk k; append kinds #(k, 1) ) else ( kinds[idx][2] = kinds[idx][2] + 1 )
        try ( totalFaces += (getPolygonCount node)[1] ) catch()
        try ( totalVerts += (getPolygonCount node)[2] ) catch()
    )
    local p = #()
    mcpPair p "count" nodes.count
    mcpPair p "shown" shown.count
    mcpPair p "truncated" (nodes.count > shown.count)
    mcpPair p "kinds" kinds
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "objects" shown
    mcpObj p
)

fn mcpCtxBuildObjects =
(
    local counts = #(0, 0, 0, 0, 0, 0, 0, 0, 0)   -- geometry shape light camera helper spacewarp system bone other
    local hiddenCount = 0
    local frozenCount = 0
    local rootCount = 0
    local totalFaces = 0
    local totalVerts = 0
    local names = #()

    for o in objects do
    (
        local k = mcpCtxSuperKind o
        case k of
        (
            "geometry":   counts[1] += 1
            "shape":      counts[2] += 1
            "light":      counts[3] += 1
            "camera":     counts[4] += 1
            "helper":     counts[5] += 1
            "spacewarp":  counts[6] += 1
            "system":     counts[7] += 1
            "bone":       counts[8] += 1
            default:      counts[9] += 1
        )
        try ( if o.isHidden do hiddenCount += 1 ) catch()
        try ( if o.isFrozen do frozenCount += 1 ) catch()
        try ( if o.parent == undefined do rootCount += 1 ) catch()
        try ( local pc = getPolygonCount o; totalFaces += pc[1]; totalVerts += pc[2] ) catch()
    )

    local p = #()
    mcpPair p "total" (try ( objects.count ) catch ( 0 ))
    mcpPair p "geometry" counts[1]
    mcpPair p "shapes" counts[2]
    mcpPair p "lights" counts[3]
    mcpPair p "cameras" counts[4]
    mcpPair p "helpers" counts[5]
    mcpPair p "spacewarps" counts[6]
    mcpPair p "systems" counts[7]
    mcpPair p "bones" counts[8]
    mcpPair p "other" counts[9]
    mcpPair p "roots" rootCount
    mcpPair p "hidden" hiddenCount
    mcpPair p "frozen" frozenCount
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "classification" "superclassof normalised (see mcpCtxSuperKind)"
    mcpObj p
)

fn mcpCtxBuildMaterials limit:100 =
(
    local rows = #()
    local total = 0
    local withMaps = 0
    local withSubs = 0
    local list = #()
    try ( list = sceneMaterials ) catch ( list = #() )
    for m in list do
    (
        total += 1
        local mapCount = 0
        try
        (
            for prop in (getPropNames m) do
            (
                local v = getProperty m prop
                if isKindOf v TextureMap do mapCount += 1
            )
        )
        catch()
        local subCount = 0
        try ( subCount = (getSubMtls m).count ) catch ( subCount = 0 )
        if mapCount > 0 do withMaps += 1
        if subCount > 0 do withSubs += 1
        if rows.count < limit do
        (
            local p = #()
            mcpPair p "name" (try ( m.name ) catch ( "" ))
            mcpPair p "class" (try ( (classof m) as string ) catch ( "" ))
            mcpPair p "mapSlots" mapCount
            mcpPair p "subMaterials" subCount
            append rows (mcpObj p)
        )
    )
    local p = #()
    mcpPair p "count" total
    mcpPair p "withMaps" withMaps
    mcpPair p "withSubMaterials" withSubs
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (total > rows.count)
    mcpPair p "items" rows
    mcpObj p
)

fn mcpCtxBuildAssets limit:100 =
(
    local textures = #()
    try ( textures = mcpCollectBitmapTextures() ) catch ( textures = #() )
    local rows = #()
    local missingFiles = #()
    local seen = #()
    local dupes = 0
    local missing = 0
    local totalBytes = 0

    for t in textures do
    (
        local fname = ""
        try ( fname = t.filename ) catch ( fname = "" )
        local exists = false
        local size = 0
        if fname != "" do
        (
            try ( exists = doesFileExist fname ) catch ( exists = false )
            if exists do
            (
                -- FileInfo, not BitmapTexture.bitmap: reading the size of a
                -- bitmap from disk just to report bytes would load every map.
                try
                (
                    local fi = (dotNetClass "System.IO.FileInfo").new fname
                    size = fi.Length
                )
                catch ( size = 0 )
            )
        )
        if not exists do
        (
            if fname != "" do
            (
                missing += 1
                local known = false
                for f in missingFiles while not known do ( if (toLower f) == (toLower fname) do known = true )
                if not known do append missingFiles fname
            )
        )

        totalBytes += size

        if fname != "" do
        (
            local key = toLower fname
            local idx = 0
            for i = 1 to seen.count while idx == 0 do ( if seen[i][1] == key do idx = i )
            if idx == 0 then ( append seen #(key, 1) ) else (
                seen[idx][2] = seen[idx][2] + 1
                if seen[idx][2] == 2 do dupes += 1
            )
        )

        if rows.count < limit do
        (
            local p = #()
            mcpPair p "name" (try ( t.name ) catch ( "" ))
            mcpPair p "class" (try ( (classof t) as string ) catch ( "" ))
            mcpPair p "filename" fname
            mcpPair p "exists" exists
            mcpPair p "sizeBytes" size
            append rows (mcpObj p)
        )
    )

    local shared = #()
    for s in seen do ( if s[2] > 1 do append shared #(s[1], s[2]) )

    local p = #()
    mcpPair p "count" textures.count
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (textures.count > rows.count)
    mcpPair p "missing" missing
    mcpPair p "missingFiles" missingFiles
    mcpPair p "duplicateFiles" dupes
    mcpPair p "sharedFiles" shared
    mcpPair p "totalBytes" totalBytes
    mcpPair p "items" rows
    mcpObj p
)

fn mcpCtxBuildAnimation limit:100 =
(
    local keyed = 0
    local totalKeys = 0
    local rows = #()
    local controllers = #()

    for o in objects do
    (
        local pk = 0
        local rk = 0
        local sk = 0
        try ( pk = o.position.controller.keys.count ) catch ( pk = 0 )
        try ( rk = o.rotation.controller.keys.count ) catch ( rk = 0 )
        try ( sk = o.scale.controller.keys.count ) catch ( sk = 0 )
        local sum = pk + rk + sk
        if sum > 0 do
        (
            keyed += 1
            totalKeys += sum
            if rows.count < limit do
            (
                local p = #()
                mcpPair p "name" (try ( o.name ) catch ( "" ))
                mcpPair p "positionKeys" pk
                mcpPair p "rotationKeys" rk
                mcpPair p "scaleKeys" sk
                mcpPair p "total" sum
                append rows (mcpObj p)
            )
        )
        -- controller class inventory: catches constraints and scripted
        -- controllers that hold no keys but still define the motion.
        local ctrlClass = ""
        try ( ctrlClass = (classof o.position.controller) as string ) catch ( ctrlClass = "" )
        if ctrlClass != "" and (findString (toLower ctrlClass) "prs") == undefined do
        (
            local idx = 0
            for i = 1 to controllers.count while idx == 0 do
                ( if controllers[i][1] == ctrlClass do idx = i )
            if idx == 0 then ( append controllers #(ctrlClass, 1) ) else ( controllers[idx][2] = controllers[idx][2] + 1 )
        )
    )

    local p = #()
    mcpPair p "currentFrame" (try ( currentTime.frame as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "animatedObjects" keyed
    mcpPair p "totalKeys" totalKeys
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (keyed > rows.count)
    mcpPair p "objects" rows
    mcpPair p "nonDefaultControllers" controllers
    mcpObj p
)

fn mcpCtxBuildRigging =
(
    local boneGeom = 0
    local biped = 0
    local cat = 0
    local dummyBones = 0
    local skinObjects = 0
    local skinnedBones = 0
    local otherHelpers = 0
    local systems = #()

    for o in objects do
    (
        local cls = ""
        try ( cls = (classof o) as string ) catch ( cls = "" )
        if cls == "BoneGeometry" then ( boneGeom += 1 ) else if cls == "Biped_Object" then ( biped += 1 ) else if cls == "CATBone" then ( cat += 1 ) else if cls == "Dummy" then ( dummyBones += 1 ) else if cls == "Point" then ( otherHelpers += 1 )

        local isSkin = false
        try
        (
            for m in o.modifiers do
                ( if (classof m) as string == "Skin" do isSkin = true )
        )
        catch()
        if isSkin do
        (
            skinObjects += 1
            try
            (
                for m in o.modifiers do
                (
                    if (classof m) as string == "Skin" do
                    (
                        local nb = 0
                        try ( nb = skinOps.getNumberBones m ) catch ( nb = 0 )
                        skinnedBones += nb
                    )
                )
            )
            catch()
        )
        -- System objects (Biped controller root, CAT rig, ...) are reported
        -- separately: they are not bones but they own the rig.
        if (mcpCtxSuperKind o) == "system" do
        (
            local idx = 0
            for i = 1 to systems.count while idx == 0 do ( if systems[i][1] == cls do idx = i )
            if idx == 0 then ( append systems #(cls, 1) ) else ( systems[idx][2] = systems[idx][2] + 1 )
        )
    )

    local totalBones = boneGeom + biped + cat
    local p = #()
    mcpPair p "bones" totalBones
    mcpPair p "boneGeometry" boneGeom
    mcpPair p "bipedBones" biped
    mcpPair p "catBones" cat
    mcpPair p "dummies" dummyBones
    mcpPair p "pointHelpers" otherHelpers
    mcpPair p "skinObjects" skinObjects
    mcpPair p "bonesInSkins" skinnedBones
    mcpPair p "systems" systems
    mcpPair p "supported" true
    mcpPair p "note" "counts by class; Biped and CAT are counted separately because they do not use BoneGeometry"
    mcpObj p
)

fn mcpCtxBuildRender =
(
    local p = #()
    -- Field-level provenance, see mcpCtxField: a value this build cannot read
    -- is published as null and named here, never as a plausible-looking 0.
    local unreadable = #()
    mcpPair p "renderer" (mcpCurrentRendererName())

    local v = 0
    local ok = true
    try ( v = renderWidth as integer ) catch ( ok = false )
    mcpCtxField p unreadable "width" ok v

    v = 0
    ok = true
    try ( v = renderHeight as integer ) catch ( ok = false )
    mcpCtxField p unreadable "height" ok v

    local fa = 1.0
    ok = true
    try ( fa = renderPixelAspect as float ) catch ( ok = false )
    mcpCtxField p unreadable "pixelAspect" ok fa

    mcpPair p "outputPath" (try ( rendOutputFilename ) catch ( "" ))
    -- rendSaveFile already returns a Boolean; `as boolean` on it raises.
    mcpPair p "saveFile" (mcpToBool (try ( rendSaveFile ) catch ( undefined )) fallback:false)

    local tt = 0
    ok = true
    try ( tt = rendTimeType as integer ) catch ( ok = false )
    mcpCtxField p unreadable "timeType" ok tt

    -- renderStart / renderEnd are the *render output* range, not
    -- animationRange: a scene with 0/100 keyframes can render frame 0..0.
    local fs = 0
    ok = true
    try ( fs = renderStart as integer ) catch ( ok = false )
    mcpCtxField p unreadable "frameStart" ok fs

    local fe = 0
    ok = true
    try ( fe = renderEnd as integer ) catch ( ok = false )
    mcpCtxField p unreadable "frameEnd" ok fe

    local fr = ""
    ok = true
    try ( fr = rendPickupFrames as string ) catch ( ok = false )
    mcpCtxField p unreadable "frames" ok fr

    local elements = 0
    local okEl = true
    -- MAXScript cannot call a method on a call result
    -- (`maxOps.GetCurRenderElementMgr().NumRenderElements()` is a syntax
    -- error), so the manager is bound first.
    local mgr = undefined
    try ( mgr = maxOps.GetCurRenderElementMgr() ) catch ( mgr = undefined )
    if mgr != undefined do
    (
        try ( elements = mgr.NumRenderElements() )
        catch ( okEl = false )
    )
    mcpPair p "renderElementCount" elements
    mcpPair p "renderElementsSupported" okEl

    -- Three different facts used to collapse into one string: "an exposure
    -- control is assigned" (a class name), "none is assigned" (the deployed
    -- build published the literal "UndefinedClass", which is what `classof`
    -- answers for undefined) and "the read failed" (also "").  Now: class name,
    -- "" = none assigned, null + `unreadable` = the read failed.
    local expo = ""
    ok = true
    try
    (
        local ec = SceneExposureControl.exposureControl
        if ec != undefined do expo = (classof ec) as string
    )
    catch ( ok = false )
    mcpCtxField p unreadable "exposureControl" ok expo

    -- Bracket state from #preRender / #postRender.  No progress percentage is
    -- reported because this release has no notification for it; saying "no
    -- progress available" is more useful than inventing a number.
    mcpPair p "rendering" (if mcpEvRendering == undefined then false else mcpEvRendering)
    mcpPair p "lastRenderMs" (if mcpEvLastRender == undefined then 0 else mcpEvLastRender)
    mcpPair p "progressAvailable" false
    mcpPair p "unreadable" unreadable
    mcpObj p
)

fn mcpCtxBuildProject =
(
    local projectFolder = ""
    try ( projectFolder = pathConfig.getCurrentProjectFolder() ) catch ( projectFolder = "" )

    local xrefCount = 0
    local xrefs = #()
    local xrefOk = true
    try
    (
        xrefCount = xrefs.getXRefFileCount()
        local lim = 50
        local n = 0
        for i = 1 to xrefCount do
        (
            n += 1
            if n <= lim do
            (
                local x = undefined
                try ( x = xrefs.getXRefFile i ) catch ( x = undefined )
                if x != undefined do
                (
                    local row = #()
                    mcpPair row "file" (try ( x.filename ) catch ( "" ))
                    mcpPair row "disabled" (try ( x.disabled ) catch ( false ))
                    append xrefs (mcpObj row)
                )
            )
        )
    )
    catch ( xrefOk = false )

    local p = #()
    mcpPair p "projectFolder" projectFolder
    mcpPair p "sceneFile" (try ( maxFilePath + maxFileName ) catch ( "" ))
    mcpPair p "sceneDir" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "xrefCount" xrefCount
    mcpPair p "xrefs" xrefs
    mcpPair p "xrefSupported" xrefOk
    mcpPair p "saveRequired" (try ( getSaveRequired() ) catch ( false ))
    mcpObj p
)


/*----------------------------------------------------------------- assembly*/
fn mcpCtxBuild domain =
(
    local d = toLower (domain as string)
    local limit = 100
    case d of
    (
        "scene":     (mcpCtxBuildScene())
        "selection": (mcpCtxBuildSelection detail:"brief" limit:50)
        "objects":   (mcpCtxBuildObjects())
        "materials": (mcpCtxBuildMaterials limit:limit)
        "assets":    (mcpCtxBuildAssets limit:limit)
        "animation": (mcpCtxBuildAnimation limit:limit)
        "rigging":   (mcpCtxBuildRigging())
        "render":    (mcpCtxBuildRender())
        "project":   (mcpCtxBuildProject())
        default:     (mcpObj #(#("supported", false), #("error", "unknown context section: " + d)))
    )
)

/* Returns #(payload, wasCached).  One cache entry per domain; rebuilding is
   always a full rebuild of that domain (partial merges of nested records would
   be more code than they are worth at these sizes). */
/* Every section that leaves the bridge goes through this wrapper, including the
   uncached `detail:"full"` variants.  Skipping it once (as the first draft did
   for a full selection dump) produces a section with no revision, no source and
   no validity flag, which is exactly the "returned ok but unverifiable" case
   the project forbids. */
/* The cached wrapper for a domain, but only when it was built from the
   domain's current revision.  Returning an out-of-date copy is the failure
   mode this whole module exists to avoid, so a miss returns undefined and the
   caller rebuilds. */
fn mcpCtxCachedEntry domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then return undefined
    local rev = mcpCtxRev[i]
    local found = undefined
    for e in mcpCtxCache do
    (
        if e[1] == mcpCtxDomains[i] and e[2] == rev do found = e
    )
    found
)

/* The last thing this domain produced, whatever its revision.  Only the panel
   uses it, to show an out-of-date snapshot with an explicit STALE banner
   instead of an empty page: serving it silently would be the bug, labelling it
   is not. */
fn mcpCtxAnyEntry domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then return undefined
    local found = undefined
    for e in mcpCtxCache do
    (
        if e[1] == mcpCtxDomains[i] do found = e
    )
    found
)

/*------------------------------------------------ specific field provenance*/
/* Pairs one field with its value, or with null plus an entry in `unreadable`.

   Why this exists (Phase B F3): `try ( renderStart as integer ) catch ( 0 )`
   publishes 0 when the read failed, and 0 is a *plausible* value for a frame
   number, so the caller cannot tell "frame 0" from "this build would not tell
   me".  Every field routed through here either has a real value or is null and
   named in the section's `unreadable` list. */
fn mcpCtxField p unreadable key ok value =
(
    if ok then ( mcpPair p key value )
    else
    (
        append unreadable key
        mcpPair p key undefined
    )
    p
)

/* The single word a caller can branch on.  Six states, because six different
   situations need six different reactions:

     failed      - this read threw; retry, the API is there but unhappy
     unsupported - this Max build has no such API; retrying will never help
     stale       - the payload predates the domain's latest change; re-read it
     partial     - the section is valid but some fields were unreadable (null)
     fresh       - valid, current, nothing missing
     unbuilt     - never built at all (context_stats only; a section that was
                   never requested is not a failed section)

   Precedence is deliberate: a permanent reason outranks a transient one, so
   `unsupported` wins over `stale` (re-reading cannot fix a missing API). */
fn mcpCtxState err supported stale unreadable =
(
    if err != "" then return "failed"
    if not supported then return "unsupported"
    if stale then return "stale"
    if unreadable.count > 0 then return "partial"
    "fresh"
)

/* The provenance block every section carries.  Four fields answer four
   different questions and must never be collapsed into one boolean:

     valid      - did THIS read produce data without raising?
     supported  - does this build offer the API this domain needs at all?
                  (a missing polyop sub-API is "unsupported", not "invalid")
     stale      - is this payload older than the domain's latest change?
                  a cache entry is dropped rather than served out of date, so
                  this is normally false and becomes true only when the domain
                  moved between the lookup and the wrap.
     updatedAt  - when the payload was generated (Max side clock string).

   `state` folds those three into the one value most callers actually want, and
   `complete` is false when any field of the section is null because it could
   not be read.

   `supported` defaults to whatever the collector itself declared in its
   payload, so a section that probed an API and found it missing reports
   supported:false without the wrapper having to know about that API. */
fn mcpCtxWrap domain rev payload ms err supported:true stale:false =
(
    local sup = supported
    if mcpIsObj payload and (mcpHas payload "supported") do
    (
        sup = mcpToBool (mcpGet payload "supported") fallback:supported
    )

    -- Fields the collector could not read, published as null by mcpCtxField.
    local unreadable = #()
    if mcpIsObj payload and (mcpHas payload "unreadable") do
    (
        local raw = mcpGet payload "unreadable"
        if isKindOf raw Array do unreadable = raw
    )

    local pairs = #()
    mcpPair pairs "domain" domain
    mcpPair pairs "revision" rev
    /* The global revision at which this domain last changed -- the same value
       `since` is compared against, and the same number context_stats reports.
       Without it a caller can see that a domain came back but not whether it is
       newer than the cursor it sent, which is the only question that matters
       for incremental sync. */
    local stamp = 0
    local idx = mcpCtxDomainIndex (domain as string)
    if idx > 0 do stamp = mcpCtxStamp[idx]
    mcpPair pairs "changedAt" stamp
    mcpPair pairs "updatedAt" (if mcpEvClock == undefined then "" else mcpEvClock)
    mcpPair pairs "source" "maxscript"
    mcpPair pairs "valid" (err == "")
    mcpPair pairs "stale" stale
    mcpPair pairs "supported" sup
    mcpPair pairs "state" (mcpCtxState err sup stale unreadable)
    mcpPair pairs "complete" ((err == "") and (unreadable.count == 0))
    mcpPair pairs "buildMs" ms
    if err != "" do mcpPair pairs "error" err
    if unreadable.count > 0 do mcpPair pairs "unreadable" unreadable
    -- `data` keeps the payload one level down so provenance can never collide
    -- with a field the collector happens to use.
    mcpPair pairs "data" payload
    mcpObj pairs
)

fn mcpCtxPayload domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then return #(mcpObj #(#("supported", false), #("error", "unknown domain")), false)

    local rev = mcpCtxRev[i]
    local entry = mcpCtxCachedEntry mcpCtxDomains[i]
    if entry != undefined then return #(entry[3], true)

    local t0 = (timeStamp())
    local payload = undefined
    local err = ""
    try ( payload = mcpCtxBuild mcpCtxDomains[i] )
    catch ( err = mcpErrText (getCurrentException()) )

    if payload == undefined do
    (
        mcpCtxLastError = err
        -- No `supported:false` here: the domain exists, this one build threw.
        -- Conflating the two would make a transient failure look permanent.
        payload = mcpObj #(
            #("valid", false),
            #("error", "context build failed: " + err)
        )
    )

    local ms = (timeStamp()) - t0
    if ms > mcpCtxSlowMs do mcpCtxSlowMs = ms
    mcpCtxBuilds += 1

    -- Wrap with the provenance every section must carry.
    local wrapped = mcpCtxWrap mcpCtxDomains[i] rev payload ms err stale:(mcpCtxRev[i] > rev)

    -- Replace the entry for this domain (keep at most one per domain).
    local kept = #()
    for e in mcpCtxCache do ( if e[1] != mcpCtxDomains[i] do append kept e )
    append kept #(mcpCtxDomains[i], rev, wrapped)
    mcpCtxCache = kept

    #(wrapped, false)
)


/*--------------------------------------------------------------- the tick*/
/* Interactive geometry edits are the one class of change this release gives no
   usable notification for.  Measured on 3ds Max 2022: dragging vertices in a
   viewport fires neither #selectionSetChanged nor NodeEventCallback
   (geometryChanged is not delivered for interactive edits), and
   #modPanelObjPostChange only covers the modifier panel.  So the scene is
   fingerprinted -- but a full sweep costs ~7 ms on the 65-object reference
   scene, which is far too much to spend on a 25 ms pump, so the sweep is
   sliced: OBJECT COUNT / 8 per tick, i.e. a full pass roughly every 1.6 s.
   Each tick costs 8 getPolygonCount calls (measured well under 1 ms).

   The fingerprint deliberately watches only face/vertex counts.  A transform
   drag does not change them (and transform edits are reported by the tools, or
   by #sceneUndo), but a vertex drag, a topology change or a modifier that
   changes the mesh does -- which is exactly the case that used to go unnoticed
   until an unrelated event happened to fire. */
fn mcpCtxGeomSlice start count =
(
    local out = #()
    local total = 0
    try ( total = objects.count ) catch ( total = 0 )
    if total == 0 then return out

    for k = 0 to (count - 1) do
    (
        local i = (mod (start + k) total) + 1
        local o = undefined
        try ( o = objects[i] ) catch ( o = undefined )
        if o != undefined do
        (
            -- -1 means "this node does not report a polygon count" (a light, a
            -- camera, a helper).  It is compared like any other value, so those
            -- nodes simply never look changed.
            local h = 0
            local f = -1
            local v = -1
            try ( h = (getHandleByAnim o) as integer ) catch ( h = 0 )
            try ( local pc = getPolygonCount o; f = pc[1]; v = pc[2] ) catch ( f = -1 )
            append out #(h, f, v)
        )
    )
    out
)

/* Returns how many objects changed since the last pass over their slice.
   A different object count is already caught by the identity check above, so
   the fingerprint is rebuilt rather than compared in that case. */
fn mcpCtxGeomChanged =
(
    local total = 0
    try ( total = objects.count ) catch ( total = 0 )
    if total == 0 do
    (
        mcpCtxGeomFP = #()
        mcpCtxGeomCursor = 0
        return 0
    )
    if total != mcpCtxGeomFP.count do
    (
        mcpCtxGeomFP = mcpCtxGeomSlice 0 total
        mcpCtxGeomCursor = 0
        return 0
    )

    -- `as integer` on purpose: MAXScript `/` yields a float, and a float index
    -- into `objects` would be rounded rather than truncated.
    local per = (((total + 7) / 8) as integer)
    if per < 1 do per = 1
    local slice = mcpCtxGeomSlice mcpCtxGeomCursor per
    mcpCtxGeomCursor = mod (mcpCtxGeomCursor + per) total

    local changed = 0
    for row in slice do
    (
        local idx = 0
        for i = 1 to mcpCtxGeomFP.count while idx == 0 do
            ( if mcpCtxGeomFP[i][1] == row[1] do idx = i )
        if idx == 0 then
        (
            -- New handle in a same-size list (delete + create): treat as a
            -- change and record it, so the next pass compares like with like.
            append mcpCtxGeomFP row
            changed += 1
        )
        else if mcpCtxGeomFP[idx][2] != row[2] or mcpCtxGeomFP[idx][3] != row[3] do
        (
            mcpCtxGeomFP[idx] = row
            changed += 1
        )
    )
    changed
)

/* Runs on the existing bridge pump.  Budget: one clock string, one identity
   comparison every 8th tick, plus one eighth of a geometry fingerprint pass. */
fn mcpCtxTick =
(
    mcpCtxTickCount += 1
    if (mod mcpCtxTickCount 8) != 0 do return 0

    try ( mcpEvClockUpdate() ) catch()

    -- Identity check: catches what has no notification on this release
    -- (file > new, reset, merge, a script writing to the scene outside MCP).
    local now = #(0, 0, "")
    try ( now = #(objects.count, selection.count, (maxFilePath + maxFileName)) ) catch ( now = #(-1, -1, "") )

    local changed = #()
    -- `scene` rides along: mcpCtxBuildScene publishes objectCount and
    -- selectionCount, so a change to either makes the cached scene section
    -- wrong, not only the objects / selection section (Phase B F1).
    local why = ""
    if now[1] != mcpCtxIdentity[1] do
    (
        append changed "objects"
        append changed "scene"
        why = "object count changed"
    )
    if now[2] != mcpCtxIdentity[2] do
    (
        append changed "scene"
        append changed "selection"
        if why == "" do why = "selection count changed"
    )
    if now[3] != mcpCtxIdentity[3] do
    (
        append changed "scene"
        append changed "project"
        append changed "objects"
        append changed "selection"
        append changed "materials"
        append changed "assets"
        why = "scene file changed"
    )
    mcpCtxIdentity = now

    -- Sliced geometry sweep, see mcpCtxGeomChanged.  A shape edit changes the
    -- objects domain (faces / verts / totals) and, through it, whatever the
    -- panel shows for the selection.
    local geomChanged = 0
    try ( geomChanged = mcpCtxGeomChanged() ) catch ( geomChanged = 0 )
    if geomChanged > 0 do
    (
        append changed "objects"
        append changed "selection"
        why = (geomChanged as string) + " object(s) changed shape"
    )

    if changed.count > 0 do
    (
        -- De-duplicate before bumping: "objects" can be listed twice above.
        local uniq = #()
        for d in changed do
        (
            local dup = false
            for u in uniq while not dup do ( if u == d do dup = true )
            if not dup do append uniq d
        )
        -- Report through mcpEvFire instead of bumping mcpEvRevision here.  The
        -- bump used to happen with no event row at all, so a client watching
        -- `revision` saw it move with nothing to explain it (Phase B F5).
        -- mcpEvFire bumps first and stamps the domains with the new revision,
        -- which is the order mcpCtxMarkDirty requires.
        try ( mcpEvFire "tick" detail:why domains:uniq )
        catch
        (
            -- mcp_events.ms missing or its handler raised: still move the
            -- revision forward, or the caller's `since` cursor would skip a
            -- change that really happened.
            if mcpEvRevision != undefined do mcpEvRevision += 1
            mcpCtxMarkDirty uniq
        )
    )
    changed.count
)


/*---------------------------------------------------------------- handlers*/
fn mcpContextSections =
(
    local out = #()
    for d in mcpCtxDomains do append out d
    out
)

fn mcpH_context_get params =
(
    local requested = mcpArr params "sections"
    local since = mcpInt params "since" default:0
    local detail = toLower (mcpStr params "detail" default:"brief")
    local t0 = (timeStamp())

    local wanted = #()
    if requested.count > 0 then
    (
        for s in requested do
        (
            local name = if isKindOf s String then s else (try (s as string) catch (""))
            local known = if name != "" then ((mcpCtxDomainIndex name) > 0) else false
            if known then ( append wanted (toLower name) ) else ( if name != "" do mcpFail "err.bad_value" a1:name )
        )
    ) else ( wanted = mcpContextSections() )

    local sections = #()
    local built = #()
    local cached = #()
    local skipped = #()

    for d in wanted do
    (
        local idx = mcpCtxDomainIndex d
        local rev = mcpCtxRev[idx]
        -- `since` is the incremental switch: a domain whose last change predates
        -- the caller's cursor is not rebuilt and not sent.  The comparison is
        -- against the global-revision stamp, never against the per-domain cache
        -- key (see mcpCtxMarkDirty).
        local stamp = mcpCtxStamp[idx]
        if since > 0 and mcpCtxSent[idx] >= 0 and stamp <= since then ( append skipped d ) else
        (
            -- detail:"full" re-runs the section with wider caps; the cached
            -- brief copy is not reused on purpose (it is smaller).  The full
            -- build is never cached, so a brief caller is not handed 200 rows.
            local payload = undefined
            if detail == "full" and d == "selection" then ( payload = mcpCtxPayloadFull d detail; append built d ) else
            (
                local res = mcpCtxPayload d
                payload = res[1]
                if res[2] then append cached d else append built d
            )
            append sections #(d, payload)
            -- Remember that the caller now holds this domain at `stamp`.
            mcpCtxSent[idx] = stamp
        )
    )

    local mapPairs = #()
    for s in sections do mcpPair mapPairs s[1] s[2]

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "since" since
    mcpPair p "detail" detail
    mcpPair p "requested" wanted
    mcpPair p "built" built
    mcpPair p "cached" cached
    mcpPair p "unchanged" skipped
    mcpPair p "sections" (mcpObj mapPairs)
    mcpPair p "timingMs" ((timeStamp()) - t0)
    mcpPair p "availableSections" (mcpContextSections())
    mcpObj p
)

/* Detail="full" needs a wider selection row set.  Kept separate so the brief
   path never pays for it.  The result is still wrapped and still carries the
   live revision, it is only kept out of the cache because a 200-row dump is not
   what the next brief caller wants back. */
fn mcpCtxPayloadFull domain detail =
(
    local d = toLower (domain as string)
    local t0 = (timeStamp())
    -- Captured before the build so staleness is measured, not assumed.
    local revAtStart = mcpCtxRevFor d
    local payload = undefined
    local err = ""
    try (
        -- Single line on purpose: MAXScript closes `if ... then <expr>` at the
        -- end of the line, so `else` must not start the next one.
        payload = if d == "selection" then ( mcpCtxBuildSelection detail:"full" limit:200 ) else ( (mcpCtxPayload d)[1] )
    )
    catch ( err = mcpErrText (getCurrentException()) )

    if payload == undefined do
    (
        mcpCtxLastError = err
        payload = mcpObj #( #("valid", false), #("error", "context build failed: " + err) )
    )

    local ms = (timeStamp()) - t0
    if ms > mcpCtxSlowMs do mcpCtxSlowMs = ms
    mcpCtxWrap d revAtStart payload ms err stale:(mcpCtxRevFor d > revAtStart)
)

fn mcpH_context_refresh params =
(
    -- Measured, not sampled: mcpCtxLastFullScan is published as `lastRefreshMs`,
    -- so it has to be a duration.  It used to hold a bare timeStamp(), which is
    -- Max's uptime in ms - the stats page reported 32243072 ms for a refresh
    -- that took about 150.
    local t0 = (timeStamp())

    local domains = mcpArr params "sections"
    local targets = #()
    if domains.count > 0 then
    (
        for s in domains do
        (
            local name = if isKindOf s String then s else (try (s as string) catch (""))
            if name != "" and (mcpCtxDomainIndex name) > 0 do append targets (toLower name)
        )
    ) else ( targets = mcpContextSections() )

    -- Force: bump every requested domain so its cache entry is stale, then
    -- rebuild immediately instead of waiting for the next context_get.
    mcpCtxMarkDirty targets
    local rebuilt = #()
    for d in targets do
    (
        local res = mcpCtxPayload d
        append rebuilt d
    )
    mcpCtxLastFullScan = (timeStamp()) - t0

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "rebuilt" rebuilt
    mcpPair p "elapsedMs" mcpCtxLastFullScan
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_context_stats params =
(
    local stale = #()
    local revs = #()
    for i = 1 to mcpCtxDomains.count do
    (
        local entry = mcpCtxCachedEntry mcpCtxDomains[i]
        local anyEntry = mcpCtxAnyEntry mcpCtxDomains[i]
        local cached = entry != undefined
        -- `built` answers "has this domain ever been collected?", `cached`
        -- answers "is there a copy at the current revision?".  Conflating them
        -- was the other half of F2: a domain with an older snapshot reported
        -- the same thing as a domain nobody had ever asked for.
        local built = anyEntry != undefined
        if not cached do append stale mcpCtxDomains[i]

        -- The UI reads this row directly, so it carries the same provenance a
        -- section does instead of a single "cached" flag: an unbuilt domain is
        -- not the same thing as an invalid one, and neither is the same as one
        -- whose snapshot simply predates the latest change.
        local valid = cached
        local supported = true
        local updatedAt = ""
        local buildMs = 0
        local state = "unbuilt"
        local unreadable = #()
        if built do
        (
            -- `cached` false means there is no cache entry at the current
            -- revision, so `entry` is undefined here and `entry[3]` was an
            -- index into undefined: context_stats threw "Unknown property or
            -- index" on exactly the state it exists to describe (built once,
            -- then invalidated).  The fallback to the last snapshot was already
            -- written below, one line too late to be reached.
            local w = undefined
            if entry != undefined and (isKindOf entry Array) and entry.count >= 3 do w = entry[3]
            if w == undefined and anyEntry != undefined and (isKindOf anyEntry Array) and anyEntry.count >= 3 do w = anyEntry[3]
            if w != undefined do
            (
                valid = mcpToBool (mcpGet w "valid") fallback:true
                supported = mcpToBool (mcpGet w "supported") fallback:true
                try ( updatedAt = (mcpGet w "updatedAt") as string ) catch ( updatedAt = "" )
                try ( buildMs = (mcpGet w "buildMs") as integer ) catch ( buildMs = 0 )
                try
                (
                    local raw = mcpGet w "unreadable"
                    if isKindOf raw Array do unreadable = raw
                )
                catch()
                try ( state = (mcpGet w "state") as string ) catch ( state = "" )
                if state == "" do
                (
                    -- Bridge older than the state field: derive the same word so
                    -- a mixed install still reports one vocabulary.
                    local staleFlag = mcpToBool (mcpGet w "stale") fallback:false
                    state = mcpCtxState "" supported staleFlag unreadable
                )
            )
            -- An older snapshot is stale whatever it said when it was built, and
            -- a built domain with nothing to read is still not a fresh one.
            if not cached do state = "stale"
        )

        local row = #()
        mcpPair row "domain" mcpCtxDomains[i]
        mcpPair row "revision" mcpCtxRev[i]
        -- The global revision at which this domain last changed.  `since` takes
        -- one of these values, not a per-domain cache key.
        mcpPair row "changedAt" mcpCtxStamp[i]
        mcpPair row "sentAt" mcpCtxSent[i]
        mcpPair row "built" built
        mcpPair row "cached" cached
        mcpPair row "valid" valid
        mcpPair row "supported" supported
        mcpPair row "stale" (not cached)
        mcpPair row "state" state
        mcpPair row "unreadable" unreadable
        mcpPair row "updatedAt" updatedAt
        mcpPair row "buildMs" buildMs
        append revs (mcpObj row)
    )

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "events" (if mcpEvSeq == undefined then 0 else mcpEvSeq)
    mcpPair p "eventsRunning" (if mcpEvRunning == undefined then false else mcpEvRunning)
    mcpPair p "domains" revs
    mcpPair p "stale" stale
    mcpPair p "cachedSections" mcpCtxCache.count
    mcpPair p "builds" mcpCtxBuilds
    mcpPair p "slowestBuildMs" mcpCtxSlowMs
    mcpPair p "lastRefreshMs" mcpCtxLastFullScan
    mcpPair p "lastError" mcpCtxLastError
    mcpPair p "tickCount" mcpCtxTickCount
    mcpPair p "sinceContract" "pass the returned `revision` back as `since`; a section is skipped only when its changedAt <= since"
    mcpPair p "eventsCapabilities" (if mcpEventsCaps != undefined then (mcpEventsCaps()) else undefined)
    mcpObj p
)

fn mcpH_context_events params =
(
    mcpEventsLog limit:(mcpInt params "limit" default:50)
)

mcpRegister "context_get" mcpH_context_get undoable:false
mcpRegister "context_refresh" mcpH_context_refresh undoable:false
mcpRegister "context_stats" mcpH_context_stats undoable:false
mcpRegister "context_events" mcpH_context_events undoable:false

/* ==========================================================================
   SECTION: mcp_ui.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_ui.ms
   "Vino 3dsMax MCP" -- the in-Max client panel.

   Scope of this first version
   ---------------------------
   It is a *window onto real state*, not a simulation of it: every page is
   filled from the same handlers the MCP tools call (bridge status, context
   sections, event ledger, self test).  If a number is not available, the page
   says so instead of printing a plausible zero.

   Pages: Connection (bridge), Context (per-domain cache state), Events (ring
   buffer), Diagnostics (capabilities, registration failures, environment), then
   Scene / Selection / Assets as detail views.  The first four are counters only;
   the last three read the context cache and rebuild solely on Rebuild.

   Deliberately simple
   -------------------
   One dotNet TabControl with read-only text pages, and MAXScript buttons for
   the actions.  MAXScript rollout buttons are the well-trodden path; wiring
   every child control's events would add failure modes without adding data.
   Later phases can replace a page with a real tree without touching the
   collectors, because the collectors are the MCP handlers either way.

   Why createDialog and not a docked dialog bar
   --------------------------------------------
   createDialog is modeless and returns immediately, so opening the panel from
   a bridge command cannot deadlock the pump.  cui.RegisterDialogBar is probed
   at open time and only used when this release has it; the panel never depends
   on being dockable.
-----------------------------------------------------------------------------*/

global mcpUiRollout, mcpUiDialog, mcpUiPages, mcpUiTab, mcpUiCurrent, mcpUiCrlf
global mcpUiOpen, mcpUiClose, mcpUiRefresh, mcpUiPretty, mcpUiPageText, mcpUiLogPath
global mcpUiPad, mcpUiRow, mcpUiDomainText, mcpUiCrlf, mcpUiPageNames
global mcpUiBridgeUp, mcpUiBridgeStart, mcpUiBridgeNote
global mcpRunning, mcpListener, mcpTimer, mcpHost, mcpPort, mcpConns
global mcpH_client_ui, mcpH_client_status

if mcpUiPages == undefined do mcpUiPages = #()
if mcpUiCurrent == undefined do mcpUiCurrent = 1

fn mcpUiLogPath =
(
    local p = ""
    try ( p = mcpBridgeLogPath() ) catch ( p = "" )
    if p == undefined then "" else p
)

/* Readable rendering of the pair objects the bridge uses.  Compact JSON is
   what mcpJsonStringify produces; a panel wants one field per line, so this
   walks the same structure with an indent and a depth cap. */
fn mcpUiPretty value indent:0 depth:0 =
(
    local pad = ""
    for i = 1 to indent do pad += "  "
    local out = ""

    if depth > 6 then return (pad + "..." + "\n")

    if mcpIsObj value then
    (
        local pairs = mcpPairs value
        if pairs.count == 0 do return (pad + "{}" + "\n")
        for p in pairs do
        (
            local v = p[2]
            if mcpIsObj v then
            (
                out += pad + (p[1] as string) + ":" + "\n"
                out += (mcpUiPretty v indent:(indent + 1) depth:(depth + 1))
            )
            else if isKindOf v Array then
            (
                if v.count == 0 then out += pad + (p[1] as string) + ": []" + "\n"
                else
                (
                    local simple = true
                    for e in v do ( if isKindOf e Array then simple = false )
                    if simple then
                    (
                        local line = ""
                        local n = 0
                        for e in v do
                        (
                            n += 1
                            if n > 12 do exit
                            local t = if e == undefined then "null" else (e as string)
                            line += t + (if n < v.count and n < 12 then ", " else "")
                        )
                        if v.count > 12 do line += " ... (" + (v.count as string) + ")"
                        out += pad + (p[1] as string) + ": " + line + "\n"
                    )
                    else
                    (
                        out += pad + (p[1] as string) + ": (" + (v.count as string) + ")" + "\n"
                        local n = 0
                        for e in v do
                        (
                            n += 1
                            if n <= 20 do out += (mcpUiPretty e indent:(indent + 2) depth:(depth + 1))
                        )
                    )
                )
            )
            else
            (
                local t = if v == undefined then "null" else (v as string)
                out += pad + (p[1] as string) + ": " + t + "\n"
            )
        )
    )
    else if isKindOf value Array then
    (
        for e in value do out += (mcpUiPretty e indent:indent depth:(depth + 1))
    )
    else out += pad + ((value as string) + "\n")
    out
)

/*------------------------------ page helpers*/
/* One list, two consumers (the tab control and client_status), so a rename can
   never leave the tool reporting a page the panel does not have. */
fn mcpUiPageNames =
(
    -- The four the client contract names come first; the last three are detail
    -- views backed by the context cache.
    #("Connection", "Context", "Events", "Diagnostics", "Scene", "Selection", "Assets")
)
fn mcpUiPad s width =
(
    local t = s as string
    while t.count < width do t += " "
    t
)

fn mcpUiRow cells widths =
(
    local line = ""
    for i = 1 to cells.count do line += (mcpUiPad cells[i] widths[i])
    line
)

/* Detail pages read whatever the context cache already holds.  Only an explicit
   Rebuild is allowed to walk the scene graph, so refreshing the panel while a
   large scene is open costs nothing: pages 1-4 are counters only, 5-7 are a
   cache lookup. */
fn mcpUiDomainText domain force:false =
(
    if force then
    (
        local res = mcpCtxPayload domain
        return (mcpUiPretty res[1])
    )

    local cur = mcpCtxCachedEntry domain
    if cur != undefined do return (mcpUiPretty cur[3])

    -- Nothing built for the current revision.  Showing the previous snapshot
    -- beats an empty page, but only with the staleness stated in the first
    -- line: silent stale data is the failure mode this module exists to avoid.
    local old = mcpCtxAnyEntry domain
    if old == undefined then
        return ("(never built - press Rebuild)" + "\n")
    local head = "STALE SNAPSHOT  revision " + (old[2] as string)
    head += ", current " + ((mcpCtxRevFor domain) as string)
    head += ", built " + ((mcpGet old[3] "updatedAt") as string) + "\n"
    head += "(the values below describe that snapshot, not the live scene)" + "\n"
    head + (mcpUiPretty old[3])
)

/* One page = one live query.  Any failure becomes text in the page: the panel
   is a diagnostic tool, so it must be able to report a broken bridge instead
   of going blank. */
fn mcpUiPageText index force:false =
(
    local text = ""
    local t0 = (timeStamp())
    try
    (
        case index of
        (
            1:
            (
                text += "Connection" + "\n"
                text += "----------------------------------------" + "\n"
                -- Rendered field by field instead of through mcpUiPretty: the
                -- `product` member is a raw 9-element version array string and
                -- reads as a defect in a panel, while year/major/build already
                -- say the same thing.
                local st = mcpH_bridge_status #()
                for p in (mcpPairs st) do
                (
                    local k = p[1] as string
                    if k == "maxVersion" and mcpIsObj p[2] then
                    (
                        local parts = ""
                        for q in (mcpPairs p[2]) do
                        (
                            local qk = q[1] as string
                            if qk != "product" do parts += qk + "=" + (q[2] as string) + "  "
                        )
                        text += "maxVersion: " + parts + "\n"
                    )
                    else if k == "maxVersion" then text += "maxVersion: " + (p[2] as string) + "\n"
                    else text += (mcpUiPretty (mcpObj #(p)) indent:0 depth:0)
                )
                text += "\n" + "Events" + "\n"
                text += (mcpUiPretty (mcpEventsStatus()))
                -- The bridge cannot be restarted from outside Max, so point at
                -- the one control inside Max that can do it.
                text += "\n" + "If running or timerActive reads false, no client can reach Max." + "\n"
                text += "Press the Start bridge button below to bring the listener back." + "\n"
            )
            2:
            (
                text += "Context" + "\n"
                text += "----------------------------------------" + "\n"
                local st = mcpH_context_stats #()
                text += "revision   : " + ((mcpGet st "revision") as string) + "\n"
                text += "tickCount  : " + ((mcpGet st "tickCount") as string) + "\n"
                text += "events     : " + ((mcpGet st "events") as string) + "   running=" + ((mcpGet st "eventsRunning") as string) + "\n"
                text += "builds     : " + ((mcpGet st "builds") as string) + "   slowest=" + ((mcpGet st "slowestBuildMs") as string) + " ms" + "\n"
                local le = mcpGet st "lastError"
                local leText = "-"
                if le != undefined and le != "" do leText = le as string
                text += "lastError  : " + leText + "\n"
                text += "\n"
                text += (mcpUiRow #("domain", "rev", "state", "valid", "stale", "sup", "ms", "updatedAt") #(11, 5, 11, 7, 7, 6, 5, 0)) + "\n"
                text += "--------------------------------------------------" + "\n"
                for d in (mcpGet st "domains") do
                (
                    -- `state` is the word that separates "never built" from
                    -- "the read failed"; reading an absent field would raise on
                    -- an older bridge, so it is fetched defensively.
                    local stText = ""
                    local rawState = mcpGet d "state"
                    if rawState != undefined do ( try ( stText = rawState as string ) catch ( stText = "" ) )
                    local cells = #()
                    append cells ((mcpGet d "domain") as string)
                    append cells ((mcpGet d "revision") as string)
                    append cells stText
                    append cells ((mcpGet d "valid") as string)
                    append cells ((mcpGet d "stale") as string)
                    append cells ((mcpGet d "supported") as string)
                    append cells ((mcpGet d "buildMs") as string)
                    append cells ((mcpGet d "updatedAt") as string)
                    text += (mcpUiRow cells #(11, 5, 11, 7, 7, 6, 5, 0)) + "\n"
                )
                text += "\n" + "state: fresh / partial / stale / unsupported / failed / unbuilt." + "\n"
                text += "stale=true: cached copy is older than the domain revision." + "\n"
            )
            3:
            (
                text += "Events" + "\n"
                text += "----------------------------------------" + "\n"
                -- mcpEventsLog returns an object (count/total/revision/events),
                -- not a bare array; the rows live under "events", newest first.
                local log = mcpEventsLog limit:40
                local rows = mcpGet log "events"
                text += "total recorded : " + ((mcpGet log "total") as string) + "   revision: " + ((mcpGet log "revision") as string) + "\n"
                text += "\n"
                text += (mcpUiRow #("seq", "at", "event", "domains", "detail") #(5, 10, 12, 26, 0)) + "\n"
                text += "------------------------------------------------------------" + "\n"
                if rows.count == 0 do text += "(no events recorded yet)" + "\n"
                for r in rows do
                (
                    local dom = mcpGet r "domains"
                    local domText = ""
                    if isKindOf dom Array do ( for x in dom do domText += (x as string) + " " )
                    local det = mcpGet r "detail"
                    local cells = #()
                    append cells ((mcpGet r "seq") as string)
                    append cells ((mcpGet r "at") as string)
                    append cells ((mcpGet r "event") as string)
                    append cells domText
                    if det != undefined do append cells (det as string)
                    text += (mcpUiRow cells #(5, 10, 12, 26, 0)) + "\n"
                )
            )
            4:
            (
                text += "Diagnostics" + "\n"
                text += "----------------------------------------" + "\n"
                local caps = mcpEventsCaps()
                local reg = mcpGet caps "registered"
                local miss = mcpGet caps "unavailableHere"
                local probe = mcpGet caps "alsoAvailable"
                text += "notifications registered : " + (reg.count as string) + "\n"
                local missText = "none"
                if miss.count > 0 do missText = mcpStringJoin miss ", "
                text += "unavailable here         : " + missText + "\n"
                if probe.count > 0 do text += "probe-only available     : " + (mcpStringJoin probe ", ") + "\n"

                -- Split by intent.  A probe that this build rejects is the
                -- probe working correctly, not a failure; listing 18 of those
                -- under "failures" would make a healthy bridge look broken.
                local wantedFail = #()
                local rejected = #()
                for c in mcpEvCaps do
                (
                    local kind = c[3]
                    local ok = c[2]
                    if (not ok) and kind == "wanted" do append wantedFail c
                    if (not ok) and kind == "probe" do append rejected c[1]
                )
                local rejectedCount = 0
                for c in mcpEvCaps do ( if (not c[2]) and c[3] == "probe" do rejectedCount += 1 )
                text += "rejected by this build   : " + (rejectedCount as string) + " (probed, then removed)" + "\n"

                text += "\n" + "Registration failures" + "\n"
                text += "(a wanted notification that did not register is a real gap)" + "\n"
                local bad = 0
                for c in wantedFail do
                (
                    bad += 1
                    text += "  " + (c[1] as string) + ": " + (c[4] as string) + "\n"
                )
                for c in mcpEvCaps do
                (
                    if (not c[2]) and c[3] == "node" do
                    (
                        bad += 1
                        text += "  " + (c[1] as string) + ": " + (c[4] as string) + "\n"
                    )
                )
                if bad == 0 do text += "  none" + "\n"

                text += "\n" + "Rejected probes (expected on this release)" + "\n"
                if rejected.count == 0 then
                (
                    text += "  none" + "\n"
                )
                else
                (
                    local line = "  "
                    for n in rejected do line += (n as string) + " "
                    text += line + "\n"
                )
                text += "\n" + "Environment" + "\n"
                text += "  log        : " + (mcpUiLogPath()) + "\n"
                text += "  bridge dir : " + (try ((MCP_BRIDGE_DIR as string)) catch ("?")) + "\n"
                text += "  modules    : " + (mcpBridgeModules.count as string) + "\n"
                text += "  handlers   : " + (mcpRegistry.count as string) + "\n"
                text += "  port       : " + (mcpPort as string) + "\n"
                text += "  3ds Max    : " + ((mcpMaxYear()) as string) + "\n"
                text += "\n" + "Install / repair / uninstall are shell commands:" + "\n"
                text += "  python scripts/install.py --list" + "\n"
                text += "  python scripts/install.py --client cursor" + "\n"
                text += "  python scripts/doctor.py" + "\n"
                if force and mcpSelfTest != undefined then
                (
                    text += "\n" + "In-Max self test" + "\n"
                    text += "----------------------------------------" + "\n"
                    text += (mcpUiPretty (mcpSelfTest()))
                )
                else if force then
                (
                    text += "\n" + "(self test module not loaded)" + "\n"
                )
            )
            5:
            (
                text += "Scene" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiDomainText "scene" force:force)
                text += "\n" + "Objects" + "\n" + (mcpUiDomainText "objects" force:force)
                text += "\n" + "Project" + "\n" + (mcpUiDomainText "project" force:force)
            )
            6:
            (
                text += "Selection" + "\n"
                text += "----------------------------------------" + "\n"
                if force then
                (
                    text += (mcpUiPretty (mcpCtxBuildSelection detail:"full" limit:20))
                )
                else
                (
                    text += (mcpUiDomainText "selection" force:false)
                )
            )
            7:
            (
                text += "Assets" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiDomainText "materials" force:force)
                text += "\n" + "Files" + "\n" + (mcpUiDomainText "assets" force:force)
            )
            default: text += "no page" + "\n"
        )
    )
    catch ( text += "PAGE ERROR: " + (mcpErrText (getCurrentException())) + "\n" )
    text += "\n" + "(" + (((timeStamp()) - t0) as string) + " ms)" + "\n"
    text
)

/* WinForms TextBox does not break lines on a lone LF: it renders the page as
   one wrapped paragraph with the newlines swallowed (measured on the running
   build - the text held char 10 between rows and still displayed as a single
   line).  MAXScript builds strings with "\n", so normalise to CRLF on the way
   into the control and leave the formatters readable. */
fn mcpUiCrlf s =
(
    local out = ""
    local prev = ""
    for i = 1 to s.count do
    (
        local c = s[i]
        if c == "\n" then
        (
            if prev != "\r" do out += "\r\n"
        )
        else out += c
        prev = c
    )
    out
)

/* force:false is the contract for the Refresh button: read what the context
   already holds and never rebuild.  Panels that silently re-scan the scene are
   how a 25 ms pump turns into a stutter. */
fn mcpUiRefresh force:false =
(
    if mcpUiDialog == undefined then return false

    -- Rebuild warms the detail domains before the status pages are rendered,
    -- so the Context table reports the state the rebuild produced instead of
    -- the state just before it (where every domain reads stale).
    local detail = #()
    if force then
    (
        -- Rebuild means every domain, not only the ones with a tab: the
        -- Context table lists nine of them, and leaving four permanently
        -- "stale" because no page happens to read them would be a lie about
        -- the cache.  Measured cost on the 65-object scene: ~80 ms.
        try ( mcpH_context_refresh #() ) catch()
        for i = 5 to mcpUiPages.count do append detail (mcpUiPageText i force:true)
    )

    for i = 1 to mcpUiPages.count do
    (
        local src = 0
        if force do src = i - 4
        local txt = undefined
        if src >= 1 and src <= detail.count do txt = detail[src]
        if txt == undefined do txt = mcpUiPageText i force:false
        try ( mcpUiPages[i].Text = (mcpUiCrlf txt) ) catch()
    )
    true
)

/*------------------------------ bridge recovery
   The bridge is the only channel a client has into Max, so `bridge_stop` is a
   one-way door: the command that would restart it has to travel over the
   socket it just closed, and `bridge_restart` therefore never arrives.  The
   panel lives inside Max, so it is the one place that can still call
   mcpNetStart after the listener is gone.

   It only ever starts or restarts.  There is deliberately no Stop here: a
   panel button that can close the last door, one mis-click wide, is how the
   door got closed in the first place. */

fn mcpUiBridgeUp =
(
    (mcpRunning == true) and (mcpListener != undefined) and (mcpTimer != undefined)
)

fn mcpUiBridgeNote =
(
    -- Both branches are parenthesised blocks on purpose.  A bare `then <expr>`
    -- followed by `else` on the next line does not parse.
    if not (mcpUiBridgeUp()) then
    (
        "bridge is DOWN - no client can reach Max (press Start bridge)"
    )
    else
    (
        local note = "listening on " + (mcpHost as string) + ":" + (mcpPort as string)
        local n = 0
        if mcpConns != undefined do n = mcpConns.count
        note += "   clients=" + (n as string)
        note
    )
)

/* Returns the note string plus whether the pump came up.  mcpNetStart throws
   on a bind failure, and a listener without a pump is just as dead as no
   listener at all, so both are reported rather than treated as success. */
fn mcpUiBridgeStart =
(
    local res = #(false, "")
    local p = undefined
    try ( p = mcpNetStart() )
    catch
    (
        res[2] = "start failed: " + (mcpErrText (getCurrentException()))
        return res
    )
    local timerOk = false
    if p != undefined do timerOk = mcpToBool (mcpGet p "timer") fallback:false
    res[1] = timerOk
    if timerOk then
    (
        res[2] = mcpUiBridgeNote()
    )
    else
    (
        res[2] = "listener is up but the 25 ms pump did not start"
    )
    res
)

rollout mcpUiRollout "Vino 3dsMax MCP" width:470 height:582
(
    dotNetControl tab "System.Windows.Forms.TabControl" pos:[6,6] width:458 height:500

    button btnRefresh "Refresh" pos:[6,512] width:86 height:26
    button btnRebuild "Rebuild" pos:[96,512] width:82 height:26
    button btnCopy "Copy page" pos:[182,512] width:86 height:26
    button btnLog "Open log" pos:[272,512] width:90 height:26
    button btnClose "Close" pos:[418,512] width:46 height:26

    button btnBridge "Start bridge" pos:[6,542] width:120 height:26
    label lblBridge "" pos:[134,546] width:330 height:20

    fn buildPages =
    (
        mcpUiPages = #()
        local names = mcpUiPageNames()
        try ( tab.TabPages.Clear() ) catch()
        for n in names do
        (
            local page = dotNetObject "System.Windows.Forms.TabPage" n
            local box = dotNetObject "System.Windows.Forms.TextBox"
            box.Multiline = true
            box.ReadOnly = true
            box.WordWrap = false
            box.ScrollBars = (dotNetClass "System.Windows.Forms.ScrollBars").Both
            box.Dock = (dotNetClass "System.Windows.Forms.DockStyle").Fill
            -- Match the Max dark theme; a white text box in a dark rollout
            -- reads as a bug.
            box.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 43 43 46
            box.ForeColor = (dotNetClass "System.Drawing.Color").FromArgb 222 222 222
            try ( box.Font = dotNetObject "System.Drawing.Font" "Consolas" 9 ) catch()
            page.Controls.Add box
            tab.TabPages.Add page
            append mcpUiPages box
        )
    )

    fn syncBridge =
    (
        if mcpUiBridgeUp() then
        (
            btnBridge.text = "Restart bridge"
        )
        else
        (
            btnBridge.text = "Start bridge"
        )
        try ( lblBridge.text = mcpUiBridgeNote() ) catch()
    )

    on mcpUiRollout open do
    (
        buildPages()
        mcpUiDialog = true
        syncBridge()
        -- Opening the panel is an explicit user action, so the first fill is
        -- allowed to build the detail domains once.  Every later Refresh reads
        -- the cache; Rebuild is the only thing that walks the scene again.
        mcpUiRefresh force:true
    )

    on btnBridge pressed do
    (
        local wasUp = mcpUiBridgeUp()
        local res = mcpUiBridgeStart()
        -- A restart invalidates every open client socket, so re-read the pages
        -- rather than leave Connection showing the state from before the click.
        syncBridge()
        local note = res[2]
        if wasUp then note = "restarted - " + note
        try ( lblBridge.text = note ) catch()
        mcpUiRefresh force:false
    )

    on btnRefresh pressed do ( mcpUiRefresh force:false )

    on btnRebuild pressed do ( mcpUiRefresh force:true )

    on btnCopy pressed do
    (
        if mcpUiPages.count > 0 do
        (
            local idx = 1
            try ( idx = tab.SelectedIndex + 1 ) catch ( idx = 1 )
            if idx >= 1 and idx <= mcpUiPages.count do
            (
                try ( setClipboardText mcpUiPages[idx].Text ) catch()
            )
        )
    )

    on btnLog pressed do
    (
        local p = mcpUiLogPath()
        if p != "" do ( try ( shellLaunch p "" ) catch() )
    )

    on btnClose pressed do ( destroyDialog mcpUiRollout )
)

fn mcpUiOpen =
(
    if mcpUiDialog == true do
    (
        try ( destroyDialog mcpUiRollout ) catch()
        mcpUiDialog = undefined
    )
    try ( createDialog mcpUiRollout ) catch ( return false )
    mcpUiDialog = true
    mcpUiRefresh force:true
    true
)

fn mcpUiClose =
(
    try ( destroyDialog mcpUiRollout ) catch()
    mcpUiDialog = undefined
    true
)

/* Tool entry points.  Both are read-only, so they are registered with
   undoable:false and never enter an undo hold. */
fn mcpH_client_ui params =
(
    local action = toLower (mcpStr params "action" default:"open")
    local opened = true
    if action == "close" then opened = mcpUiClose()
    -- Cache only: a refresh driven from a tool call must never make the
    -- panel re-walk the scene.  context_refresh is the forcing call.
    else if action == "refresh" then opened = mcpUiRefresh force:false
    else opened = mcpUiOpen()

    local p = #()
    mcpPair p "action" action
    mcpPair p "open" (mcpUiDialog == true)
    mcpPair p "pages" mcpUiPages.count
    mcpPair p "ok" opened
    mcpPair p "logPath" (mcpUiLogPath())
    mcpObj p
)

fn mcpH_client_status params =
(
    local p = #()
    mcpPair p "open" (mcpUiDialog == true)
    mcpPair p "pages" mcpUiPages.count
    mcpPair p "pageNames" (mcpUiPageNames())
    mcpPair p "eventsRunning" (if mcpEvRunning == undefined then false else mcpEvRunning)
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "logPath" (mcpUiLogPath())
    mcpPair p "bridgeDir" (try ((MCP_BRIDGE_DIR as string)) catch ("?"))
    mcpObj p
)

-- Toolbar / quad menu entry.  macroScript with a category makes it reachable
-- from Customize > Customize User Interface without shipping a .mcr file.
macroScript Vino3dsMaxMCP
category:"Vino"
buttonText:"Vino MCP"
toolTip:"Open the Vino 3dsMax MCP client panel"
(
    on execute do ( mcpUiOpen() )
)

mcpRegister "client_ui" mcpH_client_ui undoable:false
mcpRegister "client_status" mcpH_client_status undoable:false
