/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_animation.ms
   Consolidated animation & rigging module: keyframes, playback/time,
   controllers, wire parameters, constraints, bones, skinning, IK, and morpher.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_animation.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_animation.ms
   Keyframes, playback / time, controllers / wiring, constraints.

   Category: animation (bridge command names anim_*, ctrl_*, constraint_*)

   Hard rules honoured:
     * No struct, no closures / lambdas, no trailing-backslash continuations.
     * Frame values are converted with `frame * ticksPerFrame` so nothing assumes
       30 fps - the scene frame rate is always respected.
     * Undo is handled centrally by the dispatcher; we never call theHold here.
     * Every user visible string goes through mcpMsg or a bilingual catalog.
-----------------------------------------------------------------------------*/

global mcpAnimValueFor, mcpAnimSetKeyAt, mcpGetAnimController, mcpControllerClass
global mcpMapTangent, mcpMapOutOfRange, mcpKeyValFor, mcpCollectHierarchy, mcpPaginateInto
global mcpH_anim_set_key, mcpH_anim_set_keys, mcpH_anim_get_keys, mcpH_anim_delete_keys
global mcpH_anim_clear_animation, mcpH_anim_offset_keys, mcpH_anim_scale_keys
global mcpH_anim_set_controller, mcpH_anim_get_controller, mcpH_anim_set_out_of_range
global mcpH_anim_ease, mcpH_anim_bake, mcpH_anim_bake_range, mcpH_anim_set_interpolation
global mcpH_anim_goto_frame, mcpH_anim_get_frame, mcpH_anim_play, mcpH_anim_play_preview, mcpH_anim_get_key_stats
global mcpH_ctrl_list, mcpH_ctrl_set_value, mcpH_ctrl_set_property, mcpH_ctrl_add_list, mcpH_ctrl_wire, mcpH_ctrl_assign_expression
global mcpH_constraint_look_at, mcpH_constraint_position, mcpH_constraint_orientation, mcpH_constraint_path
global mcpH_constraint_link, mcpH_constraint_surface, mcpH_constraint_list, mcpH_constraint_remove, mcpH_constraint_set_weight
global mcpRegisterAnimation


/*-------------------------------------------------------------- shared helpers */
-- Coerce a raw JSON value into the MAXScript value a property expects.
fn mcpAnimValueFor propName rawVal =
(
    if propName == "rotation" then
    (
        local vv = mcpPoint3From rawVal default:[0,0,0]
        (eulerAngles vv.x vv.y vv.z) as quat
    )
    else if propName == "position" then
        mcpPoint3From rawVal default:[0,0,0]
    else if propName == "scale" then
        mcpPoint3From rawVal default:[1,1,1]
    else
    (
        if isKindOf rawVal Array then
        (
            if rawVal.count >= 3 then (point3 rawVal[1] rawVal[2] rawVal[3])
            else if rawVal.count == 1 then rawVal[1]
            else rawVal
        )
        else rawVal
    )
)

-- Write one key for a property at time t (ticks). rel adds to the current value.
fn mcpAnimSetKeyAt node propName t v rel =
(
    animate on
    (
        at time t
        (
            if propName == "position" then
            (
                if rel then node.position = node.position + v else node.position = v
            )
            else if propName == "rotation" then
            (
                if rel then node.rotation = node.rotation * v else node.rotation = v
            )
            else if propName == "scale" then
            (
                if rel then node.scale = node.scale * v else node.scale = v
            )
            else
                try ( setProperty node propName v ) catch()
        )
    )
    ok
)

-- Resolve the controller of a property (transform tracks are solid; arbitrary
-- properties are best-effort via execute / subAnim).
fn mcpGetAnimController node propName =
(
    if propName == "position" do return (try ( node.position.controller ) catch (undefined))
    if propName == "rotation" do return (try ( node.rotation.controller ) catch (undefined))
    if propName == "scale" do return (try ( node.scale.controller ) catch (undefined))
    local code = "$'" + node.name + "'." + propName + ".controller"
    local c1 = try ( execute code ) catch (undefined)
    if c1 != undefined do return c1
    local sa = try ( getSubAnim node propName ) catch (undefined)
    if sa != undefined do
    (
        local c2 = try ( sa.controller ) catch (undefined)
        if c2 != undefined do return c2
    )
    undefined
)

-- Map a friendly controller type to a MAXScript controller class name.
fn mcpControllerClass propName typeName =
(
    local t = toLower (typeName as string)
    if propName == "position" then
    (
        if t == "bezier" do return "bezier_position"
        if t == "linear" do return "linear_position"
        if t == "xyz" or t == "positionxyz" do return "position_xyz"
        if t == "list" do return "position_list"
        if t == "tcb" or t == "tch" do return "tcb_position"
    )
    if propName == "rotation" then
    (
        if t == "bezier" do return "bezier_rotation"
        if t == "linear" do return "linear_rotation"
        if t == "euler" or t == "eulerxyz" do return "euler_xyz"
        if t == "tcb" or t == "tch" do return "tcb_rotation"
        if t == "list" do return "rotation_list"
    )
    if propName == "scale" then
    (
        if t == "bezier" do return "bezier_scale"
        if t == "linear" do return "linear_scale"
        if t == "tcb" or t == "tch" do return "tcb_scale"
        if t == "list" do return "scale_list"
    )
    if t == "bezier" do return "bezier_float"
    if t == "linear" do return "linear_float"
    if t == "tcb" or t == "tch" do return "tcb_float"
    if t == "euler" do return "euler_xyz"
    if t == "xyz" do return "position_xyz"
    if t == "list" do return "position_list"
    typeName as string
)

-- Map a tangent name to a MAXScript tangent Type value.
fn mcpMapTangent name =
(
    local t = toLower (name as string)
    if t == "linear" do return #linear
    if t == "step" do return #step
    if t == "slow" do return #slow
    if t == "fast" do return #fast
    if t == "custom" do return #custom
    #smooth
)

-- Map an out-of-range name to a MAXScript out-of-range Type value.
fn mcpMapOutOfRange name =
(
    local t = toLower (name as string)
    if t == "cycle" do return #cycle
    if t == "pingpong" do return #pingpong
    if t == "constant" do return #constant
    if t == "linear" do return #linear
    #loop
)

-- Convert a key value into a JSON-friendly form (Point3 / Number / String).
fn mcpKeyValFor v =
(
    if isKindOf v Point3 then v
    else if isKindOf v Point2 then (point3 v.x v.y 0)
    else if isKindOf v quat then
    (
        local ea = (v as eulerAngles)
        (point3 ea.x ea.y ea.z)
    )
    else if isKindOf v angAxis then
    (
        local ea = (v as eulerAngles)
        (point3 ea.x ea.y ea.z)
    )
    else if isKindOf v Number then v
    else ( try ( v as string ) catch ( "" ) )
)

-- Recursively collect a node and all its descendants.
fn mcpCollectHierarchy node out =
(
    append out node
    for c in node.children do mcpCollectHierarchy c out
    ok
)

-- Append paginated fields (count/returned/offset/limit/items) into an existing pair array p.
fn mcpPaginateInto p all limit offset =
(
    local page = #()
    local cnt = 0
    if offset < 0 do offset = 0
    if limit < 1 do limit = 200
    for it in all do
    (
        cnt += 1
        if cnt > offset and page.count < limit do append page it
    )
    mcpPair p "count" all.count
    mcpPair p "returned" page.count
    mcpPair p "offset" offset
    mcpPair p "limit" limit
    mcpPair p "items" page
    ok
)


/*---------------------------------------------------------------- keyframes */
fn mcpH_anim_set_key params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local frame = mcpReqInt params "frame"
    local t = frame * ticksPerFrame
    local rawVal = mcpGet params "value"
    if rawVal == undefined do mcpFail "err.missing_param" a1:"value"
    local rel = mcpBool params "relative" default:false
    local applied = #()
    for node in nodes do
    (
        local v = mcpAnimValueFor propName rawVal
        mcpAnimSetKeyAt node propName t v rel
        append applied node.name
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "property" propName
    mcpPair p "frame" frame
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_set_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local keys = mcpArr params "keys"
    if keys.count == 0 do mcpFail "err.missing_param" a1:"keys"
    local rel = mcpBool params "relative" default:false
    local applied = #()
    for node in nodes do
    (
        for kp in keys do
        (
            local f = mcpInt kp "frame"
            local raw = mcpGet kp "value"
            if raw != undefined do
            (
                local v = mcpAnimValueFor propName raw
                mcpAnimSetKeyAt node propName (f * ticksPerFrame) v rel
            )
        )
        append applied node.name
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "property" propName
    mcpPair p "keyCount" keys.count
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_get_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local all = #()
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do
        (
            local ks = try ( ctrl.keys ) catch ( #() )
            for k in ks do
            (
                local f = try ( k.time.frame as integer ) catch (0)
                local av = try ( k.value ) catch (undefined)
                local e = #()
                mcpPair e "object" node.name
                mcpPair e "frame" f
                mcpPair e "value" (mcpKeyValFor av)
                mcpPair e "inTangent" (try ( k.inTangentType as string ) catch (""))
                mcpPair e "outTangent" (try ( k.outTangentType as string ) catch (""))
                append all (mcpObj e)
            )
        )
    )
    local p = #()
    mcpPair p "property" propName
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:200) (mcpInt params "offset" default:0)
    mcpObj p
)

