/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_ui.ms
   "Vino 3dsMax MCP" -- the in-Max client panel.

   Scope of this first version
   ---------------------------
   It is a *window onto real state*, not a simulation of it: every page is
   filled from the same handlers the MCP tools call (bridge status, context
   sections, event ledger, self test).  If a number is not available, the page
   says so instead of printing a plausible zero.

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

/* One page = one live query.  Any failure becomes text in the page: the panel
   is a diagnostic tool, so it must be able to report a broken bridge instead
   of going blank. */
fn mcpUiPageText index =
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
                text += "Scene" + "\n"
                text += "----------------------------------------" + "\n"
                local res = mcpCtxPayload "scene"
                text += (mcpUiPretty res[1])
                text += "\n" + "Objects" + "\n"
                text += (mcpUiPretty (mcpCtxPayload "objects")[1])
                text += "\n" + "Project" + "\n"
                text += (mcpUiPretty (mcpCtxPayload "project")[1])
            )
            3:
            (
                text += "Selection" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiPretty (mcpCtxBuildSelection detail:"full" limit:20))
            )
            4:
            (
                text += "Materials" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiPretty (mcpCtxPayload "materials")[1])
                text += "\n" + "Assets" + "\n"
                text += (mcpUiPretty (mcpCtxPayload "assets")[1])
            )
            5:
            (
                text += "Monitor" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiPretty (mcpH_context_stats #()))
                text += "\n" + "Recent events" + "\n"
                text += (mcpUiPretty (mcpEventsLog limit:20))
            )
            6:
            (
                text += "Maintenance" + "\n"
                text += "----------------------------------------" + "\n"
                text += "bridge log : " + (mcpUiLogPath()) + "\n"
                text += "bridge dir : " + (try ((MCP_BRIDGE_DIR as string)) catch ("?")) + "\n"
                text += "modules    : " + (mcpBridgeModules.count as string) + "\n"
                text += "handlers   : " + (mcpRegistry.count as string) + "\n"
                text += "port       : " + (mcpPort as string) + "\n"
                text += "3ds Max    : " + (mcpMaxYear()) + "\n"
                text += "\n"
                text += "Install / repair / uninstall are done from a shell:" + "\n"
                text += "  python scripts/install.py --list" + "\n"
                text += "  python scripts/install.py --client cursor" + "\n"
                text += "  python scripts/doctor.py" + "\n"
                text += "\n" + "In-Max self test" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiPretty (mcpSelfTest()))
            )
            7:
            (
                text += "Recent commands and errors" + "\n"
                text += "----------------------------------------" + "\n"
                text += (mcpUiPretty (mcpEventsLog limit:60))
                text += "\n" + "Log file" + "\n"
                text += (mcpUiLogPath()) + "\n"
            )
            default: text += "no page" + "\n"
        )
    )
    catch ( text += "PAGE ERROR: " + (getCurrentException() as string) + "\n" )
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

fn mcpUiRefresh =
(
    if mcpUiDialog == undefined then return false
    for i = 1 to mcpUiPages.count do
    (
        try ( mcpUiPages[i].Text = (mcpUiCrlf (mcpUiPageText i)) )
        catch()
    )
    true
)

rollout mcpUiRollout "Vino 3dsMax MCP" width:470 height:560
(
    dotNetControl tab "System.Windows.Forms.TabControl" pos:[6,6] width:458 height:500

    button btnRefresh "Refresh" pos:[6,512] width:96 height:26
    button btnCopy "Copy page" pos:[108,512] width:96 height:26
    button btnLog "Open log" pos:[210,512] width:96 height:26
    button btnClose "Close" pos:[418,512] width:46 height:26

    fn buildPages =
    (
        mcpUiPages = #()
        local names = #("Connection", "Scene", "Selection", "Assets", "Monitor", "Maintenance", "Log")
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
        mcpUiRefresh()
    )

    on btnRefresh pressed do ( mcpUiRefresh() )

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
    mcpUiRefresh()
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
    else if action == "refresh" then opened = mcpUiRefresh()
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
