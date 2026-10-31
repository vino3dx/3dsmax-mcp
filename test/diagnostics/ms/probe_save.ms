-- Minimal reproduction: does saveMaxFile itself damage the scene?
-- Read-only with respect to the original file; writes only to a scratch path.
(
    local src  = @"D:\Workspace\MCP\3dsmax-mcp\test\max\gundam_canyon_battlefield.max"
    local tmp  = @"D:\Workspace\MCP\3dsmax-mcp\test\max\_probe_save.max"
    local log  = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\save_probe.txt"

    deleteFile log
    local f = createFile log

    loadMaxFile src useFileUnits:true quiet:true
    format "after_load\t%\n" objects.count to:f

    -- step 1: save to a scratch file
    local ok1 = saveMaxFile tmp
    format "after_save\t%\tsaved:%\n" objects.count ok1 to:f

    -- step 2: save again (idempotent?)
    local ok2 = saveMaxFile tmp
    format "after_save2\t%\tsaved:%\n" objects.count ok2 to:f

    -- step 3: reload the original and confirm we can restore
    loadMaxFile src useFileUnits:true quiet:true
    format "after_reload\t%\n" objects.count to:f
    close f
    "probe done"
)