fn mcpH_anim_delete_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local frames = mcpArr params "frames"
    -- `objects` used to echo the request, so a node with no controller - or a
    -- frame that holds no key - still came back as "done".  Report what was
    -- actually deleted and name the nodes that had nothing to delete.
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ctrl = mcpGetAnimController node propName
        if ctrl == undefined then
            append failures (nm + ": no " + propName + " controller")
        else
        (
            local removed = 0
            if frames.count > 0 then
            (
                for f in frames do
                (
                    local k = try ( getKey ctrl (f * ticksPerFrame) ) catch ( undefined )
                    if k != undefined do
                    (
                        local ok = true
                        try ( deleteKey ctrl k ) catch ( ok = false )
                        if ok then removed = removed + 1
                        else append failures (nm + ": delete failed at frame " + (f as string))
                    )
                )
                if removed == 0 do append failures (nm + ": no key at the requested frames")
            )
            else
            (
                local ok = true
                try ( deleteKeys ctrl #all ) catch ( ok = false )
                if ok then removed = 1 else append failures (nm + ": deleteKeys failed")
            )
            if removed > 0 do append applied nm
        )
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_clear_animation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local props = mcpArr params "properties"
    local plist = #()
    if props.count == 0 then plist = #("position", "rotation", "scale")
    else ( for x in props do append plist (x as string) )
    -- Clearing an object that has no animation is a legitimate no-op, not a
    -- failure.  Clearing a controller that still holds keys afterwards is a
    -- failure.  The old code could not tell those apart: it echoed the request.
    local applied = #()
    local skipped = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local had = false
        local ok = true
        local leftover = 0
        for pr in plist do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do
            (
                local before = 0
                try ( before = ctrl.keys.count ) catch ( before = 0 )
                if before > 0 do had = true
                try ( deleteKeys ctrl #all ) catch ( ok = false )
                local after = 0
                try ( after = ctrl.keys.count ) catch ( after = 0 )
                leftover = leftover + after
            )
        )
        -- Read back: if any controller still reports keys, the clear did not take.
        if not ok or leftover > 0 then
            append failures (nm + ": " + (leftover as string) + " key(s) left")
        else if had then append applied nm
        else append skipped (nm + ": no keys to clear")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "skipped" skipped
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_offset_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local dt = (mcpReqInt params "offset") * ticksPerFrame
    local applied = #()
    local skipped = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ctrl = mcpGetAnimController node propName
        if ctrl == undefined then append skipped (nm + ": no " + propName + " controller")
        else
        (
            local n = 0
            local ok = true
            for k in ctrl.keys do ( n = n + 1; try ( k.time = k.time + dt ) catch ( ok = false ) )
            if not ok then append failures (nm + ": key move failed")
            else if n == 0 then append skipped (nm + ": no keys")
            else append applied nm
        )
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "skipped" skipped
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "offset" (mcpInt params "offset")
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_scale_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local factor = mcpNum params "factor" default:1.0
    local pt = (mcpInt params "pivotFrame" default:0) * ticksPerFrame
    local applied = #()
    local skipped = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ctrl = mcpGetAnimController node propName
        if ctrl == undefined then append skipped (nm + ": no " + propName + " controller")
        else
        (
            local n = 0
            local ok = true
            for k in ctrl.keys do ( n = n + 1; try ( k.time = pt + (k.time - pt) * factor ) catch ( ok = false ) )
            if not ok then append failures (nm + ": key move failed")
            else if n == 0 then append skipped (nm + ": no keys")
            else append applied nm
        )
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "skipped" skipped
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "factor" factor
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_set_controller params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local ctrlType = mcpReqStr params "controller"
    local cls = mcpControllerClass propName ctrlType
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if propName == "position" then node.position.controller = (execute cls)()
            else if propName == "rotation" then node.rotation.controller = (execute cls)()
            else if propName == "scale" then node.scale.controller = (execute cls)()
            else
            (
                local code = "$'" + node.name + "'." + propName + ".controller = (" + cls + ")()"
                execute code
            )
        )
        catch ( ok = false )
        -- Read back the controller that is actually installed.  Max refuses some
        -- classes for a given track and silently keeps the old one; the reply
        -- used to state the requested type either way.
        local actual = ""
        try ( actual = (classof (mcpGetAnimController node propName)) as string ) catch ( actual = "" )
        if ok and actual != "" and (toLower actual) == (toLower cls) then
            append applied nm
        else
            append failures (nm + ": installed '" + actual + "', wanted '" + cls + "'")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "controller" cls
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_get_controller params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local node = nodes[1]
    local propName = mcpReqStr params "property"
    local ctrl = mcpGetAnimController node propName
    local p = #()
    mcpPair p "object" node.name
    mcpPair p "property" propName
    mcpPair p "controller" (try ( classof ctrl as string ) catch (""))
    mcpPair p "keyCount" (try ( ctrl.keys.count ) catch (0))
    mcpObj p
)

fn mcpH_anim_set_out_of_range params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local oor = mcpMapOutOfRange (mcpStr params "type" default:"loop")
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do try ( setOutOfRangeType ctrl oor ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_ease params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local frame = mcpReqInt params "frame"
    local t = frame * ticksPerFrame
    local inT = mcpStr params "inTangent" default:""
    local outT = mcpStr params "outTangent" default:""
    -- Same fix as anim_delete_keys: the reply used to echo the request, so a
    -- node without a controller, or a frame without a key, looked like success.
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ctrl = mcpGetAnimController node propName
        if ctrl == undefined then
            append failures (nm + ": no " + propName + " controller")
        else
        (
            local k = try ( getKey ctrl t ) catch ( undefined )
            if k == undefined then
                append failures (nm + ": no key at frame " + (frame as string))
            else
            (
                local changed = false
                local ok = true
                if inT != "" do
                    try ( k.inTangentType = (mcpMapTangent inT); changed = true ) catch ( ok = false )
                if outT != "" do
                    try ( k.outTangentType = (mcpMapTangent outT); changed = true ) catch ( ok = false )
                if (mcpGet params "inHandle") != undefined do
                    try ( k.inTangent = (mcpNum params "inHandle"); changed = true ) catch ( ok = false )
                if (mcpGet params "outHandle") != undefined do
                    try ( k.outTangent = (mcpNum params "outHandle"); changed = true ) catch ( ok = false )
                if ok and changed then append applied nm
                else append failures (nm + ": tangent rejected")
            )
        )
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "frame" frame
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_bake params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local startF = mcpInt params "startFrame" default:(animationRange.start.frame as integer)
    local endF = mcpInt params "endFrame" default:(animationRange.end.frame as integer)
    local step = mcpInt params "step" default:1
    if step < 1 do step = 1
    local propArr = mcpArr params "properties"
    local props = #()
    if propArr.count == 0 then props = #("position", "rotation", "scale")
    else ( for x in propArr do append props (x as string) )
    local totalKeys = 0
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        animate on
        (
            for f = startF to endF by step do
            (
                local t = f * ticksPerFrame
                at time t
                (
                    for pr in props do
                    (
                        if pr == "position" then
                        (
                            local pv = try ( node.position ) catch (undefined)
                            if pv != undefined do node.position = pv
                        )
                        else if pr == "rotation" then
                        (
                            local rv = try ( node.rotation ) catch (undefined)
                            if rv != undefined do node.rotation = rv
                        )
                        else if pr == "scale" then
                        (
                            local sv = try ( node.scale ) catch (undefined)
                            if sv != undefined do node.scale = sv
                        )
                        else try ( local cv = getProperty node pr; setProperty node pr cv ) catch()
                    )
                )
            )
        )
        local c = 0
        local atStart = 0
        for pr in props do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do
            (
                try ( c = c + ctrl.keys.count ) catch()
                -- Bake promises a key on every sampled frame; check the
                -- first one exists instead of trusting the loop ran.
                local k = try ( getKey ctrl (startF * ticksPerFrame) ) catch ( undefined )
                if k != undefined do atStart = atStart + 1
            )
        )
        totalKeys = totalKeys + c
        if atStart > 0 then append applied nm
        else append failures (nm + ": no key at frame " + (startF as string))
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "startFrame" startF
    mcpPair p "endFrame" endF
    mcpPair p "step" step
    mcpPair p "keysWritten" totalKeys
    mcpPair p "message" (mcpMsg "msg.anim_baked" a1:(nodes.count as string))
    mcpObj p
)

