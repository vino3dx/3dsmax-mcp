/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_objects.ms
   Objects: primitives, splines, transforms, hierarchy, selection & query,
   visibility & lifecycle, booleans.

   Category: objects

   Every handler is registered with mcpRegisterObjects() at the bottom of this
   file.  Primitive and spline wrappers funnel into a single generic handler
   driven by a "class" preset, so one MAXScript fn serves many catalog tools.
   No structs, no closures, no trailing-backslash continuations - only the
   constructs listed in section 4.1 of BRIDGE_CONVENTIONS.md.
-----------------------------------------------------------------------------*/

global mcpH_create_primitive, mcpH_create_spline, mcpH_create_line
global mcpH_spline_get_points, mcpH_spline_set_points
global mcpH_transform_object, mcpH_align_objects, mcpH_mirror_object, mcpH_set_pivot
global mcpH_reset_transform, mcpH_snap_objects_to_grid, mcpH_scatter_objects
global mcpH_parent_objects, mcpH_unparent_objects, mcpH_get_hierarchy, mcpObjHierarchyNode
global mcpH_group_objects, mcpH_ungroup_objects, mcpH_open_group, mcpH_close_group
global mcpH_list_objects, mcpH_find_objects, mcpH_get_object_info, mcpH_get_selection
global mcpH_select_objects, mcpH_deselect_all, mcpH_select_all, mcpH_select_by_superclass
global mcpH_hide_objects, mcpH_unhide_all, mcpH_unhide_objects
global mcpH_freeze_objects, mcpH_unfreeze_all, mcpH_rename_object, mcpH_delete_objects
global mcpH_clone_objects, mcpH_array_objects, mcpH_attach_objects, mcpH_detach_elements
global mcpH_count_objects, mcpH_boolean_operation, mcpH_proboolean
global mcpBooleanOpCode, mcpBooleanOpName, mcpBooleanRun, mcpBooleanPayload
global mcpH_place_on_surface, mcpH_place_relative, mcpH_distribute_along_spline, mcpH_check_overlaps
global mcpDropNodeToSurface, mcpPoint3ToArr
global mcpObjL


/*---------------------------------------------- local locale helper (no mcp_core edits)
   For strings that have no existing mcpMessages key, return zh or en based on
   mcpLang.  Kept tiny and dependency free. */
fn mcpObjL zh en =
(
    if mcpLang == "en" then en else zh
)

fn mcpPoint3ToArr pt =
(
    if pt == undefined then #(0.0, 0.0, 0.0)
    else #((pt.x as float), (pt.y as float), (pt.z as float))
)


/*------------------------------------------------------ read-back state helper
   "hide nodes" returning without an exception only proves the call ran; it does
   not prove the objects are hidden (they may sit on a layer that overrides it,
   or already have been hidden).  Read the flag back and report the two groups,
   so the tool answers what the scene says instead of what the request asked
   for.  `miss` doubles as the failure list the runtime reads. */
fn mcpSplitByFlag nodes flagName want =
(
    local hit = #()
    local miss = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local value = undefined
        try ( value = getProperty n flagName ) catch ( value = undefined )
        if value == want then append hit nm else append miss nm
    )
    #(hit, miss)
)


/*----------------------------------------------- per-object action with failures
   For operations that have no cheap flag to read back, the same shape is
   written inline: run the call per object so one bad object cannot take the
   whole batch down, and name the ones that threw instead of swallowing them.
   Inline rather than a shared helper because MAXScript has no closures, and a
   helper would have to switch on an operation name - which hides the one thing
   that matters here: which call is being made. */


/* Set a numeric/boolean property and read it back.  Returns "" on success or a
   message naming what the scene kept instead of what was asked for - a spline
   silently rejects some radius/side combinations, and the old `try (...) catch()`
   turned that into a cheerful "Created." */
fn mcpSetPropVerified obj propName want =
(
    local wantNum = want as float
    try ( setProperty obj propName wantNum ) catch ( return (propName + ": not settable on " + ((classof obj) as string)) )
    local got = undefined
    try ( got = getProperty obj propName ) catch ( return (propName + ": not readable back") )
    if got == undefined do return (propName + ": rejected")
    if (abs ((got as float) - wantNum)) > 0.0001 do return (propName + ": kept " + (got as string))
    ""
)

