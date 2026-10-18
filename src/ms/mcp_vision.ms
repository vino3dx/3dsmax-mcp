/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_vision.ms

   Visual feedback.  Three commands that let the caller SEE the scene instead of
   guessing from JSON: a viewport grab, a multi-view orthographic sweep, and a
   cheap render preview.

   Why this module exists
   ----------------------
   3D work is a visual loop.  "Create a box" is not verified by a JSON reply that
   says ok:true - it is verified by looking at the box.  Without pixels the model
   is working blind and will happily report success on a scene it never saw.
   A file path is not enough either: an MCP client usually runs in another process
   or on another machine, so C:\Users\...\shot.png is unreachable to it.

   Result shape
   ------------
   Every command returns its pixels as base64 inside a top-level "_images" array:

       {
         "count": 1,
         "max_edge": 800,
         "message": "ok",
         "_images": [
           ["label", "front", "data", "<base64>", "mime", "image/jpeg"]
         ]
       }

   The Python layer splits "_images" out into real MCP image content blocks, so
   the caller receives pictures, not paths.  Anything else in the result stays
   ordinary JSON and is rendered as a text block.

   Payload budget
   --------------
   MAXScript string concatenation degrades badly on very long strings.  A
   1920x1080 PNG becomes ~2 MB of base64 and would stall the bridge for minutes,
   so captures are downscaled to max_edge (default 800, hard cap 2048) and
   written as JPEG.  That lands around 30-90 KB per view.  Do not raise this
   without measuring.

   Re-entrancy
   -----------
   completeRedraw() pumps the Windows message queue, which can re-enter the
   bridge's WinForms timer while a command is still running.  mcpVisionBusy is
   set for the duration of every capture and mcp_net.ms checks it first thing in
   mcpNetPump, so a re-entrant tick becomes a no-op instead of a half-processed
   protocol frame.
-----------------------------------------------------------------------------*/

global mcpVisionBusy, mcpVisionMaxEdge
global mcpVisionScaleFile, mcpBmpToBase64, mcpVisionGrab, mcpVisionFit
global mcpVisionVpState, mcpVisionVpRestore, mcpVisionSetType
global mcpVisionImagePair, mcpH_vision_capture, mcpH_vision_views, mcpH_vision_preview
global mcpVisionSelfTest

mcpVisionBusy = false
mcpVisionMaxEdge = 800


/*--------------------------------------------------------------- small helpers*/
fn mcpVisionText zh en =
(
    if mcpLang == "en" then en else zh
)

