(
    local out = @"D:\Workspace\MCP\3dsmax-mcp\test\logs\state_check.tsv"
    local f = createFile out
    format "OBJCOUNT\t%\n" objects.count to:f
    format "SCENE\t%\n" maxFileName to:f
    for o in objects do format "OBJ\t%\t%\t%\n" o.name ((superClassOf o) as string) ((classOf o) as string) to:f
    close f
    "state written"
)