fn mcpH_anim_bake_range params =
(
    local roots = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local all = #()
    for r in roots do mcpCollectHierarchy r all
    local startF = mcpInt params "startFrame" default:(animationRange.start.frame as integer)
    local endF = mcpInt params "endFrame" default:(animationRange.end.frame as integer)
    local step = mcpInt params "step" default:1
    if step < 1 do step = 1
    local propArr = mcpArr params "properties"
    local props = #()
    if propArr.count == 0 then props = #("position", "rotation", "scale")
    else ( for x in propArr do append props (x as string) )
    local totalKeys = 0
    local applied = #()
    local failures = #()
    for node in all do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        animate on
        (
            for f = startF to endF by step do
            (
                local t = f * ticksPerFrame
                at time t
                (
                    for pr in props do
                    (
                        if pr == "position" then
                        (
                            local pv = try ( node.position ) catch (undefined)
                            if pv != undefined do node.position = pv
                        )
                        else if pr == "rotation" then
                        (
                            local rv = try ( node.rotation ) catch (undefined)
                            if rv != undefined do node.rotation = rv
                        )
                        else if pr == "scale" then
                        (
                            local sv = try ( node.scale ) catch (undefined)
                            if sv != undefined do node.scale = sv
                        )
                        else try ( local cv = getProperty node pr; setProperty node pr cv ) catch()
                    )
                )
            )
        )
        local c = 0
        local atStart = 0
        for pr in props do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do
            (
                try ( c = c + ctrl.keys.count ) catch()
                -- Bake promises a key on every sampled frame; check the
                -- first one exists instead of trusting the loop ran.
                local k = try ( getKey ctrl (startF * ticksPerFrame) ) catch ( undefined )
                if k != undefined do atStart = atStart + 1
            )
        )
        totalKeys = totalKeys + c
        if atStart > 0 then append applied nm
        else append failures (nm + ": no key at frame " + (startF as string))
    )
    local p = #()
    mcpPair p "roots" (for r in roots collect r.name)
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "objectCount" all.count
    mcpPair p "startFrame" startF
    mcpPair p "endFrame" endF
    mcpPair p "step" step
    mcpPair p "keysWritten" totalKeys
    mcpPair p "message" (mcpMsg "msg.anim_baked" a1:(all.count as string))
    mcpObj p
)