/*------------------------------------------------------------------- primitives*/
-- Generic primitive creator.  `class` arrives via the catalog preset or the
-- `class` argument of create_primitive.  Dimension params are applied with
-- try/catch so a property missing on some Max version never throws.
fn mcpH_create_primitive params =
(
    local cls = mcpStr params "class" default:""
    if cls == "" do cls = mcpStr params "preset_class" default:""
    if cls == "" do mcpFail "err.missing_param" a1:"class"
    if not (mcpClassExists cls) do mcpFail "err.class_missing" a1:cls

    local obj = execute (cls + "()")
    if obj == undefined do mcpFail "err.bad_value" a1:cls
    if not (isValidNode obj) do mcpFail "err.bad_value" a1:(cls + " returned no node")

    local failures = #()
    local warnings = #()
    local nm = mcpStr params "name" default:""
    if nm == "" do nm = mcpStr params "setName" default:""
    if nm != "" do
    (
        try ( obj.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        -- Max keeps a unique variant when the name is taken; say so instead of
        -- letting the caller believe the requested name is what exists.
        if obj.name != nm do append warnings ("name: scene kept " + obj.name)
    )

    local pos = mcpGet params "position"
    if pos != undefined do ( try ( obj.position = (mcpPoint3From pos) ) catch ( append failures ("position: " + (getCurrentException() as string)) ) )

    local dimProps = #("length","width","height","depth","radius","radius1","radius2","segments",
                       "sides","chamfer","fillet","turns","heightSegs","widthSegs","lengthSegs",
                       "capSegs","cornerRadius","from","to","genSmooth","axis")
    for pn in dimProps do
    (
        if (mcpGet params pn) != undefined do
        (
            local problem = mcpSetPropVerified obj pn (mcpNum params pn)
            if problem != "" do append failures problem
        )
    )

    -- Boolean dimension props must go through mcpBool: mcpNum maps a JSON
    -- true to its default 0.0 (a Boolean is not a Number in MAXScript), which
    -- silently turned smooth=true into smooth=false on the Teapot.
    local boolProps = #("smooth")
    for pn in boolProps do
    (
        if (mcpGet params pn) != undefined do
        (
            local problem = mcpSetPropVerified obj pn (mcpBool params pn)
            if problem != "" do append failures problem
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "object" (mcpNodeInfo obj)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:obj.name)
    mcpObj p
)


/*--------------------------------------------------------------------- splines*/
-- Generic spline creator for everything except Line (which needs points).
fn mcpH_create_spline params =
(
    local cls = mcpStr params "class" default:""
    if cls == "" do mcpFail "err.missing_param" a1:"class"
    if not (mcpClassExists cls) do mcpFail "err.class_missing" a1:cls

    local obj = execute (cls + "()")
    if obj == undefined do mcpFail "err.bad_value" a1:cls

    local failures = #()
    local warnings = #()

    local nm = mcpStr params "name" default:""
    if nm != "" do
    (
        try ( obj.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        -- Max silently keeps a unique variant when the name is taken; report the
        -- name the scene actually holds instead of the one that was requested.
        if obj.name != nm do append warnings ("name: scene kept " + obj.name)
    )

    local pos = mcpGet params "position"
    if pos != undefined do
    (
        try ( obj.position = (mcpPoint3From pos) ) catch ( append failures ("position: " + (getCurrentException() as string)) )
    )

    local txt = mcpStr params "text" default:""
    if txt != "" do
    (
        try ( obj.text = txt ) catch ( append failures ("text: " + (getCurrentException() as string)) )
        local gotTxt = ""
        try ( gotTxt = obj.text ) catch ( gotTxt = "" )
        if gotTxt != txt do append failures ("text: scene kept " + gotTxt)
    )

    local dimProps = #("length","width","radius","radius1","radius2","sides","segments",
                       "height","turns","from","to","cornerRadius","size","thickness","angle","genSmooth")
    for pn in dimProps do
    (
        if (mcpGet params pn) != undefined do
        (
            local problem = mcpSetPropVerified obj pn (mcpNum params pn)
            if problem != "" do append failures problem
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "object" (mcpNodeInfo obj)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:obj.name)
    mcpObj p
)


fn mcpH_create_line params =
(
    local pts = mcpArr params "points"
    if pts.count == 0 do mcpFail "err.missing_param" a1:"points"
    local closed = mcpBool params "closed" default:false

    -- NOTE: SplineShape + addNewSpline + addKnot is the working spline API
    -- (verified live on 2020); setNumSplines / addPoint do not exist and made
    -- this handler fail with "Call needs function or class, got: undefined".
    local obj = SplineShape()
    addNewSpline obj
    local failures = #()
    local warnings = #()
    for i = 1 to pts.count do
    (
        try ( addKnot obj 1 #corner #line (mcpPoint3From pts[i]) )
        catch ( append failures ("point " + (i as string) + ": " + (getCurrentException() as string)) )
    )

    -- A line whose knots did not land is not a created line.  Compare against the
    -- request instead of trusting addKnot's silence.
    local knots = 0
    try ( knots = numKnots obj 1 ) catch ( knots = 0 )
    if knots != pts.count do append failures ("knots: asked for " + (pts.count as string) + ", scene has " + (knots as string))

    if closed do
    (
        try ( close obj 1 ) catch ( append failures ("closed: " + (getCurrentException() as string)) )
    )

    local nm = mcpStr params "name" default:""
    if nm != "" do
    (
        try ( obj.name = nm ) catch ( append failures ("name: " + (getCurrentException() as string)) )
        if obj.name != nm do append warnings ("name: scene kept " + obj.name)
    )

    local pos = mcpGet params "position"
    if pos != undefined do
    (
        try ( obj.position = obj.position + (mcpPoint3From pos) ) catch ( append failures ("position: " + (getCurrentException() as string)) )
    )

    updateShape obj
    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0)
    mcpPair p "object" (mcpNodeInfo obj)
    mcpPair p "failures" failures
    mcpPair p "warnings" warnings
    mcpPair p "message" (mcpMsg "msg.created" a1:obj.name)
    mcpObj p
)


fn mcpH_spline_get_points params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local out = #()
    for n in nodes do
    (
        local pts = #()
        try
        (
            for s = 1 to (numSplines n) do
                for k = 1 to (numKnots n s) do
                    append pts (getKnotPoint n s k)
        )
        catch()
        local entry = #()
        mcpPair entry "name" n.name
        mcpPair entry "points" pts
        append out (mcpObj entry)
    )
    local p = #()
    mcpPair p "objects" out
    mcpObj p
)


fn mcpH_spline_set_points params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local pts = mcpArr params "points"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        local written = 0
        try
        (
            if (numSplines n) == 0 do setNumSplines n 1
            local count = numKnots n 1
            local take = min count (pts.count)
            for k = 1 to take do
            (
                try ( setKnotPoint n 1 k (mcpPoint3From pts[k]); written = written + 1 ) catch()
            )
            for k = (take + 1) to (pts.count) do
            (
                try ( addPoint n (mcpPoint3From pts[k]); written = written + 1 ) catch()
            )
            updateShape n
        )
        catch ( ok = false )
        if not ok then append failures (nm + ": shape rejected the points")
        else if pts.count > 0 and written == 0 then append failures (nm + ": no point was written")
        else append applied nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------------ transforms*/
fn mcpH_transform_object params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local op = mcpStr params "operation" default:"move"
    local space = mcpStr params "space" default:"world"
    local mode = mcpStr params "mode" default:"relative"
    local val = mcpPoint3From (mcpGet params "value") default:[0,0,0]

    for n in nodes do
    (
        if op == "move" then
        (
            try
            (
                if mode == "absolute" then n.position = val
                else n.position = n.position + val
            )
            catch()
        )
        else if op == "scale" then
        (
            try
            (
                if mode == "absolute" then n.scale = val
                else n.scale = [n.scale.x * val.x, n.scale.y * val.y, n.scale.z * val.z]
            )
            catch()
        )
        else if op == "rotate" then
        (
            try
            (
                local rt = mcpStr params "rotationType" default:"euler"
                local q = undefined
                if rt == "axisangle" then
                (
                    local ax = mcpPoint3From (mcpGet params "axis") default:[0,0,1]
                    if (length ax) < 1e-6 do ax = [0,0,1]
                    local ang = mcpNum params "angle" default:0
                    q = quat (degToRad ang) (normalize ax)
                )
                else
                (
                    q = (eulerAngles val.x val.y val.z) as quat
                )
                if mode == "absolute" then n.rotation = q
                else n.rotation = (n.rotation as quat) * q
            )
            catch()
        )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_align_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local targetName = mcpStr params "target" default:""
    local target = mcpResolveNode targetName
    if target == undefined do mcpFail "err.node_not_found" a1:targetName

    local doPos = mcpBool params "position" default:true
    local doRot = mcpBool params "rotation" default:false
    local doScale = mcpBool params "scale" default:false
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if doPos do
            (
                n.position = target.position
                -- A locked transform or a driven controller can reject the
                -- assignment without throwing, so read the position back.
                if (distance n.position target.position) > 0.001 do
                    mcpFail "err.bad_value" a1:("position kept " + (n.position as string))
            )
            if doScale do
            (
                n.scale = target.scale
                local s = n.scale
                local t = target.scale
                if (abs (s.x - t.x)) > 0.001 or (abs (s.y - t.y)) > 0.001 or (abs (s.z - t.z)) > 0.001 do
                    mcpFail "err.bad_value" a1:("scale kept " + (s as string))
            )
            if doRot do ( n.rotation = target.rotation )
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok then append applied nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "target" target.name
    -- `aligned` used to be the request list, so a locked node still counted as
    -- aligned.  It is now what the scene agreed to.
    mcpPair p "aligned" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_mirror_object params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local axis = mcpStr params "axis" default:"x"
    local offset = mcpNum params "offset" default:0.0
    local cloneType = mcpStr params "cloneType" default:"none"

    -- Per object, so a locked node cannot abort the rest of the set and the
    -- caller learns which ones were skipped instead of just "Done.".
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            local mirrored = n
            if cloneType == "copy" then mirrored = copy n
            else if cloneType == "instance" then mirrored = instance n
            if mirrored == undefined or not (isValidNode mirrored) do
                mcpFail "err.bad_value" a1:"clone returned no node"

            local mp = mirrored.position
            if axis == "x" then
            (
                mp.x = (2.0 * offset) - mp.x
                try ( mirrored.scale = [-mirrored.scale.x, mirrored.scale.y, mirrored.scale.z] ) catch()
            )
            else if axis == "y" then
            (
                mp.y = (2.0 * offset) - mp.y
                try ( mirrored.scale = [mirrored.scale.x, -mirrored.scale.y, mirrored.scale.z] ) catch()
            )
            else
            (
                mp.z = (2.0 * offset) - mp.z
                try ( mirrored.scale = [mirrored.scale.x, mirrored.scale.y, -mirrored.scale.z] ) catch()
            )
            mirrored.position = mp
            if (distance mirrored.position mp) > 0.001 do
                mcpFail "err.bad_value" a1:"mirrored position did not stick"
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok do append applied nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_set_pivot params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local mode = mcpStr params "mode" default:"place"
    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if mode == "center" then centerPivot n
            else if mode == "origin" then n.pivot = [0,0,0]
            else n.pivot = pos
        )
        catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_reset_transform params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local rot = mcpBool params "rotation" default:true
    local scl = mcpBool params "scale" default:true
    local pos = mcpBool params "position" default:false
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if rot do n.rotation = (eulerAngles 0 0 0)
            if scl do n.scale = [1,1,1]
            if pos do n.position = [0,0,0]
        )
        catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_snap_objects_to_grid params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spacing = mcpNum params "spacing" default:10.0
    if spacing <= 0 do spacing = 10.0
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            n.position = [ (floor (n.position.x / spacing + 0.5)) * spacing,
                           (floor (n.position.y / spacing + 0.5)) * spacing,
                           (floor (n.position.z / spacing + 0.5)) * spacing ]
        )
        catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_scatter_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local count = mcpInt params "count" default:nodes.count
    if count < 1 do count = 1
    local region = mcpStr params "region" default:"box"
    local center = mcpPoint3From (mcpGet params "center") default:[0,0,0]
    local size = mcpPoint3From (mcpGet params "size") default:[100,100,100]
    local seedVal = mcpInt params "seed" default:12345
    local doRot = mcpBool params "randomRotation" default:true
    local doScale = mcpBool params "randomScale" default:false
    local sMin = mcpNum params "scaleMin" default:0.8
    local sMax = mcpNum params "scaleMax" default:1.2
    local surfaceName = mcpStr params "surface" default:""
    local surfaceNode = undefined
    if surfaceName != "" do surfaceNode = mcpResolveNode surfaceName

    seed seedVal
    local created = #()
    local failures = #()
    for i = 1 to count do
    (
        local proto = nodes[((i - 1) mod nodes.count) + 1]
        try
        (
            local obj = copy proto
            if obj == undefined or not (isValidNode obj) do mcpFail "err.bad_value" a1:"copy returned no node"
            local px = center.x + (random (-0.5 * size.x) (0.5 * size.x))
            local py = center.y + (random (-0.5 * size.y) (0.5 * size.y))
            local pz = center.z + (random (-0.5 * size.z) (0.5 * size.z))

            if region == "surface" then
            (
                -- Asking for surface placement and silently leaving the copy in
                -- mid-air is the one thing this mode must not do.
                if surfaceNode == undefined do mcpFail "err.node_not_found" a1:surfaceName
                local rayHit = intersectRay surfaceNode (ray [px, py, 1e6] [0,0,-1])
                if rayHit == undefined do mcpFail "err.bad_value" a1:"ray missed the surface"
                px = rayHit.pos.x
                py = rayHit.pos.y
                pz = rayHit.pos.z
            )

            obj.position = [px, py, pz]
            if doRot do ( try ( obj.rotation = (eulerAngles (random -180.0 180.0) (random -180.0 180.0) (random -180.0 180.0)) as quat ) catch() )
            if doScale do
            (
                local sc = random sMin sMax
                obj.scale = [sc, sc, sc]
            )
            append created obj.name
        )
        catch ( append failures ("instance " + (i as string) + ": " + (getCurrentException() as string)) )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "count" created.count
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.created" a1:(created.count as string))
    mcpObj p
)


