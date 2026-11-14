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
                text += (mcpUiRow #("domain", "rev", "valid", "stale", "sup", "ms", "updatedAt") #(11, 5, 7, 7, 6, 5, 0)) + "\n"
                text += "--------------------------------------------------" + "\n"
                for d in (mcpGet st "domains") do
                (
                    local cells = #()
                    append cells ((mcpGet d "domain") as string)
                    append cells ((mcpGet d "revision") as string)
                    append cells ((mcpGet d "valid") as string)
                    append cells ((mcpGet d "stale") as string)
                    append cells ((mcpGet d "supported") as string)
                    append cells ((mcpGet d "buildMs") as string)
                    append cells ((mcpGet d "updatedAt") as string)
                    text += (mcpUiRow cells #(11, 5, 7, 7, 6, 5, 0)) + "\n"
                )
                text += "\n" + "stale=true: cached copy is older than the domain revision." + "\n"
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

rollout mcpUiRollout "Vino 3dsMax MCP" width:470 height:560
(
    dotNetControl tab "System.Windows.Forms.TabControl" pos:[6,6] width:458 height:500

    button btnRefresh "Refresh" pos:[6,512] width:86 height:26
    button btnRebuild "Rebuild" pos:[96,512] width:82 height:26
    button btnCopy "Copy page" pos:[182,512] width:86 height:26
    button btnLog "Open log" pos:[272,512] width:90 height:26
    button btnClose "Close" pos:[418,512] width:46 height:26

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

    on mcpUiRollout open do
    (
        buildPages()
        mcpUiDialog = true
        -- Opening the panel is an explicit user action, so the first fill is
        -- allowed to build the detail domains once.  Every later Refresh reads
        -- the cache; Rebuild is the only thing that walks the scene again.
        mcpUiRefresh force:true
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