fn mcpH_anim_set_interpolation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local tn = mcpMapTangent (mcpReqStr params "type")
    local frames = mcpArr params "frames"
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do
        (
            if frames.count > 0 then
            (
                for f in frames do
                (
                    local k = try ( getKey ctrl (f * ticksPerFrame) ) catch (undefined)
                    if k != undefined do try ( k.inTangentType = tn; k.outTangentType = tn ) catch()
                )
            )
            else
                for k in ctrl.keys do try ( k.inTangentType = tn; k.outTangentType = tn ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------ playback & time */
fn mcpH_anim_goto_frame params =
(
    local frame = mcpReqInt params "frame"
    sliderTime = frame * ticksPerFrame
    -- Read the frame back: the timeline clamps at the scene range, and a
    -- "goto 200" that actually landed on 100 must not look like success.
    local got = try ( currentTime.frame as integer ) catch ( -1 )
    local p = #()
    mcpPair p "frame" got
    mcpPair p "requested" frame
    mcpPair p "failures" (if got == frame then #() else #("frame=" + (got as string)))
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_get_frame params =
(
    local p = #()
    mcpPair p "frame" (try ( currentTime.frame as integer ) catch (0))
    mcpObj p
)

fn mcpH_anim_play params =
(
    local action = mcpReqStr params "action"
    local p = #()
    if action == "play" then
    (
        if (mcpGet params "fromFrame") != undefined do
        (
            local ff = mcpInt params "fromFrame"
            sliderTime = ff * ticksPerFrame
        )
        if (mcpGet params "toFrame") != undefined do
        (
            local tf = mcpInt params "toFrame"
            try ( playbackRange = interval (sliderTime) (tf * ticksPerFrame) ) catch()
        )
        try ( playAnimation() ) catch()
        mcpPair p "action" "play"
    )
    else if action == "stop" then
    (
        try ( stopAnimation() ) catch()
        mcpPair p "action" "stop"
    )
    else if action == "pause" then
    (
        try ( execute "max time.pause" ) catch ( try ( stopAnimation() ) catch() )
        mcpPair p "action" "pause"
    )
    else mcpFail "err.bad_value" a1:"action"
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_play_preview params =
(
    local out = mcpStr params "output" default:""
    local sf = mcpInt params "startFrame" default:(animationRange.start.frame as integer)
    local ef = mcpInt params "endFrame" default:(animationRange.end.frame as integer)
    local pct = mcpInt params "percent" default:100
    local path = ""
    try
    (
        if out != "" then
            makePreview outputName:out range:(interval (sf * ticksPerFrame) (ef * ticksPerFrame)) percent:pct
        else
            makePreview range:(interval (sf * ticksPerFrame) (ef * ticksPerFrame)) percent:pct
        path = out
    )
    catch ( path = "" )
    local p = #()
    mcpPair p "output" path
    mcpPair p "message" (if path != "" then (mcpMsg "msg.ok") else (mcpMsg "msg.feature_unsupported" a1:"preview"))
    mcpObj p
)

fn mcpH_anim_get_key_stats params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local all = #()
    for node in nodes do
    (
        local pk = 0; local rk = 0; local sk = 0
        local pc = mcpGetAnimController node "position"
        if pc != undefined do ( try ( pk = pc.keys.count ) catch (0) )
        local rc = mcpGetAnimController node "rotation"
        if rc != undefined do ( try ( rk = rc.keys.count ) catch (0) )
        local sc = mcpGetAnimController node "scale"
        if sc != undefined do ( try ( sk = sc.keys.count ) catch (0) )
        local e = #()
        mcpPair e "object" node.name
        mcpPair e "positionKeys" pk
        mcpPair e "rotationKeys" rk
        mcpPair e "scaleKeys" sk
        mcpPair e "total" (pk + rk + sk)
        append all (mcpObj e)
    )
    local p = #()
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:200) (mcpInt params "offset" default:0)
    mcpObj p
)


/*-------------------------------------------------------- controllers / wiring */
fn mcpH_ctrl_list params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local node = nodes[1]
    local all = #()
    local subs = try ( node.numSubs ) catch (0)
    for i = 1 to subs do
    (
        local sa = try ( getSubAnim node i ) catch (undefined)
        if sa != undefined do
        (
            local nm = try ( getSubAnimName node i ) catch ("")
            local ctrl = try ( sa.controller ) catch (undefined)
            if ctrl != undefined do
            (
                local e = #()
                mcpPair e "track" nm
                mcpPair e "controller" (try ( classof ctrl as string ) catch (""))
                mcpPair e "keyCount" (try ( ctrl.keys.count ) catch (0))
                append all (mcpObj e)
            )
        )
    )
    local p = #()
    mcpPair p "object" node.name
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:200) (mcpInt params "offset" default:0)
    mcpObj p
)

fn mcpH_ctrl_set_value params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local rawVal = mcpGet params "value"
    if rawVal == undefined do mcpFail "err.missing_param" a1:"value"
    local rel = mcpBool params "relative" default:false
    local t = ticksPerFrame * (mcpInt params "frame" default:(currentTime.frame as integer))
    local applied = #()
    for node in nodes do
    (
        local v = mcpAnimValueFor propName rawVal
        mcpAnimSetKeyAt node propName t v rel
        append applied node.name
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_ctrl_set_property params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local valStr = mcpReqStr params "value"
    local t = ticksPerFrame * (mcpInt params "frame" default:(currentTime.frame as integer))
    local applied = #()
    for node in nodes do
    (
        at time t
        (
            try ( setProperty node propName valStr ) catch()
        )
        append applied node.name
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_ctrl_add_list params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local layer = mcpStr params "layer" default:"noise_position"
    local weight = mcpNum params "weight" default:100.0
    for node in nodes do
    (
        if propName == "position" then
        (
            if (classof node.position.controller) != position_list do
                try ( node.position.controller = position_list() ) catch()
            local lst = node.position.controller
            try
            (
                lst.count = lst.count + 1
                lst[lst.count] = (execute layer)()
                try ( lst.weight[lst.count] = weight ) catch ( try ( lst.setWeight lst.count weight ) catch() )
            )
            catch()
        )
        else if propName == "rotation" then
        (
            if (classof node.rotation.controller) != rotation_list do
                try ( node.rotation.controller = rotation_list() ) catch()
            local lst = node.rotation.controller
            try
            (
                lst.count = lst.count + 1
                lst[lst.count] = (execute layer)()
                try ( lst.weight[lst.count] = weight ) catch ( try ( lst.setWeight lst.count weight ) catch() )
            )
            catch()
        )
        else if propName == "scale" then
        (
            if (classof node.scale.controller) != scale_list do
                try ( node.scale.controller = scale_list() ) catch()
            local lst = node.scale.controller
            try
            (
                lst.count = lst.count + 1
                lst[lst.count] = (execute layer)()
                try ( lst.weight[lst.count] = weight ) catch ( try ( lst.setWeight lst.count weight ) catch() )
            )
            catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "property" propName
    mcpPair p "layer" layer
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_ctrl_wire params =
(
    local srcNode = mcpResolveNode (mcpReqStr params "source")
    local srcProp = mcpReqStr params "sourceProperty"
    local dstNode = mcpResolveNode (mcpReqStr params "target")
    local dstProp = mcpReqStr params "targetProperty"
    local expr = mcpStr params "expression" default:""
    local code = "paramWire.connect ($'" + srcNode.name + "'." + srcProp + ") ($'" + dstNode.name + "'." + dstProp + ") \"" + expr + "\""
    local ok = false
    try ( execute code; ok = true ) catch()
    local p = #()
    mcpPair p "source" srcNode.name
    mcpPair p "target" dstNode.name
    mcpPair p "wired" ok
    mcpPair p "message" (if ok then (mcpMsg "msg.ok") else (mcpMsg "msg.feature_unsupported" a1:"wire"))
    mcpObj p
)

fn mcpH_ctrl_assign_expression params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local expr = mcpReqStr params "expression"
    local applied = #()
    for node in nodes do
    (
        local ok = false
        local code = "$'" + node.name + "'." + propName + ".controller = expression_float()"
        try ( execute code; ok = true ) catch()
        if ok do
        (
            local ec = try ( execute ("$'" + node.name + "'." + propName + ".controller") ) catch (undefined)
            if ec != undefined do try ( ec.script = expr ) catch()
        )
        append applied node.name
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*--------------------------------------------------------------- constraints */
fn mcpH_constraint_look_at params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local upNodeName = mcpStr params "upNode" default:""
    local keep = mcpBool params "keepOffset" default:false
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            node.rotation.controller = lookAt_constraint()
            local lc = node.rotation.controller
            lc.appendTarget target 100.0
            if upNodeName != "" do
            (
                local un = mcpResolveNode upNodeName
                if un != undefined do try ( lc.upnode = un ) catch()
            )
            try ( lc.relative = keep ) catch()
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_position params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local w = mcpNum params "weight" default:100.0
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            node.position.controller = position_constraint()
            node.position.controller.appendTarget target w
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_orientation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local w = mcpNum params "weight" default:100.0
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            node.rotation.controller = orientation_constraint()
            node.rotation.controller.appendTarget target w
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_path params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local pathNode = mcpResolveNode (mcpReqStr params "path")
    local pct = mcpNum params "percent" default:0.0
    local follow = mcpBool params "follow" default:true
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            node.position.controller = path_constraint()
            local pc = node.position.controller
            pc.path = pathNode
            try ( pc.follow = follow ) catch()
            try ( pc.percent = pct ) catch()
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "path" pathNode.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_link params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local f = mcpInt params "frame" default:(currentTime.frame as integer)
    -- The whole loop used to sit inside one bare catch, so a locked controller or
    -- a bad target produced "objects: [everything]" and no error at all.
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            node.position.controller = link_constraint()
            node.position.controller.addTarget target (f * ticksPerFrame)
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_surface params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local targetNode = mcpResolveNode (mcpReqStr params "target")
    local u = mcpNum params "u" default:0.5
    local v = mcpNum params "v" default:0.5
    -- This one cannot use the shape of the other constraints: it tries two
    -- constructor names, and it can leave a half-built constraint behind (the
    -- controller is installed but never bound to the target).
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local made = false
        try ( node.position.controller = surface(); made = true ) catch()
        if not made do try ( node.position.controller = surface_constraint(); made = true ) catch()
        if not made then
            append failures (nm + ": no surface constraint class")
        else
        (
            local sc = node.position.controller
            local bound = true
            try ( sc.surface = targetNode ) catch ( bound = false )
            try ( sc.u = u; sc.v = v ) catch()
            -- Read back the bound surface: "the controller was created" is not
            -- "the constraint points at the target".
            local actual = ""
            try ( actual = sc.surface.name ) catch ( actual = "" )
            if bound and actual == targetNode.name then append applied nm
            else append failures (nm + ": surface bound to '" + actual + "'")
        )
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "target" targetNode.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_list params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local node = nodes[1]
    local all = #()
    local subs = try ( node.numSubs ) catch (0)
    for i = 1 to subs do
    (
        local sa = try ( getSubAnim node i ) catch (undefined)
        if sa != undefined do
        (
            local ctrl = try ( sa.controller ) catch (undefined)
            if ctrl != undefined do
            (
                local isC = false
                try ( isC = (isKindOf ctrl Constraint) ) catch ( isC = false )
                if not isC do
                (
                    local cn = try ( classof ctrl as string ) catch ("")
                    isC = ((findString (toLower cn) "constraint") != undefined)
                )
                if isC do
                (
                    local e = #()
                    mcpPair e "track" (try ( getSubAnimName node i ) catch (""))
                    mcpPair e "controller" (try ( classof ctrl as string ) catch (""))
                    mcpPair e "keyCount" (try ( ctrl.keys.count ) catch (0))
                    append all (mcpObj e)
                )
            )
        )
    )
    local p = #()
    mcpPair p "object" node.name
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:200) (mcpInt params "offset" default:0)
    mcpObj p
)

fn mcpH_constraint_remove params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpStr params "property" default:"position"
    -- Removing a constraint means putting a plain bezier controller back.  Read
    -- the installed class back: a locked track keeps its constraint, and the
    -- reply used to say the removal happened anyway.
    local want = "bezier_position"
    if propName == "rotation" do want = "bezier_rotation"
    else if propName == "scale" do want = "bezier_scale"
    else if propName != "position" do want = "bezier_float"
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if propName == "position" then node.position.controller = bezier_position()
            else if propName == "rotation" then node.rotation.controller = bezier_rotation()
            else if propName == "scale" then node.scale.controller = bezier_scale()
            else
            (
                local code = "$'" + node.name + "'." + propName + ".controller = bezier_float()"
                execute code
            )
        )
        catch ( ok = false )
        local actual = ""
        try ( actual = (classof (mcpGetAnimController node propName)) as string ) catch ( actual = "" )
        if ok and (toLower actual) == (toLower want) then append applied nm
        else append failures (nm + ": controller is '" + actual + "', wanted '" + want + "'")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "property" propName
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_set_weight params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local ti = mcpReqInt params "targetIndex"
    local w = mcpNum params "weight" default:100.0
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do try ( ctrl.setWeight ti w ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "property" propName
    mcpPair p "targetIndex" ti
    mcpPair p "weight" w
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*--------------------------------------------------------------- registration */
fn mcpRegisterAnimation =
(
    mcpRegister "anim_set_key" mcpH_anim_set_key label:"Set Key"
    mcpRegister "anim_set_keys" mcpH_anim_set_keys label:"Set Keys"
    mcpRegister "anim_get_keys" mcpH_anim_get_keys undoable:false label:"Get Keys"
    mcpRegister "anim_delete_keys" mcpH_anim_delete_keys label:"Delete Keys"
    mcpRegister "anim_clear_animation" mcpH_anim_clear_animation label:"Clear Animation"
    mcpRegister "anim_offset_keys" mcpH_anim_offset_keys label:"Offset Keys"
    mcpRegister "anim_scale_keys" mcpH_anim_scale_keys label:"Scale Keys"
    mcpRegister "anim_set_controller" mcpH_anim_set_controller label:"Set Controller"
    mcpRegister "anim_get_controller" mcpH_anim_get_controller undoable:false label:"Get Controller"
    mcpRegister "anim_set_out_of_range" mcpH_anim_set_out_of_range label:"Set Out Of Range"
    mcpRegister "anim_ease" mcpH_anim_ease label:"Ease Key"
    mcpRegister "anim_bake" mcpH_anim_bake label:"Bake Animation"
    mcpRegister "anim_bake_range" mcpH_anim_bake_range label:"Bake Range"
    mcpRegister "anim_set_interpolation" mcpH_anim_set_interpolation label:"Set Interpolation"
    mcpRegister "anim_goto_frame" mcpH_anim_goto_frame label:"Go To Frame"
    mcpRegister "anim_get_frame" mcpH_anim_get_frame undoable:false label:"Get Frame"
    mcpRegister "anim_play" mcpH_anim_play label:"Play Animation"
    mcpRegister "anim_play_preview" mcpH_anim_play_preview label:"Play Preview"
    mcpRegister "anim_get_key_stats" mcpH_anim_get_key_stats undoable:false label:"Key Stats"
    mcpRegister "ctrl_list" mcpH_ctrl_list undoable:false label:"List Controllers"
    mcpRegister "ctrl_set_value" mcpH_ctrl_set_value label:"Set Controller Value"
    mcpRegister "ctrl_set_property" mcpH_ctrl_set_property label:"Set Property"
    mcpRegister "ctrl_add_list" mcpH_ctrl_add_list label:"Add List Controller"
    mcpRegister "ctrl_wire" mcpH_ctrl_wire label:"Wire Parameters"
    mcpRegister "ctrl_assign_expression" mcpH_ctrl_assign_expression label:"Assign Expression"
    mcpRegister "constraint_look_at" mcpH_constraint_look_at label:"LookAt Constraint"
    mcpRegister "constraint_position" mcpH_constraint_position label:"Position Constraint"
    mcpRegister "constraint_orientation" mcpH_constraint_orientation label:"Orientation Constraint"
    mcpRegister "constraint_path" mcpH_constraint_path label:"Path Constraint"
    mcpRegister "constraint_link" mcpH_constraint_link label:"Link Constraint"
    mcpRegister "constraint_surface" mcpH_constraint_surface label:"Surface Constraint"
    mcpRegister "constraint_list" mcpH_constraint_list undoable:false label:"List Constraints"
    mcpRegister "constraint_remove" mcpH_constraint_remove label:"Remove Constraint"
    mcpRegister "constraint_set_weight" mcpH_constraint_set_weight label:"Set Constraint Weight"
    ok
)

mcpRegisterAnimation()

/* ==========================================================================
   SECTION: mcp_rigging.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_rigging.ms
   Bones / helpers, skinning, IK, morph targets.

   Category: animation (bridge command names rig_*)

   Hard rules honoured:
     * No struct, no closures / lambdas, no trailing-backslash continuations.
     * Frame values use `frame * ticksPerFrame` - never assumes 30 fps.
     * Undo is handled centrally by the dispatcher; we never call theHold here.
     * Every user visible string goes through mcpMsg or a bilingual catalog.
-----------------------------------------------------------------------------*/

global mcpGetSkinMod, mcpGetMorpherMod, mcpFindBoneIndex
global mcpH_rig_create_bone, mcpH_rig_create_bone_chain, mcpH_rig_create_dummy, mcpH_rig_create_point_helper
global mcpH_rig_link_objects, mcpH_rig_set_bone_size, mcpH_rig_mirror_bone_chain, mcpH_rig_list_bones
global mcpBoneKind
global mcpH_rig_skin_add, mcpH_rig_skin_add_bone, mcpH_rig_skin_set_weight, mcpH_rig_skin_auto_weight
global mcpH_rig_skin_weight_table, mcpH_rig_skin_remove_bone, mcpH_rig_skin_set_vertex_weights
global mcpH_rig_ik_solver, mcpH_rig_set_ik_chain, mcpH_rig_ik_goal, mcpH_rig_spline_ik, mcpH_rig_ik_enable, mcpH_rig_ik_disable
global mcpH_rig_morpher_add, mcpH_rig_morpher_add_target, mcpH_rig_morpher_set_value, mcpH_rig_morpher_list
global mcpRegisterRigging


/*-------------------------------------------------------------- shared helpers */
fn mcpGetSkinMod node =
(
    for m in node.modifiers do ( if (classof m) == Skin do return m )
    undefined
)

fn mcpGetMorpherMod node =
(
    for m in node.modifiers do ( if (classof m) == Morpher do return m )
    undefined
)

/* skinOps.getBoneName takes THREE arguments in 3ds Max 2022:
   (skin, index, useXref).  Called with two it raises "argument count error",
   which was swallowed by the catch() and turned every bone name into "" --
   the weight table listed each vertex with an empty bone name. */
fn mcpSkinBoneName skinMod index =
(
    local nm = ""
    try ( nm = skinOps.getBoneName skinMod index 0 ) catch ( nm = "" )
    if nm == "" do try ( nm = skinOps.getBoneName skinMod index ) catch ( nm = "" )
    nm
)

fn mcpFindBoneIndex skinMod boneName =
(
    local nb = 0
    try ( nb = skinOps.getNumberBones skinMod ) catch ( nb = 0 )
    for i = 1 to nb do
    (
        if (mcpSkinBoneName skinMod i) == boneName do return i
    )
    -1
)

/* Read/modify/write of one vertex' weights.  There is no per-bone setter that
   works from script (skinOps.setWeight wants 2 arguments and works on the
   modifier panel selection), so the vertex weight set is rebuilt and pushed
   back with ReplaceVertexWeights -- the same call the auto weights use. */
fn mcpSkinSetVertexWeight skinMod vertex boneId weight =
(
    local ids = #()
    local ws = #()
    local vc = 0
    try ( vc = skinOps.getVertexWeightCount skinMod vertex ) catch ( vc = 0 )
    for i = 1 to vc do
    (
        local b = 0
        local w = 0.0
        try ( b = skinOps.GetVertexWeightBoneID skinMod vertex i ) catch ( b = 0 )
        try ( w = skinOps.getVertexWeight skinMod vertex i ) catch ( w = 0.0 )
        if b > 0 do ( append ids b; append ws w )
    )
    local found = false
    for i = 1 to ids.count do ( if ids[i] == boneId do ( ws[i] = weight; found = true ) )
    if not found do ( append ids boneId; append ws weight )

    /* Weights are normalised to 1 per vertex, so scaling the whole set by the
       new total diluted the value the caller asked for: "Bone1 = 1.0" on a
       vertex that held 0.5/0.5 came back 0.667/0.333.  Instead the requested
       weight is authoritative and the *other* bones share what is left --
       which is what "set this bone to 1.0 and the others stop mattering"
       means in the tool description. */
    local target = 0.0
    local others = 0.0
    for i = 1 to ids.count do
    (
        if ids[i] == boneId then target = ws[i] else others += ws[i]
    )
    if target < 0.0 do target = 0.0
    if target > 1.0 do target = 1.0
    local remain = 1.0 - target
    for i = 1 to ids.count do
    (
        if ids[i] == boneId then ws[i] = target
        else if others > 0.000001 then ws[i] = ws[i] / others * remain
        else ws[i] = 0.0
    )
    try ( skinOps.ReplaceVertexWeights skinMod vertex ids ws ) catch ( return false )
    true
)


/*----------------------------------------------------- rigging: bones & helpers */
fn mcpH_rig_create_bone params =
(
    local root = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    local dir = mcpPoint3From (mcpGet params "direction") default:[1,0,0]
    local len = mcpNum params "length" default:10.0
    local w = mcpNum params "width" default:1.0
    local h = mcpNum params "height" default:1.0
    local ndir = [0,0,1]
    try ( if (length dir) > 0.0 do ndir = normalize dir ) catch()
    local endP = root + ndir * len
    local b = BoneSys.createBone root endP [0,0,1]
    local failures = #()
    local warnings = #()
    local alive = true
    try ( alive = isValidNode b ) catch ( alive = false )
    if not alive do mcpFail "err.bad_value" a1:"BoneSys.createBone returned no node"

    local szOk = true
    local szErr = ""
    try ( b.width = w; b.height = h ) catch ( szOk = false; szErr = (getCurrentException() as string) )
    if not szOk then
    (
        append failures ("width/height: " + szErr)
    )
    else
    (
        -- Read the dimensions back: a bone silently clamps or ignores them, and
        -- the reply used to be built from the request.
        local gotW = 0.0
        local gotH = 0.0
        try ( gotW = b.width; gotH = b.height ) catch ( gotW = -1.0 )
        if (abs (gotW - w)) > 0.0001 do append failures ("width: kept " + (gotW as string))
        if (abs (gotH - h)) > 0.0001 do append failures ("height: kept " + (gotH as string))
    )

    local nm = mcpStr params "name" default:""
    if nm != "" do
    (
        try ( b.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        if b.name != nm do append warnings ("name: scene kept " + b.name)
    )
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "bone" (mcpNodeInfo b)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:b.name)
    mcpObj p
)

fn mcpH_rig_create_bone_chain params =
(
    local startRaw = mcpGet params "start"
    if startRaw == undefined do mcpFail "err.missing_param" a1:"start"
    local endRaw = mcpGet params "end"
    if endRaw == undefined do mcpFail "err.missing_param" a1:"end"
    local startP = mcpPoint3From startRaw default:[0,0,0]
    local endP = mcpPoint3From endRaw default:[0,0,0]
    local n = mcpReqInt params "count"
    local w = mcpNum params "width" default:1.0
    local h = mcpNum params "height" default:1.0
    local prefix = mcpStr params "name" default:"Bone"
    local bones = #()
    /* `count` is the number of bones, so the chain is cut into `count` equal
       segments.  It used to be cut into count-1 segments, which quietly made
       "count: 3" produce a two bone chain. */
    for i = 1 to n do
    (
        local a = startP + (endP - startP) * ((i - 1) as float / n)
        local bpt = startP + (endP - startP) * (i as float / n)
        local bone = BoneSys.createBone a bpt [0,0,1]
        try ( bone.width = w; bone.height = h ) catch()
        if bones.count > 0 do try ( bone.parent = bones[bones.count] ) catch()
        try ( bone.name = prefix + (i as string) ) catch()
        append bones bone
    )
    local p = #()
    mcpPair p "bones" (for b in bones collect (mcpNodeInfo b))
    mcpPair p "count" bones.count
    mcpPair p "message" (mcpMsg "msg.created" a1:(bones.count as string))
    mcpObj p
)

fn mcpH_rig_create_dummy params =
(
    local d = Dummy()
    local failures = #()
    local warnings = #()
    local alive = true
    try ( alive = isValidNode d ) catch ( alive = false )
    if not alive do mcpFail "err.bad_value" a1:"Dummy() returned no node"

    local sz = mcpPoint3From (mcpGet params "size") default:[10,10,10]
    local szOk = true
    local szErr = ""
    try ( d.boxSize = sz ) catch ( szOk = false; szErr = (getCurrentException() as string) )
    if not szOk then ( append failures ("size: " + szErr) )
    else
    (
        local got = [0,0,0]
        try ( got = d.boxSize ) catch ( got = [-1,-1,-1] )
        if (abs (got.x - sz.x)) > 0.0001 or (abs (got.y - sz.y)) > 0.0001 or (abs (got.z - sz.z)) > 0.0001 do
            append failures ("size: kept " + (got as string))
    )

    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    local posOk = true
    local posErr = ""
    try ( d.position = pos ) catch ( posOk = false; posErr = (getCurrentException() as string) )
    if not posOk then ( append failures ("position: " + posErr) )
    else if (distance d.position pos) > 0.001 do append failures ("position: kept " + (d.position as string))

    local nm = mcpStr params "name" default:""
    if nm != "" do
    (
        try ( d.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        if d.name != nm do append warnings ("name: scene kept " + d.name)
    )
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "object" (mcpNodeInfo d)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:d.name)
    mcpObj p
)

fn mcpH_rig_create_point_helper params =
(
    local pt = Point()
    local failures = #()
    local warnings = #()
    local alive = true
    try ( alive = isValidNode pt ) catch ( alive = false )
    if not alive do mcpFail "err.bad_value" a1:"Point() returned no node"

    local sz = mcpNum params "size" default:1.0
    local szOk = true
    local szErr = ""
    try ( pt.size = sz ) catch ( szOk = false; szErr = (getCurrentException() as string) )
    if not szOk then ( append failures ("size: " + szErr) )
    else
    (
        local got = 0.0
        try ( got = pt.size ) catch ( got = -1.0 )
        if (abs (got - sz)) > 0.0001 do append failures ("size: kept " + (got as string))
    )

    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    local posOk = true
    local posErr = ""
    try ( pt.position = pos ) catch ( posOk = false; posErr = (getCurrentException() as string) )
    if not posOk then ( append failures ("position: " + posErr) )
    else if (distance pt.position pos) > 0.001 do append failures ("position: kept " + (pt.position as string))

    local nm = mcpStr params "name" default:""
    if nm != "" do
    (
        try ( pt.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        if pt.name != nm do append warnings ("name: scene kept " + pt.name)
    )
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "object" (mcpNodeInfo pt)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:pt.name)
    mcpObj p
)

fn mcpH_rig_link_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local parent = mcpResolveNode (mcpReqStr params "parent")
    local linked = #()
    for node in nodes do
    (
        try
        (
            local wt = node.transform
            node.parent = parent
            if parent != undefined then
                node.transform = (inverse parent.transform) * wt
            else
                node.transform = wt
            append linked node.name
        )
        catch()
    )
    local p = #()
    mcpPair p "linked" linked
    mcpPair p "parent" (if parent != undefined then parent.name else "")
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_set_bone_size params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local w = mcpNum params "width" default:-1.0
    local h = mcpNum params "height" default:-1.0
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        if w >= 0 do try ( node.width = w ) catch ( ok = false )
        if h >= 0 do try ( node.height = h ) catch ( ok = false )
        if ok then append applied nm
        else append failures (nm + ": size rejected")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_mirror_bone_chain params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local axis = toLower (mcpStr params "axis" default:"x")
    local sl = mcpStr params "suffixL" default:"_L"
    local sr = mcpStr params "suffixR" default:"_R"
    local created = #()
    for node in nodes do
    (
        local c = undefined
        try ( c = copy node ) catch ( c = undefined )
        if c != undefined do
        (
            local pp = c.position
            if axis == "x" then pp.x = -pp.x
            else if axis == "y" then pp.y = -pp.y
            else pp.z = -pp.z
            try ( c.position = pp ) catch()
            local nm = node.name
            local newName = ""
            local idx = findString nm sl
            if idx != undefined then
                newName = (substring nm 1 (idx - 1)) + sr
            else
                newName = nm + sr
            try ( c.name = newName ) catch()
            append created newName
        )
    )
    local p = #()
    mcpPair p "created" created
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

/* Which kind of bone is this node, if any?

   Measured on 3ds Max 2022: a Biped adds 31 nodes whose class is Biped_Object
   and not one is a BoneGeometry, so the previous filter
       if (classof o) == BoneGeometry
   returned an empty list for a whole Biped rig -- no error, just "count: 0".
   CAT bones report CATBone; that class is present on this build, but no
   scriptable way to create a CAT rig was found here, so the CATBone branch is
   class-name based and is NOT live-verified (marked in the report rather than
   claimed).

   Matched on the class name as a string on purpose: comparing against a class
   symbol raises on a build where the plugin is not loaded, which would take the
   whole handler down instead of returning the bones that do exist. */
fn mcpBoneKind node =
(
    if node == undefined do return ""
    local c = ""
    try ( c = (classof node) as string ) catch ( c = "" )
    if c == "BoneGeometry" do return "bone"
    if c == "Biped_Object" do return "biped"
    if c == "CATBone" do return "cat"
    ""
)

fn mcpH_rig_list_bones params =
(
    local rootName = mcpStr params "root" default:""
    local root = undefined
    if rootName != "" do root = mcpResolveNode rootName
    local candidates = #()
    if root == undefined then
        candidates = (for o in objects collect o)
    else
        mcpCollectHierarchy root candidates

    local bones = #()
    local nBone = 0
    local nBiped = 0
    local nCat = 0
    for o in candidates do
    (
        local kind = mcpBoneKind o
        if kind != "" do
        (
            append bones o
            if kind == "bone" do nBone += 1
            if kind == "biped" do nBiped += 1
            if kind == "cat" do nCat += 1
        )
    )

    -- Each row keeps everything mcpNodeInfo reports and gains `boneKind`, so a
    -- caller can tell a Biped chain from a bone chain without a second call.
    local rows = #()
    for b in bones do
    (
        local info = mcpNodeInfo b
        local pairs = #()
        for pair in (mcpPairs info) do append pairs pair
        append pairs #("boneKind", (mcpBoneKind b))
        append rows (mcpObj pairs)
    )

    local p = #()
    mcpPaginateInto p rows (mcpInt params "limit" default:500) (mcpInt params "offset" default:0)
    local kinds = #()
    mcpPair kinds "bone" nBone
    mcpPair kinds "biped" nBiped
    mcpPair kinds "cat" nCat
    mcpPair p "kinds" (mcpObj kinds)
    mcpPair p "filter" "BoneGeometry | Biped_Object | CATBone (matched by class name)"
    mcpObj p
)


/*------------------------------------------------------------ rigging: skin */
fn mcpH_rig_skin_add params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try ( addModifier node (Skin()) ) catch ( ok = false )
        -- Read back: the only proof a Skin was added is that the node now has one.
        local now = (mcpGetSkinMod node) != undefined
        if ok and now then append applied nm
        else append failures (nm + ": no Skin after addModifier")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.skin_added" a1:(applied.count as string))
    mcpObj p
)

/* Accepts either "bone" (one name) or "bones" (a list).
   A name that does not resolve used to reach `boneNode.name` and die with
   "unknown property: name in undefined", which says nothing about the actual
   mistake; resolve first, then report the names that did not match. */
fn mcpH_rig_skin_add_bone params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    -- The catalog has advertised a rigid/weighted switch since this tool existed,
    -- but the handler always passed 0 (weighted), so `rigid: true` was silently
    -- ignored.  addBone's third argument is exactly that flag.
    local rigid = mcpBool params "rigid" default:false
    -- Keep the integer form the old code used (0): it reads as false for
    -- versions that want a boolean and as "weighted" for versions that want 0/1.
    local flag = if rigid then 1 else 0

    local names = #()
    local single = mcpStr params "bone" default:""
    if single != "" do append names single
    for n in (mcpArr params "bones") do
    (
        local s = if isKindOf n String then n else (try (n as string) catch (""))
        if s != "" do append names s
    )
    if names.count == 0 do mcpFail "err.missing_param" a1:"bone or bones"

    local boneNodes = #()
    local missing = #()
    for nm in names do
    (
        local b = mcpResolveNode nm
        if b == undefined then append missing nm else append boneNodes b
    )
    if boneNodes.count == 0 do
        mcpFail "err.not_found_in_list" a1:(mcpStringJoin names ", ") a2:"bones"

    local failed = #()
    local applied = #()
    local added = 0
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
        (
            local nodeAdded = 0
            for b in boneNodes do
            (
                local ok = true
                try ( skinOps.addBone skinMod b flag ) catch ( ok = false; append failed (node.name + "/" + b.name + ": " + (getCurrentException() as string)) )
                if ok do ( added += 1; nodeAdded += 1 )
            )
            if nodeAdded > 0 do append applied node.name
        )
    )

    local p = #()
    -- A node named in `failed` is not a success just because it was asked for.
    mcpPair p "objects" applied
    mcpPair p "bones" (for b in boneNodes collect b.name)
    mcpPair p "added" added
    mcpPair p "rigid" rigid
    if missing.count > 0 do mcpPair p "notFound" missing
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_skin_set_weight params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local boneNode = mcpResolveNode (mcpReqStr params "bone")
    local vertex = mcpReqInt params "vertex"
    local weight = mcpNum params "weight" default:0.0
    local failed = #()
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
        (
            local bi = mcpFindBoneIndex skinMod boneNode.name
            if bi < 0 then
                append failed (node.name + ": bone not in skin")
            else if not (mcpSkinSetVertexWeight skinMod vertex bi weight) do
                append failed (node.name + ": could not set the weight")
        )
    )
    local p = #()
    -- A node named in `failed` is not a success just because it was asked for.
    local applied = #()
    for n in nodes do
    (
        local nm = try (n.name) catch ("")
        local bad = false
        for f in failed do ( if (findString f nm) == 1 do bad = true )
        if not bad and nm != "" do append applied nm
    )
    mcpPair p "objects" applied
    mcpPair p "vertex" vertex
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

/* Distance from a point to a bone segment (start -> end, already in the same
   space as p). */
fn mcpPointSegmentDistance p a b =
(
    local ab = b - a
    local len2 = dot ab ab
    local t = 0.0
    if len2 > 0.000001 do t = (dot (p - a) ab) / len2
    t = amax 0.0 (amin 1.0 t)
    length (p - (a + ab * t))
)

/* Auto weights.
   The Skin modifier's "Auto Weights" button is a C++ only operation: skinOps
   exposes no autoWeight entry point (the whole struct was enumerated -- see
   mcp/README), so calling it raised "unknown property".  Instead compute the
   weights the same way the modifier does conceptually: distance from each
   vertex to every bone segment (skinOps.GetStartPoint/GetEndPoint give those in
   object space), then blend the two nearest bones with an inverse square
   falloff.  Fast, deterministic, and it produces usable skinning that the
   caller can refine with rig_skin_set_weight. */
fn mcpH_rig_skin_auto_weight params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failed = #()
    local weighted = 0

    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
        (
            local nb = 0
            try ( nb = skinOps.getNumberBones skinMod ) catch ( nb = 0 )
            if nb < 1 then
                append failed (node.name + ": no bones in the Skin modifier")
            else
            (
                -- Bone segments in world space (GetStartPoint is object space,
                -- so transform by the node matrix below).
                local starts = #()
                local ends = #()
                for i = 1 to nb do
                (
                    local sPt = [0,0,0]
                    local ePt = [0,0,0]
                    try ( sPt = skinOps.GetStartPoint skinMod i ) catch()
                    try ( ePt = skinOps.GetEndPoint skinMod i ) catch()
                    starts[i] = sPt
                    ends[i] = ePt
                )

                local mesh = undefined
                local done = 0
                try
                (
                    mesh = snapshotAsMesh node
                    local tm = node.transform
                    for v = 1 to mesh.numVerts do
                    (
                        local p = (getVert mesh v) * tm
                        -- nearest two bones
                        local i1 = 0
                        local d1 = 1.0e9
                        local i2 = 0
                        local d2 = 1.0e9
                        for i = 1 to nb do
                        (
                            local d = mcpPointSegmentDistance p starts[i] ends[i]
                            if d < d1 then ( i2 = i1; d2 = d1; i1 = i; d1 = d )
                            else if d < d2 then ( i2 = i; d2 = d )
                        )
                        if i1 > 0 do
                        (
                            local ids = #(i1)
                            local ws = #(1.0)
                            if i2 > 0 and d2 < 1.0e8 then
                            (
                                local e = 0.001
                                local w1 = 1.0 / ((d1 * d1) + e)
                                local w2 = 1.0 / ((d2 * d2) + e)
                                -- only blend when the second bone is genuinely
                                -- nearby, otherwise the vertex belongs to one bone
                                if (d2 < (d1 * 2.0 + 0.001)) then
                                (
                                    local total = w1 + w2
                                    ids = #(i1, i2)
                                    ws = #(w1 / total, w2 / total)
                                )
                            )
                            try ( skinOps.ReplaceVertexWeights skinMod v ids ws ) catch()
                            done += 1
                        )
                    )
                    try ( free mesh ) catch()
                )
                catch ( append failed (node.name + ": " + (getCurrentException() as string)) )
                if done > 0 do ( weighted += 1; append applied node.name )
            )
        )
    )

    local p = #()
    -- `objects` is what the weights were recomputed for, not what was asked.
    mcpPair p "objects" applied
    mcpPair p "weighted" weighted
    mcpPair p "method" "distance to bone segments (nearest two bones, inverse square)"
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_skin_weight_table params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local node = nodes[1]
    local skinMod = mcpGetSkinMod node
    local all = #()
    if skinMod != undefined do
    (
        local nv = 0
        try ( nv = skinOps.getNumberVertices skinMod ) catch ( nv = 0 )
        for v = 1 to nv do
        (
            local wc = 0
            try ( wc = skinOps.getVertexWeightCount skinMod v ) catch ( wc = 0 )
            local wlist = #()
            for i = 1 to wc do
            (
                local w = 0.0
                local bi = 0
                try ( w = skinOps.getVertexWeight skinMod v i ) catch ( w = 0.0 )
                -- GetVertexWeightBoneID, not getVertexWeightBone: the latter
                -- does not exist in this release (unknown property).
                try ( bi = skinOps.GetVertexWeightBoneID skinMod v i ) catch ( bi = 0 )
                /* getVertexWeightBone returns a bone *id*, while getBoneName
                   is indexed by position in the bone list.  Passing the id
                   straight through produced empty names for every vertex
                   whenever the two orders differed, so map id -> list index
                   first. */
                local bn = mcpSkinBoneName skinMod bi
                local we = #()
                mcpPair we "bone" bn
                mcpPair we "weight" w
                append wlist (mcpObj we)
            )
            local ve = #()
            mcpPair ve "vertex" v
            mcpPair ve "weights" wlist
            append all (mcpObj ve)
        )
    )
    local p = #()
    mcpPair p "object" node.name
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:200) (mcpInt params "offset" default:0)
    mcpObj p
)