/*------------------------------------------------------------------ hierarchy*/
fn mcpH_parent_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local parentName = mcpStr params "parent" default:""
    local parent = mcpResolveNode parentName
    if parent == undefined do mcpFail "err.node_not_found" a1:parentName

    local keep = mcpBool params "keepTransform" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if keep then
            (
                local w = n.transform
                n.parent = parent
                n.transform = w
            )
            else n.parent = parent
            -- A parent assignment can be refused (cycle, locked hierarchy);
            -- `children` used to echo the request so it looked like it worked.
            if n.parent != parent do mcpFail "err.bad_value" a1:"parent not changed"
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok then append applied nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "parent" parent.name
    mcpPair p "children" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.hierarchy" a1:parent.name)
    mcpObj p
)


fn mcpH_unparent_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local keep = mcpBool params "keepTransform" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            if keep then
            (
                local w = n.transform
                n.parent = undefined
                n.transform = w
            )
            else n.parent = undefined
        )
        catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpObjHierarchyNode node =
(
    local p = #()
    mcpPair p "name" (try ( node.name ) catch ( "" ))
    mcpPair p "class" (try ( (classof node) as string ) catch ( "" ))
    mcpPair p "superClass" (mcpSuperclass node)
    local kids = #()
    try ( for c in node.children do append kids (mcpObjHierarchyNode c) ) catch()
    mcpPair p "children" kids
    mcpObj p
)


fn mcpH_get_hierarchy params =
(
    local rootName = mcpStr params "root" default:""
    if rootName == "" or rootName == "scene" then
    (
        local p = #()
        mcpPair p "name" "scene"
        mcpPair p "class" "Scene"
        mcpPair p "superClass" ""
        local kids = #()
        try ( for n in objects do ( if n.parent == undefined do append kids (mcpObjHierarchyNode n) ) ) catch()
        mcpPair p "children" kids
        mcpObj p
    )
    else
    (
        local root = mcpResolveNode rootName
        if root == undefined do mcpFail "err.node_not_found" a1:rootName
        mcpObjHierarchyNode root
    )
)


