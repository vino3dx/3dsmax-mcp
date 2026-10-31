(
    local p = @"D:\Workspace\MCP\3dsmax-mcp\test\max\gundam_canyon_battlefield_v2.max"
    local ok = loadMaxFile p useFileUnits:true quiet:true
    format "loaded:% objects:% scene:%\n" ok objects.count (maxFileName)
)
