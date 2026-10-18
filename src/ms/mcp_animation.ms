/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_animation.ms
   Keyframes, playback / time, controllers / wiring, constraints.

   Category: animation (bridge command names anim_*, ctrl_*, constraint_*)

   Hard rules honoured:
     * No struct, no closures / lambdas, no trailing-backslash continuations.
     * Frame values are converted with `frame * ticksPerFrame` so nothing assumes
       30 fps - the scene frame rate is always respected.
     * Undo is handled centrally by the dispatcher; we never call theHold here.
     * Every user visible string goes through mcpMsg or a bilingual
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
                    if k != undefined do try ( deleteKey ctrl k ) catch()
                )
            )
            else try ( deleteKeys ctrl #all ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        for pr in plist do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do try ( deleteKeys ctrl #all ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_anim_offset_keys params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local propName = mcpReqStr params "property"
    local dt = (mcpReqInt params "offset") * ticksPerFrame
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do
            for k in ctrl.keys do try ( k.time = k.time + dt ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do
            for k in ctrl.keys do try ( k.time = pt + (k.time - pt) * factor ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        if propName == "position" then
            try ( node.position.controller = (execute cls)() ) catch()
        else if propName == "rotation" then
            try ( node.rotation.controller = (execute cls)() ) catch()
        else if propName == "scale" then
            try ( node.scale.controller = (execute cls)() ) catch()
        else
        (
            local code = "$'" + node.name + "'." + propName + ".controller = (" + cls + ")()"
            try ( execute code ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        local ctrl = mcpGetAnimController node propName
        if ctrl != undefined do
        (
            local k = try ( getKey ctrl t ) catch (undefined)
            if k != undefined do
            (
                if inT != "" do try ( k.inTangentType = (mcpMapTangent inT) ) catch()
                if outT != "" do try ( k.outTangentType = (mcpMapTangent outT) ) catch()
                if (mcpGet params "inHandle") != undefined do try ( k.inTangent = (mcpNum params "inHandle") ) catch()
                if (mcpGet params "outHandle") != undefined do try ( k.outTangent = (mcpNum params "outHandle") ) catch()
            )
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
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
        for pr in props do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do ( try ( c = c + ctrl.keys.count ) catch() )
        )
        totalKeys = totalKeys + c
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in all do
    (
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
        for pr in props do
        (
            local ctrl = mcpGetAnimController node pr
            if ctrl != undefined do ( try ( c = c + ctrl.keys.count ) catch() )
        )
        totalKeys = totalKeys + c
    )
    local p = #()
    mcpPair p "roots" (for r in roots collect r.name)
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
    local p = #()
    mcpPair p "frame" frame
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
    for node in nodes do
    (
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
        catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_position params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local w = mcpNum params "weight" default:100.0
    for node in nodes do
    (
        try
        (
            node.position.controller = position_constraint()
            node.position.controller.appendTarget target w
        )
        catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "target" target.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_orientation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local w = mcpNum params "weight" default:100.0
    for node in nodes do
    (
        try
        (
            node.rotation.controller = orientation_constraint()
            node.rotation.controller.appendTarget target w
        )
        catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        try
        (
            node.position.controller = path_constraint()
            local pc = node.position.controller
            pc.path = pathNode
            try ( pc.follow = follow ) catch()
            try ( pc.percent = pct ) catch()
        )
        catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "path" pathNode.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_constraint_link params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local target = mcpResolveNode (mcpReqStr params "target")
    local f = mcpInt params "frame" default:(currentTime.frame as integer)
    for node in nodes do
    (
        try
        (
            node.position.controller = link_constraint()
            node.position.controller.addTarget target (f * ticksPerFrame)
        )
        catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        local ok = false
        try ( node.position.controller = surface(); ok = true ) catch()
        if not ok do try ( node.position.controller = surface_constraint(); ok = true ) catch()
        if ok do
        (
            local sc = node.position.controller
            try ( sc.surface = targetNode ) catch()
            try ( sc.u = u; sc.v = v ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
    (
        if propName == "position" then
            try ( node.position.controller = bezier_position() ) catch()
        else if propName == "rotation" then
            try ( node.rotation.controller = bezier_rotation() ) catch()
        else if propName == "scale" then
            try ( node.scale.controller = bezier_scale() ) catch()
        else
        (
            local code = "$'" + node.name + "'." + propName + ".controller = bezier_float()"
            try ( execute code ) catch()
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