fn mcpH_group_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if nodes.count == 0 do mcpFail "err.no_selection"
    local g = group nodes
    local nm = mcpStr params "name" default:""
    if nm != "" do ( try ( g.name = nm ) catch() )
    local p = #()
    mcpPair p "group" g.name
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_ungroup_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    -- Collect what actually got ungrouped: the old loop swallowed every error,
    -- so a selection of plain meshes answered "ok" while nothing changed.
    local ungrouped = #()
    local failures = #()
    for n in nodes do
    (
        local nm = ""
        try ( nm = n.name ) catch ( nm = "" )
        local ok = true
        try ( ungroup n ) catch ( ok = false )
        if ok then append ungrouped nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "ungrouped" ungrouped
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_open_group params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try ( setGroupOpen n true ) catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_close_group params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try ( setGroupOpen n false ) catch ( ok = false )
        if ok then append applied nm else append failures nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------- selection & query*/
fn mcpH_list_objects params =
(
    local sc = mcpStr params "superClass" default:""
    local cls = mcpStr params "class" default:""
    local layer = mcpStr params "layer" default:""
    local pat = mcpStr params "namePattern" default:""
    local typ = mcpStr params "type" default:""
    local all = #()
    for i = 1 to objects.count do append all objects[i]

    local filtered = #()
    for n in all do
    (
        if sc != "" and (mcpSuperclass n) != sc do continue
        if typ != "" and (mcpSuperclass n) != typ do continue
        if cls != "" and ((classof n) as string) != cls do continue
        if layer != "" and (try ( n.layer.name ) catch ( "" )) != layer do continue
        if pat != "" and not (matchPattern n.name pattern:pat) do continue
        append filtered n
    )

    local total = filtered.count
    local limit = mcpInt params "limit" default:200
    local offset = mcpInt params "offset" default:0
    if limit < 0 do limit = 200
    if offset < 0 do offset = 0
    local last = offset + limit
    if last > total do last = total

    local page = #()
    for i = (offset + 1) to last do append page (mcpNodeInfo filtered[i])

    local p = #()
    mcpPair p "count" total
    mcpPair p "offset" offset
    mcpPair p "limit" limit
    mcpPair p "objects" page
    mcpObj p
)


fn mcpH_find_objects params =
(
    local pat = mcpStr params "name" default:""
    if pat == "" do pat = mcpStr params "pattern" default:""
    if pat == "" do mcpFail "err.missing_param" a1:"name"
    local exact = mcpBool params "exact" default:false

    local found = #()
    for i = 1 to objects.count do
    (
        local n = objects[i]
        if exact then
        (
            if n.name == pat do append found (mcpNodeInfo n)
        )
        else
        (
            if matchPattern n.name pattern:pat or matchPattern n.name pattern:("*" + pat + "*") do
                append found (mcpNodeInfo n)
        )
    )
    local p = #()
    mcpPair p "count" found.count
    mcpPair p "objects" found
    mcpObj p
)


fn mcpH_get_object_info params =
(
    local name = mcpStr params "name" default:""
    if name == "" do mcpFail "err.missing_param" a1:"name"
    local n = mcpResolveNode name
    if n == undefined do mcpFail "err.node_not_found" a1:name
    mcpNodeInfo n
)


fn mcpH_get_selection params =
(
    mcpSelectionInfo()
)


fn mcpH_select_objects params =
(
    local mode = mcpStr params "mode" default:"replace"
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:false silent:true
    if mode == "add" then ( try ( selectMore nodes ) catch() )
    else if mode == "subtract" then ( try ( for n in nodes do deselect n ) catch() )
    else if mode == "invert" then ( max select invert )
    else ( try ( select nodes ) catch() )
    mcpSelectionInfo()
)


fn mcpH_deselect_all params =
(
    clearSelection()
    mcpSelectionInfo()
)


fn mcpH_select_all params =
(
    select objects
    mcpSelectionInfo()
)


fn mcpH_select_by_superclass params =
(
    local sc = mcpStr params "superClass" default:""
    if sc == "" do sc = mcpStr params "type" default:""
    if sc == "" do mcpFail "err.missing_param" a1:"superClass"
    local matches = #()
    for i = 1 to objects.count do
    (
        if (mcpSuperclass objects[i]) == sc do append matches objects[i]
    )
    try ( select matches ) catch()
    mcpSelectionInfo()
)


/*------------------------------------------------------ visibility & lifecycle*/
fn mcpH_hide_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    try ( hide nodes ) catch()
    mcpRedraw()
    local split = mcpSplitByFlag nodes "isHidden" true
    local p = #()
    mcpPair p "hidden" split[1]
    mcpPair p "failures" split[2]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unhide_all params =
(
    -- Remember who was hidden before the call: "shown" has to mean "this one was
    -- hidden and is not any more", otherwise every visible object is reported as
    -- something the call did.
    local was = #()
    for i = 1 to objects.count do
    (
        local n = objects[i]
        local h = false
        try ( h = n.isHidden ) catch ( h = false )
        if h do append was n
    )
    try ( unhide objects ) catch()
    mcpRedraw()
    local split = mcpSplitByFlag was "isHidden" false
    local p = #()
    mcpPair p "shown" split[1]
    mcpPair p "failures" split[2]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unhide_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:false silent:true
    local target = nodes
    if nodes.count == 0 then
    (
        try ( unhide objects ) catch()
        target = #()
        for i = 1 to objects.count do append target objects[i]
    )
    else ( try ( unhide nodes ) catch() )
    mcpRedraw()
    local split = mcpSplitByFlag target "isHidden" false
    local p = #()
    mcpPair p "shown" split[1]
    mcpPair p "failures" split[2]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_freeze_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    try ( freeze nodes ) catch()
    mcpRedraw()
    local split = mcpSplitByFlag nodes "isFrozen" true
    local p = #()
    mcpPair p "frozen" split[1]
    mcpPair p "failures" split[2]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unfreeze_all params =
(
    local was = #()
    for i = 1 to objects.count do
    (
        local n = objects[i]
        local f = false
        try ( f = n.isFrozen ) catch ( f = false )
        if f do append was n
    )
    try ( unfreeze objects ) catch()
    mcpRedraw()
    local split = mcpSplitByFlag was "isFrozen" false
    local p = #()
    mcpPair p "thawed" split[1]
    mcpPair p "failures" split[2]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_rename_object params =
(
    local name = mcpStr params "name" default:""
    local newName = mcpStr params "newName" default:""
    if name == "" do mcpFail "err.missing_param" a1:"name"
    if newName == "" do mcpFail "err.missing_param" a1:"newName"
    local n = mcpResolveNode name
    if n == undefined do mcpFail "err.node_not_found" a1:name
    try ( n.name = newName ) catch()
    local p = #()
    mcpPair p "oldName" name
    mcpPair p "newName" n.name
    -- Max silently keeps the old name when the new one collides, so compare
    -- instead of assuming the assignment took effect.
    mcpPair p "renamed" (n.name == newName)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_delete_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local names = (for n in nodes collect n.name)
    try ( delete nodes ) catch()
    mcpRedraw()
    local p = #()
    mcpPair p "deleted" names
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_clone_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local cloneType = mcpStr params "cloneType" default:"copy"
    local count = mcpInt params "count" default:1
    if count < 1 do count = 1
    local offset = mcpPoint3From (mcpGet params "offset") default:[0,0,0]

    local created = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        for k = 1 to count do
        (
            local c = undefined
            local made = true
            try
            (
                if cloneType == "instance" then c = instance n
                else if cloneType == "reference" then c = reference n
                else ( c = copy n )
                -- The name is the evidence the copy exists: `copy` returning
                -- undefined is the only silent way this can half-succeed.
                if c == undefined or not (isValidNode c) do mcpFail "err.bad_value" a1:"copy returned no node"
                if k > 1 do ( c.position = c.position + (offset * (k - 1)) )
            )
            catch ( made = false; append failures (nm + " #" + (k as string) + ": " + (getCurrentException() as string)) )
            if made do append created c.name
        )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "count" created.count
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.created" a1:(created.count as string))
    mcpObj p
)


fn mcpH_array_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local mode = mcpStr params "mode" default:"grid"
    local c1 = mcpInt params "count1" default:3
    local c2 = mcpInt params "count2" default:1
    local c3 = mcpInt params "count3" default:1
    local s1 = mcpNum params "spacing1" default:10.0
    local s2 = mcpNum params "spacing2" default:10.0
    local s3 = mcpNum params "spacing3" default:10.0
    local center = mcpPoint3From (mcpGet params "center") default:[0,0,0]
    local axis = mcpStr params "axis" default:"z"
    local radius = mcpNum params "radius" default:50.0

    local created = #()
    local moved = #()
    local failures = #()
    local proto = nodes[1]
    if mode == "radial" then
    (
        local total = c1
        for i = 1 to total do
        (
            local ang = (i - 1) * (360.0 / (amax total 1))
            local pos = [0,0,0]
            if axis == "x" then
                pos = [center.x, center.y + radius * (cos (degToRad ang)), center.z + radius * (sin (degToRad ang))]
            else if axis == "y" then
                pos = [center.x + radius * (cos (degToRad ang)), center.y, center.z + radius * (sin (degToRad ang))]
            else
                pos = [center.x + radius * (cos (degToRad ang)), center.y + radius * (sin (degToRad ang)), center.z]
            try
            (
                local c = copy proto
                if c == undefined or not (isValidNode c) do mcpFail "err.bad_value" a1:"copy returned no node"
                c.position = pos
                try ( c.rotation = (eulerAngles 0 0 ang) as quat ) catch()
                append created c.name
            )
            catch ( append failures ("ring " + (i as string) + ": " + (getCurrentException() as string)) )
        )
    )
    else
    (
        for i = 1 to c1 do
            for j = 1 to c2 do
                for k = 1 to c3 do
                (
                    local cell = center + [(i - 1) * s1, (j - 1) * s2, (k - 1) * s3]
                    if i == 1 and j == 1 and k == 1 then
                    (
                        -- The original is repositioned, not copied.  Reporting it
                        -- under `created` made a moved object look like a new one.
                        local mo = true
                        try ( proto.position = cell )
                        catch ( mo = false; append failures (proto.name + ": " + (getCurrentException() as string)) )
                        if mo do append moved proto.name
                    )
                    else
                    (
                        try
                        (
                            local c = copy proto
                            if c == undefined or not (isValidNode c) do mcpFail "err.bad_value" a1:"copy returned no node"
                            c.position = cell
                            append created c.name
                        )
                        catch ( append failures (proto.name + " cell " + (i as string) + "," + (j as string) + "," +
                                                 (k as string) + ": " + (getCurrentException() as string)) )
                    )
                )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "moved" moved
    mcpPair p "count" created.count
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.created" a1:(created.count as string))
    mcpObj p
)


fn mcpH_attach_objects params =
(
    local targetName = mcpStr params "target" default:""
    local target = mcpResolveNode targetName
    if target == undefined do mcpFail "err.node_not_found" a1:targetName
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true

    -- Attach only exists for shapes.  Converting the target is a scene change of
    -- its own, so a failure here must be reported: the old code swallowed it and
    -- then listed every requested node as attached while nothing had happened.
    if not (isKindOf target Shape) do
    (
        local converted = true
        try ( convertToSplineShape target ) catch ( converted = false )
        if not converted do
            mcpFail "err.bad_value" a1:("target is not a shape: " + target.name)
    )

    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local ok = true
        try
        (
            local before = numSplines target
            attach target n
            -- The only evidence that attach worked is the target gaining splines.
            if (numSplines target) <= before do
                mcpFail "err.bad_value" a1:"attach added no splines"
        )
        catch ( ok = false; append failures (nm + ": " + (getCurrentException() as string)) )
        if ok then append applied nm
    )
    mcpRedraw()
    local p = #()
    mcpPair p "target" target.name
    mcpPair p "attached" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_detach_elements params =
(
    local name = mcpStr params "name" default:""
    local n = mcpResolveNode name
    if n == undefined do mcpFail "err.node_not_found" a1:name
    try ( convertToPoly n ) catch()
    if not (mcpIsPoly n) do
        mcpFail "err.poly_required" a1:(n.name + " is not an Editable Poly")

    local created = #()
    local failures = #()
    local elemCount = 0
    try ( elemCount = polyOp.getNumElements n ) catch()
    for e = 1 to elemCount do
    (
        local newName = "Det_" + n.name + "_" + (e as string)
        local before = objects.count
        try
        (
            local faces = polyOp.getElementFaces n e
            polyOp.detachFaces n faces delete:false asNode:true name:newName
            -- detachFaces does not return the node it made, so count the scene:
            -- the old code appended the requested name and called it created.
            if objects.count <= before do
                mcpFail "err.bad_value" a1:"detach created no node"
            local made = getNodeByName newName
            if made != undefined then append created made.name else append created newName
        )
        catch ( append failures ("element " + (e as string) + ": " + (getCurrentException() as string)) )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "detached" created
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_count_objects params =
(
    local sc = mcpStr params "superClass" default:""
    local total = 0
    if sc == "" then total = objects.count
    else
    (
        for i = 1 to objects.count do
            if (mcpSuperclass objects[i]) == sc do total = total + 1
    )
    local p = #()
    mcpPair p "count" total
    mcpObj p
)


/*------------------------------------------------------------------ booleans*/

<<<<<<< Updated upstream
/* Operation codes are the 0-based radio-button states of the ProBoolean UI:
   0 union, 1 intersection, 2 subtraction, 3 merge.  (The previous code mapped
   subtract/intersect to 1/2, which silently ran the wrong operation.) */
fn mcpBooleanOpCode op =
(
    local o = toLower (op as string)
    if o == "intersect" or o == "intersection" then return 1
    if o == "subtract" or o == "subtraction" or o == "difference" then return 2
    if o == "merge" then return 3
    0
)

fn mcpBooleanOpName opb =
(
    if opb == 1 do return "intersect"
    if opb == 2 do return "subtract"
    if opb == 3 do return "merge"
    "union"
)

/* Run a CSG boolean and return #(resultNode, engine, operandCount).

   ProBoolean is the primary engine.  Its MAXScript entry point is the
   PolyBoolean interface exposed on the ProBoolean class:

       ProBoolean.createBooleanObjects <operandA> #(<operandsB>) op addMethod matMethod

   with op as above, addMethod 0=reference 1=copy 2=move 3=instance and
   matMethod 0=apply operand method 1=retain original material.

   When that path is unavailable we fall back to the classic boolean2
   operation.  Both paths either produce a node or raise -- the old code
   wrapped every call in an empty catch(), so a failed boolean still reported
   "done" and the caller ended up with the untouched first object. */
fn mcpBooleanRun nodes op addMethod matMethod =
(
    local base = nodes[1]
    local operands = #()
    for i = 2 to nodes.count do append operands nodes[i]
    local opb = mcpBooleanOpCode op

    local engine = ""
    local ok = false
    local errMsg = ""

    if mcpClassExists "ProBoolean" then
    (
        try
        (
            ProBoolean.createBooleanObjects base operands opb addMethod matMethod
            engine = "proboolean"
            ok = true
        )
        catch ( errMsg = getCurrentException(); ok = false )
    )

    if not ok then
    (
        local opName = #union
        if opb == 1 do opName = #intersection
        if opb == 2 do opName = #subtraction
        local res = base
        local fallbackOk = true
        local fbErr = ""
        for o in operands do
        (
            try ( res = boolean2 res o operation:opName )
            catch ( fallbackOk = false; fbErr = getCurrentException() )
        )
        if not fallbackOk do
        (
            local why = if errMsg != "" then errMsg else fbErr
            mcpFail "err.bad_value" a1:("boolean (" + (mcpBooleanOpName opb) + "): " + why)
        )
        base = res
        engine = "boolean2"
    )

    #(base, engine, operands.count)
)

fn mcpBooleanPayload nodes op addMethod matMethod =
(
    local facesBefore = 0
    try ( facesBefore = (getPolygonCount nodes[1])[1] ) catch ( facesBefore = 0 )
    local r = mcpBooleanRun nodes op addMethod matMethod
    local result = r[1]
    local facesAfter = 0
    try ( facesAfter = (getPolygonCount result)[1] ) catch ( facesAfter = 0 )
    local p = #()
    mcpPair p "success" true
    mcpPair p "engine" r[2]
    mcpPair p "operation" (mcpBooleanOpName (mcpBooleanOpCode op))
    mcpPair p "operands" r[3]
    mcpPair p "result" (mcpNodeInfo result)
    mcpPair p "facesBefore" facesBefore
    mcpPair p "facesAfter" facesAfter
    mcpPair p "changed" (facesAfter != facesBefore)
    mcpPair p "failures" #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_boolean_operation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if nodes.count < 2 do mcpFail "err.bad_value" a1:"objects"
    local op = mcpStr params "operation" default:"union"
    local addMethod = mcpInt params "addMethod" default:2
    local matMethod = mcpInt params "materialMethod" default:0
    mcpBooleanPayload nodes op addMethod matMethod
)

fn mcpH_proboolean params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if nodes.count < 2 do mcpFail "err.bad_value" a1:"objects"
    if not (mcpClassExists "ProBoolean") do mcpFail "err.class_missing" a1:"ProBoolean"
    local op = mcpStr params "operation" default:"union"
    local addMethod = mcpInt params "addMethod" default:2
    local matMethod = mcpInt params "materialMethod" default:0
    local payload = mcpBooleanPayload nodes op addMethod matMethod
    mcpRedraw()
    payload
)


/*------------------------------------------------------------ asset placement*/
fn mcpDropNodeToSurface node surfaceNode groundZ offset alignNormal usePivot =
(
    local pos = node.position
    local hitZ = groundZ
    local hitNormal = [0, 0, 1]
    if surfaceNode != undefined then
    (
        if node == surfaceNode do mcpFail "err.bad_value" a1:"cannot place surface onto itself"
        local rayHit = undefined
        try ( rayHit = intersectRay surfaceNode (ray [pos.x, pos.y, 1.0e6] [0, 0, -1]) ) catch ( rayHit = undefined )
        if rayHit == undefined do mcpFail "err.bad_value" a1:("ray missed surface " + surfaceNode.name)
        hitZ = rayHit.pos.z
        hitNormal = rayHit.dir
    )

    if alignNormal and surfaceNode != undefined do
    (
        local zAxis = normalize hitNormal
        local upRef = if (abs zAxis.z) > 0.99 then [0, 1, 0] else [0, 0, 1]
        local xAxis = normalize (cross upRef zAxis)
        local yAxis = normalize (cross zAxis xAxis)
        local tm = matrix3 xAxis yAxis zAxis pos
        local s = node.scale
        node.transform = tm
        node.scale = s
    )

    local targetZ = hitZ + offset
    if not usePivot do
    (
        local bMin = node.min
        local pivotToBottom = node.position.z - bMin.z
        targetZ = targetZ + pivotToBottom
    )
    node.position = [pos.x, pos.y, targetZ]

    -- Read-back verification
    local actualZ = if usePivot then node.position.z else node.min.z
    local expectedZ = hitZ + offset
    if (abs (actualZ - expectedZ)) > 0.01 do
        mcpFail "err.bad_value" a1:("z read-back " + (actualZ as string) + " != " + (expectedZ as string))
    #(hitZ, actualZ)
)

fn mcpH_place_on_surface params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local surfaceName = mcpStr params "surface" default:""
    local surfaceNode = undefined
    if surfaceName != "" do
    (
        surfaceNode = mcpResolveNode surfaceName
        if surfaceNode == undefined do mcpFail "err.node_not_found" a1:surfaceName
    )
    local groundZ = mcpNum params "groundZ" default:0.0
    local offset = mcpNum params "offset" default:0.0
    local alignNormal = mcpBool params "alignNormal" default:false
    local usePivot = mcpBool params "usePivot" default:false

    local applied = #()
    local placed = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local res = undefined
        try ( res = mcpDropNodeToSurface n surfaceNode groundZ offset alignNormal usePivot )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
        if ok do
        (
            append applied n.name
            local row = #()
            mcpPair row "name" n.name
            mcpPair row "surfaceZ" res[1]
            mcpPair row "finalZ" res[2]
            mcpPair row "position" (mcpPoint3ToArr n.position)
            append placed (mcpObj row)
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0 and applied.count > 0)
    mcpPair p "applied" applied
    mcpPair p "placed" placed
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_place_relative params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local targetName = mcpReqStr params "target"
    local target = mcpResolveNode targetName
    if target == undefined do mcpFail "err.node_not_found" a1:targetName
    local side = toLower (mcpStr params "side" default:"top")
    local gap = mcpNum params "gap" default:0.0
    local alignCenter = mcpBool params "alignCenter" default:true

    local tMin = target.min
    local tMax = target.max
    local tCenter = (tMin + tMax) * 0.5

    local applied = #()
    local placed = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if n == target do mcpFail "err.bad_value" a1:"cannot place target relative to itself"
            local nMin = n.min
            local nMax = n.max
            local nCenter = (nMin + nMax) * 0.5
            local dx = if alignCenter then (tCenter.x - nCenter.x) else 0.0
            local dy = if alignCenter then (tCenter.y - nCenter.y) else 0.0
            local dz = if alignCenter then (tCenter.z - nCenter.z) else 0.0

            if side == "top" then dz = (tMax.z + gap) - nMin.z
            else if side == "bottom" then dz = (tMin.z - gap) - nMax.z
            else if side == "right" then dx = (tMax.x + gap) - nMin.x
            else if side == "left" then dx = (tMin.x - gap) - nMax.x
            else if side == "back" then dy = (tMax.y + gap) - nMin.y
            else if side == "front" then dy = (tMin.y - gap) - nMax.y
            else if side == "center" then ( dx = tCenter.x - nCenter.x; dy = tCenter.y - nCenter.y; dz = tCenter.z - nCenter.z )
            else mcpFail "err.invalid_argument" a1:side a2:"unknown side"

            local expectedPos = n.position + [dx, dy, dz]
            n.position = expectedPos
            if (distance n.position expectedPos) > 0.01 do
                mcpFail "err.bad_value" a1:"position read-back mismatch"

            append applied n.name
            local row = #()
            mcpPair row "name" n.name
            mcpPair row "position" (mcpPoint3ToArr n.position)
            mcpPair row "min" (mcpPoint3ToArr n.min)
            mcpPair row "max" (mcpPoint3ToArr n.max)
            append placed (mcpObj row)
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0 and applied.count > 0)
    mcpPair p "target" target.name
    mcpPair p "side" side
    mcpPair p "applied" applied
    mcpPair p "placed" placed
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_distribute_along_spline params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local splineName = mcpReqStr params "spline"
    local sp = mcpResolveNode splineName
    if sp == undefined do mcpFail "err.node_not_found" a1:splineName
    if (superclassof sp) != shape do mcpFail "err.invalid_argument" a1:splineName a2:"target is not a spline shape"

    local count = mcpInt params "count" default:0
    local spacing = mcpNum params "spacing" default:0.0
    if count <= 0 then
    (
        if spacing > 0.0 then
        (
            local len = 0.0
            try ( len = curveLength sp 1 ) catch ( len = 0.0 )
            count = if len > 0.0 then ((floor (len / spacing)) as integer + 1) else 10
        )
        else count = 10
    )
    if count < 1 do count = 1
    if count > 500 do count = 500

    local followTangent = mcpBool params "followTangent" default:true
    local yawOffset = mcpNum params "yawOffset" default:0.0
    local randomYaw = mcpNum params "randomYaw" default:0.0
    local doScale = mcpBool params "randomScale" default:false
    local sMin = mcpNum params "scaleMin" default:0.85
    local sMax = mcpNum params "scaleMax" default:1.15
    local surfaceName = mcpStr params "surface" default:""
    local surfaceNode = undefined
    if surfaceName != "" do
    (
        surfaceNode = mcpResolveNode surfaceName
        if surfaceNode == undefined do mcpFail "err.node_not_found" a1:surfaceName
    )
    local offset = mcpNum params "offset" default:0.0
    local seedVal = mcpInt params "seed" default:12345

    local isClosedCurve = false
    try ( isClosedCurve = isClosed sp 1 ) catch ( isClosedCurve = false )

    seed seedVal
    local created = #()
    local failures = #()
    for i = 1 to count do
    (
        local proto = nodes[((i - 1) mod nodes.count) + 1]
        local t = 0.0
        if count > 1 do
        (
            t = if isClosedCurve then ((i - 1) as float) / (count as float) else ((i - 1) as float) / ((count - 1) as float)
        )
        try
        (
            local pt = interpCurve3D sp 1 t pathParam:true
            local obj = copy proto
            if obj == undefined or not (isValidNode obj) do mcpFail "err.bad_value" a1:"copy returned no node"

            local yaw = yawOffset
            if followTangent do
            (
                local tang = tangentCurve3D sp 1 t pathParam:true
                yaw = (atan2 tang.y tang.x) + yawOffset
            )
            if randomYaw > 0.0 do yaw = yaw + (random (-randomYaw) randomYaw)
            obj.rotation = (eulerAngles 0 0 yaw) as quat
            if doScale do
            (
                local sc = random sMin sMax
                obj.scale = [sc, sc, sc]
            )
            obj.position = pt
            if surfaceNode != undefined do
                mcpDropNodeToSurface obj surfaceNode 0.0 offset false false
            else if offset != 0.0 do
                obj.position = [pt.x, pt.y, pt.z + offset]

            if not (isValidNode obj) do mcpFail "err.bad_value" a1:"instance invalid after placement"
            append created obj.name
        )
        catch ( append failures ("instance " + (i as string) + ": " + (getCurrentException() as string)) )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "success" (failures.count == 0 and created.count > 0)
    mcpPair p "spline" sp.name
    mcpPair p "created" created
    mcpPair p "count" created.count
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.created" a1:(created.count as string))
    mcpObj p
)

fn mcpH_check_overlaps params =
(
    local reqNames = mcpArr params "objects"
    local againstNames = mcpArr params "against"
    local ignoreNames = mcpArr params "ignore"
    local tol = mcpNum params "tolerance" default:0.01
    local includeHidden = mcpBool params "includeHidden" default:false

    local ignoreSet = #()
    for nm in ignoreNames do append ignoreSet (toLower (nm as string))

    local targets = #()
    if reqNames.count > 0 then
        targets = mcpResolveNodes reqNames fallbackToSelection:false
    else if selection.count > 0 then
        targets = for n in selection collect n
    else
        targets = for n in geometry where (includeHidden or not n.isHiddenInVpt) collect n

    local pool = #()
    if againstNames.count > 0 then
        pool = mcpResolveNodes againstNames fallbackToSelection:false
    else
        pool = for n in geometry where (includeHidden or not n.isHiddenInVpt) collect n

    local filteredTargets = #()
    for t in targets do
    (
        if (findItem ignoreSet (toLower t.name)) == 0 do append filteredTargets t
    )
    local filteredPool = #()
    for q in pool do
    (
        if (findItem ignoreSet (toLower q.name)) == 0 do append filteredPool q
    )

    local overlaps = #()
    local seenPairs = #()
    local cap = 100
    for a in filteredTargets do
    (
        local aMin = a.min
        local aMax = a.max
        for b in filteredPool do
        (
            if a != b and overlaps.count < cap do
            (
                local pairKey = if a.handle < b.handle then ((a.handle as string) + ":" + (b.handle as string)) else ((b.handle as string) + ":" + (a.handle as string))
                if (findItem seenPairs pairKey) == 0 do
                (
                    local bMin = b.min
                    local bMax = b.max
                    local ox = (amin aMax.x bMax.x) - (amax aMin.x bMin.x)
                    local oy = (amin aMax.y bMax.y) - (amax aMin.y bMin.y)
                    local oz = (amin aMax.z bMax.z) - (amax aMin.z bMin.z)
                    if ox > tol and oy > tol and oz > tol do
                    (
                        append seenPairs pairKey
                        local row = #()
                        mcpPair row "a" a.name
                        mcpPair row "b" b.name
                        mcpPair row "penetration" #(ox, oy, oz)
                        append overlaps (mcpObj row)
                    )
                )
            )
        )
    )

    local p = #()
    mcpPair p "checkedObjects" filteredTargets.count
    mcpPair p "overlapCount" overlaps.count
    mcpPair p "overlaps" overlaps
    mcpPair p "tolerance" tol
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------------ registry*/
fn mcpRegisterObjects =
(
    -- primitives (generic handler, one per class)
    mcpRegister "create_primitive" mcpH_create_primitive label:"Create Primitive"
    mcpRegister "create_box" mcpH_create_primitive label:"Create Box"
    mcpRegister "create_sphere" mcpH_create_primitive label:"Create Sphere"
    mcpRegister "create_cylinder" mcpH_create_primitive label:"Create Cylinder"
    mcpRegister "create_cone" mcpH_create_primitive label:"Create Cone"
    mcpRegister "create_torus" mcpH_create_primitive label:"Create Torus"
    mcpRegister "create_teapot" mcpH_create_primitive label:"Create Teapot"
    mcpRegister "create_plane" mcpH_create_primitive label:"Create Plane"
    mcpRegister "create_tube" mcpH_create_primitive label:"Create Tube"
    mcpRegister "create_pyramid" mcpH_create_primitive label:"Create Pyramid"
    mcpRegister "create_hedra" mcpH_create_primitive label:"Create Hedra"
    mcpRegister "create_geosphere" mcpH_create_primitive label:"Create GeoSphere"
    mcpRegister "create_chamferbox" mcpH_create_primitive label:"Create ChamferBox"
    mcpRegister "create_capsule" mcpH_create_primitive label:"Create Capsule"

    -- splines
    mcpRegister "create_line" mcpH_create_line label:"Create Line"
    mcpRegister "create_rectangle" mcpH_create_spline label:"Create Rectangle"
    mcpRegister "create_circle" mcpH_create_spline label:"Create Circle"
    mcpRegister "create_ellipse" mcpH_create_spline label:"Create Ellipse"
    mcpRegister "create_ngon" mcpH_create_spline label:"Create NGon"
    mcpRegister "create_donut" mcpH_create_spline label:"Create Donut"
    mcpRegister "create_arc" mcpH_create_spline label:"Create Arc"
    mcpRegister "create_helix" mcpH_create_spline label:"Create Helix"
    mcpRegister "create_text" mcpH_create_spline label:"Create Text"
    mcpRegister "spline_get_points" mcpH_spline_get_points undoable:false label:"Spline Get Points"
    mcpRegister "spline_set_points" mcpH_spline_set_points label:"Spline Set Points"

    -- transforms
    mcpRegister "transform_object" mcpH_transform_object label:"Transform Object"
    mcpRegister "align_objects" mcpH_align_objects label:"Align Objects"
    mcpRegister "mirror_object" mcpH_mirror_object label:"Mirror Object"
    mcpRegister "set_pivot" mcpH_set_pivot label:"Set Pivot"
    mcpRegister "reset_transform" mcpH_reset_transform label:"Reset Transform"
    mcpRegister "snap_objects_to_grid" mcpH_snap_objects_to_grid label:"Snap To Grid"
    mcpRegister "scatter_objects" mcpH_scatter_objects label:"Scatter Objects"

    -- hierarchy
    mcpRegister "parent_objects" mcpH_parent_objects label:"Parent Objects"
    mcpRegister "unparent_objects" mcpH_unparent_objects label:"Unparent Objects"
    mcpRegister "get_hierarchy" mcpH_get_hierarchy undoable:false label:"Get Hierarchy"
    mcpRegister "group_objects" mcpH_group_objects label:"Group Objects"
    mcpRegister "ungroup_objects" mcpH_ungroup_objects label:"Ungroup Objects"
    mcpRegister "open_group" mcpH_open_group label:"Open Group"
    mcpRegister "close_group" mcpH_close_group label:"Close Group"

    -- selection & query
    mcpRegister "list_objects" mcpH_list_objects undoable:false label:"List Objects"
    mcpRegister "find_objects" mcpH_find_objects undoable:false label:"Find Objects"
    mcpRegister "get_object_info" mcpH_get_object_info undoable:false label:"Get Object Info"
    mcpRegister "get_selection" mcpH_get_selection undoable:false label:"Get Selection"
    mcpRegister "select_objects" mcpH_select_objects label:"Select Objects"
    mcpRegister "deselect_all" mcpH_deselect_all label:"Deselect All"
    mcpRegister "select_all" mcpH_select_all label:"Select All"
    mcpRegister "select_by_superclass" mcpH_select_by_superclass label:"Select By Superclass"

    -- visibility & lifecycle
    mcpRegister "hide_objects" mcpH_hide_objects label:"Hide Objects"
    mcpRegister "unhide_all" mcpH_unhide_all label:"Unhide All"
    mcpRegister "unhide_objects" mcpH_unhide_objects label:"Unhide Objects"
    mcpRegister "freeze_objects" mcpH_freeze_objects label:"Freeze Objects"
    mcpRegister "unfreeze_all" mcpH_unfreeze_all label:"Unfreeze All"
    mcpRegister "rename_object" mcpH_rename_object label:"Rename Object"
    mcpRegister "delete_objects" mcpH_delete_objects label:"Delete Objects"
    mcpRegister "clone_objects" mcpH_clone_objects label:"Clone Objects"
    mcpRegister "array_objects" mcpH_array_objects label:"Array Objects"
    mcpRegister "attach_objects" mcpH_attach_objects label:"Attach Objects"
    mcpRegister "detach_elements" mcpH_detach_elements label:"Detach Elements"
    mcpRegister "count_objects" mcpH_count_objects undoable:false label:"Count Objects"

    -- booleans
    mcpRegister "boolean_operation" mcpH_boolean_operation label:"Boolean Operation"
    mcpRegister "proboolean" mcpH_proboolean label:"ProBoolean"

    -- asset placement & spatial check
    mcpRegister "place_on_surface" mcpH_place_on_surface label:"Place On Surface"
    mcpRegister "place_relative" mcpH_place_relative label:"Place Relative"
    mcpRegister "distribute_along_spline" mcpH_distribute_along_spline label:"Distribute Along Spline"
    mcpRegister "check_overlaps" mcpH_check_overlaps undoable:false label:"Check Overlaps"
    ok
)

mcpRegisterObjects()