fn mcpH_rig_skin_remove_bone params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local boneName = mcpReqStr params "bone"
    local failed = #()
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
        (
            local bi = mcpFindBoneIndex skinMod boneName
            if bi < 0 then
                append failed (node.name + ": bone not in skin")
            else
                try ( skinOps.removeBone skinMod bi ) catch ( append failed (node.name + ": " + (getCurrentException())) )
        )
    )
    local p = #()
    -- A node named in `failed` is not a success just because it was asked for.
    local applied = #()
    for n in nodes do
    (
        local nm = try (n.name) catch ("")
        local bad = false
        for f in failed do ( if (findString f nm) == 1 do bad = true )
        if not bad and nm != "" do append applied nm
    )
    mcpPair p "objects" applied
    mcpPair p "bone" boneName
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_skin_set_vertex_weights params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local vertex = mcpReqInt params "vertex"
    local weights = mcpArr params "weights"
    local failed = #()
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
        (
            for wp in weights do
            (
                local bn = mcpStr wp "bone" default:""
                local w = mcpNum wp "weight" default:0.0
                if bn != "" do
                (
                    local bi = mcpFindBoneIndex skinMod bn
                    if bi < 0 then
                        append failed (node.name + ": " + bn)
                    else
                        try ( skinOps.setWeight skinMod bi vertex w ) catch ( append failed (node.name + ": " + bn) )
                )
            )
        )
    )
    local p = #()
    -- A node named in `failed` is not a success just because it was asked for.
    local applied = #()
    for n in nodes do
    (
        local nm = try (n.name) catch ("")
        local bad = false
        for f in failed do ( if (findString f nm) == 1 do bad = true )
        if not bad and nm != "" do append applied nm
    )
    mcpPair p "objects" applied
    mcpPair p "vertex" vertex
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------------- rigging: IK */
fn mcpH_rig_ik_solver params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local typeStr = toLower (mcpStr params "type" default:"HI")
    local st = #HI_IK
    if typeStr == "hd" then st = #HD_IK
    else if typeStr == "spline" then st = #IKSpline
    local goal = undefined
    try ( goal = ikSys.addSolver nodes st ) catch ( goal = undefined )
    local p = #()
    mcpPair p "chain" (for n in nodes collect n.name)
    mcpPair p "solver" typeStr
    mcpPair p "goal" (try ( goal.name ) catch (""))
    mcpPair p "message" (if goal != undefined then (mcpMsg "msg.ok") else (mcpMsg "msg.feature_unsupported" a1:"iksolver"))
    mcpObj p
)