-- A unique temp path.  A Guid printed with "as string" becomes the literal
-- "dotNetObject:System.Guid" -- the colon is not a legal path character and
-- .NET then refuses the file with "不支持给定路径的格式".  Use a formatted
-- timestamp plus a random tail instead: digits only, always path safe.
fn mcpVisionTempFile ext =
(
    local stamp = ""
    try
    (
        local now = (dotNetClass "System.DateTime").Now
        stamp = (now.ToString "yyyyMMddHHmmssfff") as string
    )
    catch ( stamp = "" )
    if stamp == "" do ( stamp = "0" )
    local uniq = 0
    try ( uniq = random 100000 999999 ) catch ( uniq = 0 )
    stamp = stamp + "_" + (uniq as string)

    local dir = ""
    try ( dir = getDir #temp ) catch ( dir = "" )
    if dir == "" do ( dir = "." )
    local sep = "\\"
    if (substring dir dir.count 1) == "\\" do ( sep = "" )
    dir + sep + "mcp_vision_" + stamp + ext
)

-- Downscale a saved image file so its longest edge is at most maxEdge.
-- MAXScript has no resampler (resizeBitmap does not exist in Max 2020 and
-- pasteBitmap only blits, it does not scale), so the resize is done by GDI+.
-- Returns true only when dstPath was written.
fn mcpVisionScaleFile srcPath dstPath maxEdge mime =
(
    local ok = false
    local img = undefined
    local nb = undefined
    local g = undefined
    try
    (
        img = (dotNetClass "System.Drawing.Image").FromFile srcPath
        local w = img.Width
        local h = img.Height
        local longest = if w > h then w else h
        local nw = w
        local nh = h
        if maxEdge > 0 and longest > maxEdge do
        (
            local k = (maxEdge as float) / (longest as float)
            nw = (floor (w * k)) as integer
            nh = (floor (h * k)) as integer
        )
        if nw < 1 do ( nw = 1 )
        if nh < 1 do ( nh = 1 )

        nb = dotNetObject "System.Drawing.Bitmap" nw nh
        g = (dotNetClass "System.Drawing.Graphics").FromImage nb
        try ( g.InterpolationMode = (dotNetClass "System.Drawing.Drawing2D.InterpolationMode").HighQualityBicubic ) catch()
        g.DrawImage img 0 0 nw nh

        local fmt = (dotNetClass "System.Drawing.Imaging.ImageFormat").Jpeg
        if mime == "image/png" do ( fmt = (dotNetClass "System.Drawing.Imaging.ImageFormat").Png )
        nb.Save dstPath fmt
        ok = true
    )
    catch ( ok = false )

    -- Dispose in dependency order; failures here must not change the result.
    try ( if g != undefined do g.Dispose() ) catch()
    try ( if nb != undefined do nb.Dispose() ) catch()
    try ( if img != undefined do img.Dispose() ) catch()
    ok
)

-- Save the bitmap to a temp file, optionally downscale it, read the bytes back
-- and base64 them.  Returns #(base64, width, height); base64 is "" on failure.
-- Base64 is pure ASCII, so it survives the wire codec in mcp_json.ms unchanged.
fn mcpBmpToBase64 bmp mime maxEdge:0 =
(
    if bmp == undefined do return #("", 0, 0)
    local ext = if mime == "image/png" then ".png" else ".jpg"
    local tmp = mcpVisionTempFile ext
    local scaled = ""
    local b64 = ""
    local outW = bmp.width
    local outH = bmp.height
    try
    (
        -- MAXScript's save() takes no file name: the bitmap has to carry one.
        -- save bmp tmp  raises "位图的 save() 操作需要 fileName".
        bmp.filename = tmp
        save bmp

        local src = tmp
        if maxEdge > 0 do
        (
            local longest = if outW > outH then outW else outH
            if longest > maxEdge do
            (
                scaled = mcpVisionTempFile ext
                if (mcpVisionScaleFile tmp scaled maxEdge mime) then
                (
                    src = scaled
                    local k = (maxEdge as float) / (longest as float)
                    outW = (floor (outW * k)) as integer
                    outH = (floor (outH * k)) as integer
                )
            )
        )

        if (doesFileExist src) and ((getFileSize src) > 0) do
        (
            local bytes = (dotNetClass "System.IO.File").ReadAllBytes src
            local s = (dotNetClass "System.Convert").ToBase64String bytes
            b64 = s as string
        )
    )
    catch ( b64 = "" )
    try ( if scaled != "" and (doesFileExist scaled) do deleteFile scaled ) catch()
    try ( if doesFileExist tmp do deleteFile tmp ) catch()
    #(b64, outW, outH)
)

-- One MCP image content block, in the exact shape the protocol expects:
-- ["type","image","data",<base64>,"mimeType",<mime>]
-- The "_images" array carries a label alongside it so the caller can tell which
-- view is which; the Python side moves label into the text block.
fn mcpVisionImagePair label b64 mime =
(
    local p = #()
    mcpPair p "label" label
    mcpPair p "data" b64
    mcpPair p "mime" mime
    mcpObj p
)


/*----------------------------------------------------------------- viewport IO*/
-- Grab the active viewport, downscale, encode.  Returns #(base64, width, height)
-- or undefined when the framebuffer could not be read.
fn mcpVisionGrab maxEdge:800 mime:"image/jpeg" =
(
    local bmp = undefined
    try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    if bmp == undefined do
    (
        -- Retry once after an explicit redraw: some drivers hand back an empty
        -- DIB when the viewport has not painted since the last scene change.
        try ( mcpRedraw() ) catch()
        try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    )
    if bmp == undefined do return undefined

    local r = mcpBmpToBase64 bmp mime maxEdge:maxEdge
    if r == undefined do return undefined
    if r[1] == "" do return undefined
    #(r[1], r[2], r[3])
)

fn mcpVisionFit =
(
    local ok = true
    try
    (
        actionMan.executeAction 0 "311"
    )
    catch
    (
        ok = false
        try ( actionMan.executeAction 0 "311" ) catch()
    )
    ok
)

-- Map a friendly view name onto a viewport type constant.
fn mcpVisionSetType viewName =
(
    local n = toLower (viewName as string)
    local t = undefined
    if n == "front" then t = #view_front
    else if n == "back" then t = #view_back
    else if n == "left" then t = #view_left
    else if n == "right" then t = #view_right
    else if n == "top" then t = #view_top
    else if n == "bottom" then t = #view_bottom
    else if n == "perspective" or n == "persp" then t = #view_persp_user
    else if n == "orthographic" or n == "ortho" then t = #view_iso_user
    else if n == "user" or n == "iso" then t = #view_user

    if t == undefined do return false
    local ok = true
    try ( viewport.setType t ) catch ( ok = false )
    ok
)

-- Snapshot enough of the active viewport to put it back afterwards.
fn mcpVisionVpState =
(
    local t = undefined
    local tm = undefined
    try ( t = viewport.getType() ) catch ( t = undefined )
    try ( tm = viewport.getTM() ) catch ( tm = undefined )
    #(t, tm)
)

fn mcpVisionVpRestore st =
(
    if st == undefined do return false
    local ok = true
    if st[1] != undefined do ( try ( viewport.setType st[1] ) catch ( ok = false ) )
    if st[2] != undefined do ( try ( viewport.setTM st[2] ) catch ( ok = false ) )
    try ( mcpRedraw() ) catch()
    ok
)


/*-------------------------------------------------------------------- handlers*/
fn mcpH_vision_capture params =
(
    local maxEdge = mcpInt params "max_edge" default:800
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 2048 do maxEdge = 2048

    local fmt = toLower (mcpStr params "format" default:"jpeg")
    local mime = if fmt == "png" then "image/png" else "image/jpeg"
    local doRedraw = mcpBool params "redraw" default:true
    local savePath = mcpStr params "path" default:""

    local grab = undefined
    mcpVisionBusy = true
    try
    (
        if doRedraw do mcpRedraw()
        grab = mcpVisionGrab maxEdge:maxEdge mime:mime
    )
    catch ( grab = undefined )
    mcpVisionBusy = false

    if grab == undefined do mcpFail "err.bad_value" a1:"viewport"

    -- Optional copy on disk, for the human who is sitting in front of Max.
    local written = ""
    if savePath != "" do
    (
        try
        (
            local dir = getFilenamePath savePath
            if dir != "" and not (doesDirectoryExist dir) do ( makeDir dir all:true )
            local bytes = (dotNetClass "System.Convert").FromBase64String grab[1]
            (dotNetClass "System.IO.File").WriteAllBytes savePath bytes
            if doesFileExist savePath do written = savePath
        )
        catch ( written = "" )
    )

    local p = #()
    mcpPair p "width" grab[2]
    mcpPair p "height" grab[3]
    mcpPair p "mime" mime
    mcpPair p "bytes" (grab[1].count)
    if written != "" do mcpPair p "path" written
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" #( (mcpVisionImagePair "active" grab[1] mime) )
    mcpObj p
)


fn mcpH_vision_views params =
(
    -- Which views to sweep.  Defaults to the four that describe a model best:
    -- one perspective for shape, three orthographic for proportion.
    local views = #()
    local raw = mcpArr params "views"
    if raw != undefined and (isKindOf raw Array) and raw.count > 0 then
    (
        for v in raw do append views (toLower (v as string))
    )
    else views = #("perspective", "front", "left", "top")

    -- Hard cap: each view is a separate image block and a separate redraw.
    if views.count > 6 do
    (
        local kept = #()
        for k = 1 to 6 do append kept views[k]
        views = kept
    )

    local maxEdge = mcpInt params "max_edge" default:800
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 2048 do maxEdge = 2048

    local fmt = toLower (mcpStr params "format" default:"jpeg")
    local mime = if fmt == "png" then "image/png" else "image/jpeg"
    local doFit = mcpBool params "fit" default:true
    local doRestore = mcpBool params "restore" default:true

    local st = mcpVisionVpState()
    local images = #()
    local meta = #()

    mcpVisionBusy = true
    try
    (
        for v in views do
        (
            local switched = mcpVisionSetType v
            if switched then
            (
                if doFit do mcpVisionFit()
                try ( mcpRedraw() ) catch()
                local grab = mcpVisionGrab maxEdge:maxEdge mime:mime
                if grab != undefined do
                (
                    append images (mcpVisionImagePair v grab[1] mime)
                    local mp = #()
                    mcpPair mp "view" v
                    mcpPair mp "width" grab[2]
                    mcpPair mp "height" grab[3]
                    append meta (mcpObj mp)
                )
            )
        )
    )
    catch()

    if doRestore do ( try ( mcpVisionVpRestore st ) catch() )
    mcpVisionBusy = false

    if images.count == 0 do
        mcpFail "err.bad_value" a1:"viewport"

    local p = #()
    mcpPair p "count" images.count
    mcpPair p "max_edge" maxEdge
    mcpPair p "views" meta
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" images
    mcpObj p
)


/*---------------------------------------------------------------- render preview
   Slower and renderer-dependent, but it shows real shading, real lights and
   real materials - the only way to verify look-dev.  Kept small on purpose:
   a preview at 640px and 1 sample is enough to answer "does this look right".
   Note that the first render after a scene change can take tens of seconds
   while shaders compile, which is why this is a separate command and not part
   of vision_capture.
------------------------------------------------------------------------------*/
fn mcpH_vision_preview params =
(
    local maxEdge = mcpInt params "max_edge" default:640
    if maxEdge < 64 do maxEdge = 64
    if maxEdge > 1600 do maxEdge = 1600

    local aspect = 4.0 / 3.0
    try
    (
        local rw = renderWidth
        local rh = renderHeight
        if rh > 0 do aspect = (rw as float) / (rh as float)
    )
    catch()

    local w = maxEdge
    local h = (floor (maxEdge / aspect)) as integer
    if h < 1 do h = 1

    local bmp = undefined
    local ok = true
    mcpVisionBusy = true
    try
    (
        bmp = bitmap w h
        render outputwidth:w outputheight:h to:bmp vfb:false
    )
    catch
    (
        ok = false
        bmp = undefined
    )
    mcpVisionBusy = false

    if not ok or bmp == undefined do
        mcpFail "err.bad_value" a1:"render"

    -- The render target is already at the requested size, so no rescale here.
    local r = mcpBmpToBase64 bmp "image/jpeg"
    if r == undefined do mcpFail "err.bad_value" a1:"render"
    if r[1] == "" do mcpFail "err.bad_value" a1:"render"

    local p = #()
    mcpPair p "width" r[2]
    mcpPair p "height" r[3]
    mcpPair p "mime" "image/jpeg"
    mcpPair p "bytes" r[1].count
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpPair p "_images" #( (mcpVisionImagePair "render" r[1] "image/jpeg") )
    mcpObj p
)


/*--------------------------------------------------------------- self test
   Runs without a client: fileIn this module, then mcpVisionSelfTest().
   It reports whether the framebuffer can be read and how big the payload is,
   which is the only way to tell a dead pipeline from a big one.
------------------------------------------------------------------------------*/
fn mcpVisionSelfTest =
(
    format "\n--- mcp_vision self test ---\n"
    local t0 = timestamp()
    local grab = undefined
    try ( grab = mcpVisionGrab maxEdge:800 mime:"image/jpeg" )
    catch ( format "  grab FAILED: %\n" (getCurrentException()) )
    local ms = timestamp() - t0
    if grab == undefined then
    (
        format "  viewport grab  : FAILED (no framebuffer)\n"
        false
    )
    else
    (
        format "  viewport grab  : OK  %x% px, % base64 chars, % ms\n" grab[2] grab[3] grab[1].count ms
        format "  est. wire bytes: %\n" grab[1].count
        true
    )
)


/*------------------------------------------------------------------- register*/

mcpRegister "vision_capture" mcpH_vision_capture undoable:false label:"Capture active viewport"
mcpRegister "vision_views" mcpH_vision_views undoable:false label:"Capture orthographic views"
mcpRegister "vision_preview" mcpH_vision_preview undoable:false label:"Render preview"

format "3ds Max MCP: vision module loaded (max_edge cap %, base64 image results enabled)\n" mcpVisionMaxEdge
