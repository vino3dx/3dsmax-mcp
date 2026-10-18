/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_selftest.ms
   In-Max diagnostics.  Because the bridge deliberately avoids Python, structs
   and closures, the only meaningful way to prove the environment is healthy is
   to exercise it from inside Max.

   Call it from the Listener      : mcpSelfTest()
   Or through MCP                : bridge_selftest
-----------------------------------------------------------------------------*/

global mcpSelfTest, mcpH_bridge_selftest, mcpSelfTestLines

mcpSelfTestLines = #()

fn mcpStPush name ok detail =
(
    append mcpSelfTestLines (mcpObj #(#("check", name), #("ok", ok), #("detail", (detail as string))))
    ok
)

fn mcpSelfTest echoText:"" =
(
    mcpSelfTestLines = #()
    local checks = #()
    local failures = 0

    local stamp = mcpStPush "handlerRegistry" (mcpRegistry.count > 0) (mcpRegistry.count as string)
    if not stamp do failures += 1

    -- 1. object marker discrimination
    local o = mcpObj #(#("a", 1))
    local arr = #("a", 1)
    local ok1 = (mcpIsObj o) and (not (mcpIsObj arr)) and (not (mcpIsObj #())) and (not (mcpIsObj 5))
    if not (mcpStPush "jsonObjectMarker" ok1 ((mcpIsObj o) as string)) do failures += 1

    -- 2. JSON round trip incl. nesting
    local src = "{\"a\":1,\"b\":[1,2,3],\"c\":{\"d\":\"e\"},\"f\":true,\"g\":null,\"h\":1.5}"
    local parsed = mcpJsonParse src
    local hasBool = (mcpBool parsed "f" default:false) == true
    local hasNull = (mcpGet parsed "g") == undefined
    local ok2 = (mcpInt parsed "a" == 1) and ((mcpArr parsed "b").count == 3) and (mcpStr (mcpGet parsed "c") "d" == "e") and hasBool and hasNull and ((mcpNum parsed "h") == 1.5)
    if not (mcpStPush "jsonParse" ok2 src) do failures += 1

    local ok3 = false
    local detail3 = ""
    try (
        local again = mcpJsonStringify parsed
        local reparse = mcpJsonParse again
        ok3 = (mcpInt reparse "a" == 1) and ((mcpArr reparse "b").count == 3)
        detail3 = again
    ) catch ( detail3 = getCurrentException() )
    if not (mcpStPush "jsonStringify" ok3 detail3) do failures += 1

    -- 3. empty object / empty array
    local ok4 = (mcpObjCount (mcpJsonParse "{}") == 0) and ((mcpJsonParse "[]").count == 0)
    if not (mcpStPush "jsonEmpty" ok4 "") do failures += 1

    -- 4. non ASCII round trip (the \u00XX byte escaping scheme)
    local zh = "模型材质测试"
    local ok5 = false
    local detail5 = ""
    try (
        local wire = mcpJsonStringify (mcpObj #(#("n", zh)))
        local back = mcpStr (mcpJsonParse wire) "n"
        ok5 = (back == zh)
        detail5 = "wire=" + wire + " back=" + back
    ) catch ( detail5 = getCurrentException() )
    if not (mcpStPush "unicodeRoundTrip" ok5 detail5) do failures += 1

    -- 5. echo of the caller supplied text (end to end codepage check)
    local ok6 = true
    local detail6 = echoText
    if echoText != "" then
    (
        local wire = mcpJsonStringify (mcpObj #(#("n", echoText)))
        local back = mcpStr (mcpJsonParse wire) "n"
        ok6 = (back == echoText)
        detail6 = "sent=" + echoText + " back=" + back
    )
    if not (mcpStPush "echoText" ok6 detail6) do failures += 1

    -- 6. number formatting must stay valid JSON
    local ok7 = false
    local detail7 = ""
    try (
        detail7 = (mcpJsonNumber 10) + "," + (mcpJsonNumber 1.5) + "," + (mcpJsonNumber 0.000001) + "," + (mcpJsonNumber 100000000000000000000.0)
        local lower = toLower detail7
        ok7 = ((findString lower "e") == undefined)
    ) catch ( detail7 = getCurrentException() )
    if not (mcpStPush "numberFormat" ok7 detail7) do failures += 1

    -- 7. object creation / inspection / deletion
    local ok8 = false
    local detail8 = ""
    local probe = undefined
    try (
        probe = Box length:12 width:8 height:5 name:"__mcp_selftest_box"
        local info = mcpNodeInfo probe
        ok8 = (mcpStr info "name" == "__mcp_selftest_box") and (mcpInt info "handle" != 0)
        detail8 = mcpStr info "class" + " / " + (mcpStr info "superClass")
    ) catch ( detail8 = getCurrentException() )
    if not (mcpStPush "sceneCreate" ok8 detail8) do failures += 1
    if probe != undefined do ( try ( delete probe ) catch() )

    -- 8. node resolution helper
    local ok9 = false
    local detail9 = ""
    local probe2 = undefined
    try (
        probe2 = Sphere radius:3 name:"__mcp_selftest_sphere"
        local n1 = mcpResolveNode "__mcp_selftest_sphere"
        local n2 = mcpResolveNode "$__mcp_selftest_sphere"
        ok9 = (n1 == probe2) and (n2 == probe2)
        detail9 = "resolved=" + ((n1 != undefined) as string)
    ) catch ( detail9 = getCurrentException() )
    if not (mcpStPush "nodeResolve" ok9 detail9) do failures += 1
    if probe2 != undefined do ( try ( delete probe2 ) catch() )

    -- 9. the hold stack (what every mutating command relies on)
    local ok10 = false
    local detail10 = ""
    local probe3 = undefined
    try (
        mcpHoldBegin()
        probe3 = Cylinder radius:2 height:6 name:"__mcp_selftest_cyl"
        mcpHoldAccept "mcp self test"
        ok10 = (probe3 != undefined)
        detail10 = "accepted"
    ) catch ( detail10 = getCurrentException() )
    if not (mcpStPush "holdStack" ok10 detail10) do failures += 1
    if probe3 != undefined do ( try ( delete probe3 ) catch() )

    -- 10. socket layer
    local ok11 = false
    local detail11 = ""
    try (
        local ip = (dotNetClass "System.Net.IPAddress").Parse "127.0.0.1"
        local lst = dotNetObject "System.Net.Sockets.TcpListener" ip 8799
        lst.Start()
        ok11 = (lst.Pending() == false)
        lst.Stop()
        detail11 = "bind ok"
    ) catch ( detail11 = getCurrentException() )
    if not (mcpStPush "tcpListener" ok11 detail11) do failures += 1

    -- 11. pump timer
    local ok12 = (mcpTimer != undefined)
    if not (mcpStPush "pumpTimer" ok12 ((mcpTimer != undefined) as string)) do failures += 1

    -- 12. version probe
    local ok13 = (mcpMaxYear() >= 2020)
    if not (mcpStPush "version" ok13 ((mcpMaxYear()) as string)) do failures += 1

    local p = #()
    mcpPair p "ok" (failures == 0)
    mcpPair p "failures" failures
    mcpPair p "checks" mcpSelfTestLines
    mcpPair p "maxYear" (mcpMaxYear())
    mcpPair p "language" mcpLang
    mcpPair p "port" mcpPort
    mcpObj p
)

fn mcpH_bridge_selftest params =
(
    local echo = mcpStr params "echoText"
    mcpSelfTest echoText:echo
)

fn mcpRegisterSelftest =
(
    mcpRegister "bridge_selftest" mcpH_bridge_selftest undoable:false
    ok
)

mcpRegisterSelftest()