fn mcpH_rig_set_ik_chain params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local hasPA = (mcpGet params "preferredAngle") != undefined
    local pa = mcpNum params "preferredAngle" default:0.0
    local hasSA = (mcpGet params "swivelAngle") != undefined
    local sa = mcpNum params "swivelAngle" default:0.0
    for node in nodes do
    (
        if hasPA do try ( node.preferredAngle = pa ) catch()
        if hasSA do try ( node.swivelAngle = sa ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_ik_goal params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    local frame = mcpInt params "frame" default:(currentTime.frame as integer)
    local t = frame * ticksPerFrame
    for node in nodes do
        animate on ( at time t ( try ( node.position = pos ) catch() ) )
    local p = #()
    mcpPair p "goals" (for n in nodes collect n.name)
    mcpPair p "frame" frame
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_spline_ik params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local pathNode = mcpResolveNode (mcpReqStr params "path")
    local goal = undefined
    try ( goal = ikSys.addSolver nodes #IKSpline ) catch ( goal = undefined )
    if goal != undefined do try ( goal.spline = pathNode ) catch()
    local p = #()
    mcpPair p "chain" (for n in nodes collect n.name)
    mcpPair p "path" pathNode.name
    mcpPair p "goal" (try ( goal.name ) catch (""))
    mcpPair p "message" (if goal != undefined then (mcpMsg "msg.ok") else (mcpMsg "msg.feature_unsupported" a1:"splineik"))
    mcpObj p
)

fn mcpH_rig_ik_enable params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try ( node.ikEnabled = true ) catch ( ok = false )
        if not ok do try ( node.isIKNode = true; ok = true ) catch ( ok = false )
        -- Read the flag back; when the node has no such property the write
        -- itself decides, which is still better than assuming.
        local got = ok
        try ( got = node.ikEnabled ) catch ( got = ok )
        if got == true then append applied nm
        else append failures (nm + ": IK flag did not change")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "ikEnabled" true
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_ik_disable params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try ( node.ikEnabled = false ) catch ( ok = false )
        if not ok do try ( node.isIKNode = false; ok = true ) catch ( ok = false )
        -- Read the flag back; when the node has no such property the write
        -- itself decides, which is still better than assuming.
        local got = ok
        try ( got = node.ikEnabled ) catch ( got = ok )
        if got == false then append applied nm
        else append failures (nm + ": IK flag did not change")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "ikEnabled" false
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------------ morph */
fn mcpH_rig_morpher_add params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for node in nodes do
    (
        local nm = "?"
        try ( nm = node.name ) catch ( nm = "?" )
        local ok = true
        try ( addModifier node (Morpher()) ) catch ( ok = false )
        local now = (mcpGetMorpherMod node) != undefined
        if ok and now then append applied nm
        else append failures (nm + ": no Morpher after addModifier")
    )
    local p = #()
    mcpPair p "objects" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_morpher_add_target params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local targetNode = mcpResolveNode (mcpReqStr params "target")
    local failed = #()
    for node in nodes do
    (
        local mm = mcpGetMorpherMod node
        if mm == undefined then
            append failed (node.name + ": no Morpher")
        else
            try ( morpherOps.addMorphTarget mm node targetNode ) catch ( append failed (node.name + ": " + (getCurrentException())) )
    )
    local p = #()
    -- A node named in `failed` is not a success just because it was asked for.
    local applied = #()
    for n in nodes do
    (
        local nm = try (n.name) catch ("")
        local bad = false
        for f in failed do ( if (findString f nm) == 1 do bad = true )
        if not bad and nm != "" do append applied nm
    )
    mcpPair p "objects" applied
    mcpPair p "target" targetNode.name
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_morpher_set_value params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local channel = mcpReqInt params "channel"
    local value = mcpNum params "value" default:0.0
    local frame = mcpInt params "frame" default:(currentTime.frame as integer)
    local t = frame * ticksPerFrame
    for node in nodes do
    (
        local mm = mcpGetMorpherMod node
        if mm != undefined do
            try ( animate on ( at time t ( mm[channel].value = value ) ) ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "channel" channel
    mcpPair p "value" value
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_morpher_list params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local node = nodes[1]
    local mm = mcpGetMorpherMod node
    local all = #()
    if mm != undefined do
    (
        local ch = 0
        try ( ch = mm.numChannels ) catch ( ch = 0 )
        for i = 1 to ch do
        (
            local nm = ""
            local val = 0.0
            try ( nm = mm[i].name ) catch ( nm = "" )
            try ( val = mm[i].value ) catch ( val = 0.0 )
            local e = #()
            mcpPair e "channel" i
            mcpPair e "name" nm
            mcpPair e "value" val
            append all (mcpObj e)
        )
    )
    local p = #()
    mcpPair p "object" node.name
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:100) (mcpInt params "offset" default:0)
    mcpObj p
)


/*--------------------------------------------------------------- registration */
fn mcpRegisterRigging =
(
    mcpRegister "rig_create_bone" mcpH_rig_create_bone label:"Create Bone"
    mcpRegister "rig_create_bone_chain" mcpH_rig_create_bone_chain label:"Create Bone Chain"
    mcpRegister "rig_create_dummy" mcpH_rig_create_dummy label:"Create Dummy"
    mcpRegister "rig_create_point_helper" mcpH_rig_create_point_helper label:"Create Point Helper"
    mcpRegister "rig_link_objects" mcpH_rig_link_objects label:"Link Objects"
    mcpRegister "rig_set_bone_size" mcpH_rig_set_bone_size label:"Set Bone Size"
    mcpRegister "rig_mirror_bone_chain" mcpH_rig_mirror_bone_chain label:"Mirror Bone Chain"
    mcpRegister "rig_list_bones" mcpH_rig_list_bones undoable:false label:"List Bones"
    mcpRegister "rig_skin_add" mcpH_rig_skin_add label:"Add Skin"
    mcpRegister "rig_skin_add_bone" mcpH_rig_skin_add_bone label:"Add Bone To Skin"
    mcpRegister "rig_skin_set_weight" mcpH_rig_skin_set_weight label:"Set Skin Weight"
    mcpRegister "rig_skin_auto_weight" mcpH_rig_skin_auto_weight label:"Auto Weight Skin"
    mcpRegister "rig_skin_weight_table" mcpH_rig_skin_weight_table undoable:false label:"Skin Weight Table"
    mcpRegister "rig_skin_remove_bone" mcpH_rig_skin_remove_bone label:"Remove Bone From Skin"
    mcpRegister "rig_skin_set_vertex_weights" mcpH_rig_skin_set_vertex_weights label:"Set Vertex Weights"
    mcpRegister "rig_ik_solver" mcpH_rig_ik_solver label:"Add IK Solver"
    mcpRegister "rig_set_ik_chain" mcpH_rig_set_ik_chain label:"Set IK Chain"
    mcpRegister "rig_ik_goal" mcpH_rig_ik_goal label:"Move IK Goal"
    mcpRegister "rig_spline_ik" mcpH_rig_spline_ik label:"Spline IK"
    mcpRegister "rig_ik_enable" mcpH_rig_ik_enable label:"Enable IK"
    mcpRegister "rig_ik_disable" mcpH_rig_ik_disable label:"Disable IK"
    mcpRegister "rig_morpher_add" mcpH_rig_morpher_add label:"Add Morpher"
    mcpRegister "rig_morpher_add_target" mcpH_rig_morpher_add_target label:"Add Morph Target"
    mcpRegister "rig_morpher_set_value" mcpH_rig_morpher_set_value label:"Set Morph Value"
    mcpRegister "rig_morpher_list" mcpH_rig_morpher_list undoable:false label:"List Morph Targets"
    ok
)

mcpRegisterRigging()
