/* Workaround for viewport_capture: gw.getViewportDib() returns a DIB with no
   filename, and `save bmp path` raises "Bitmap requires a fileName for save()".
   Assigning bmp.filename first then calling save works. */
(
    local path = @"D:\Workspace\MCP\3dsmax-mcp\test\max\_valley\preview_terrain.png"

    local cam = getNodeByName "CAM_Main"
    if cam != undefined then
    (
        try ( viewport.setCamera cam ) catch()
        try ( viewport.setRenderLevel #smoothhighlights ) catch()
        try ( viewport.setShowEdgeFaces false ) catch()
    )

    local bmp = undefined
    try ( bmp = gw.getViewportDib() ) catch ( bmp = undefined )
    local ok = false
    if bmp != undefined do
    (
        try
        (
            bmp.filename = path
            save bmp
            ok = doesFileExist path
        )
        catch ( ok = false )
    )
    "capture ok=" + (ok as string) + " " + (try ((bmp.width as string) + "x" + (bmp.height as string)) catch "-")
)
