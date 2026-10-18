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
global mcpObjL


/*---------------------------------------------- local locale helper (no mcp_core edits)
   For strings that have no existing mcpMessages key, return zh or en based on
   mcpLang.  Kept tiny and dependency free. */
fn mcpObjL zh en =
(
    if mcpLang == "en" then en else zh
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

    local nm = mcpStr params "name" default:""
    if nm == "" do nm = mcpStr params "setName" default:""
    if nm != "" do ( try ( obj.name = nm ) catch() )

    local pos = mcpGet params "position"
    if pos != undefined do ( try ( obj.position = (mcpPoint3From pos) ) catch() )

    local dimProps = #("length","width","height","depth","radius","radius1","radius2","segments",
                       "sides","chamfer","fillet","turns","heightSegs","widthSegs","lengthSegs",
                       "capSegs","cornerRadius","from","to","genSmooth","axis")
    for pn in dimProps do
    (
        if (mcpGet params pn) != undefined do
        (
            try ( setProperty obj pn (mcpNum params pn) ) catch()
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
            try ( setProperty obj pn (mcpBool params pn) ) catch()
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "object" (mcpNodeInfo obj)
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

    local nm = mcpStr params "name" default:""
    if nm != "" do ( try ( obj.name = nm ) catch() )

    local pos = mcpGet params "position"
    if pos != undefined do ( try ( obj.position = (mcpPoint3From pos) ) catch() )

    local txt = mcpStr params "text" default:""
    if txt != "" do ( try ( obj.text = txt ) catch() )

    local dimProps = #("length","width","radius","radius1","radius2","sides","segments",
                       "height","turns","from","to","cornerRadius","size","thickness","angle","genSmooth")
    for pn in dimProps do
    (
        if (mcpGet params pn) != undefined do
        (
            try ( setProperty obj pn (mcpNum params pn) ) catch()
        )
    )

    mcpRedraw()
    local p = #()
    mcpPair p "object" (mcpNodeInfo obj)
    mcpPair p "message" (mcpMsg "msg.created" a1:obj.name)
    mcpObj p
)


fn mcpH_create_line params =
(
    local pts = mcpArr params "points"
    if pts.count == 0 do mcpFail "err.missing_param" a1:"points"
    local closed = mcpBool params "closed" default:false

    local obj = line()
    setNumSplines obj 1
    for i = 1 to pts.count do
    (
        try ( addPoint obj (mcpPoint3From pts[i]) ) catch()
    )
    if closed do ( try ( close obj 1 ) catch() )

    local nm = mcpStr params "name" default:""
    if nm != "" do ( try ( obj.name = nm ) catch() )

    local pos = mcpGet params "position"
    if pos != undefined do ( try ( obj.position = obj.position + (mcpPoint3From pos) ) catch() )

    updateShape obj
    mcpRedraw()
    local p = #()
    mcpPair p "object" (mcpNodeInfo obj)
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
    for n in nodes do
    (
        try
        (
            if (numSplines n) == 0 do setNumSplines n 1
            local count = numKnots n 1
            local take = min count (pts.count)
            for k = 1 to take do
            (
                try ( setKnotPoint n 1 k (mcpPoint3From pts[k]) ) catch()
            )
            for k = (take + 1) to (pts.count) do
            (
                try ( addPoint n (mcpPoint3From pts[k]) ) catch()
            )
            updateShape n
        )
        catch()
    )
    mcpRedraw()
    local p = #()
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
    for n in nodes do
    (
        if doPos do ( try ( n.position = target.position ) catch() )
        if doRot do ( try ( n.rotation = target.rotation ) catch() )
        if doScale do ( try ( n.scale = target.scale ) catch() )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "target" target.name
    mcpPair p "aligned" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_mirror_object params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local axis = mcpStr params "axis" default:"x"
    local offset = mcpNum params "offset" default:0.0
    local cloneType = mcpStr params "cloneType" default:"none"

    for n in nodes do
    (
        local mirrored = n
        if cloneType == "copy" then mirrored = copy n
        else if cloneType == "instance" then mirrored = instance n

        local p = mirrored.position
        if axis == "x" then
        (
            p.x = (2.0 * offset) - p.x
            try ( mirrored.scale = [-mirrored.scale.x, mirrored.scale.y, mirrored.scale.z] ) catch()
        )
        else if axis == "y" then
        (
            p.y = (2.0 * offset) - p.y
            try ( mirrored.scale = [mirrored.scale.x, -mirrored.scale.y, mirrored.scale.z] ) catch()
        )
        else
        (
            p.z = (2.0 * offset) - p.z
            try ( mirrored.scale = [mirrored.scale.x, mirrored.scale.y, -mirrored.scale.z] ) catch()
        )
        mirrored.position = p
    )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_set_pivot params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local mode = mcpStr params "mode" default:"place"
    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    for n in nodes do
    (
        if mode == "center" then ( try ( centerPivot n ) catch() )
        else if mode == "origin" then ( try ( n.pivot = [0,0,0] ) catch() )
        else ( try ( n.pivot = pos ) catch() )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_reset_transform params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local rot = mcpBool params "rotation" default:true
    local scl = mcpBool params "scale" default:true
    local pos = mcpBool params "position" default:false
    for n in nodes do
    (
        if rot do ( try ( n.rotation = (eulerAngles 0 0 0) ) catch() )
        if scl do ( try ( n.scale = [1,1,1] ) catch() )
        if pos do ( try ( n.position = [0,0,0] ) catch() )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_snap_objects_to_grid params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spacing = mcpNum params "spacing" default:10.0
    if spacing <= 0 do spacing = 10.0
    for n in nodes do
    (
        try
        (
            n.position = [ (floor (n.position.x / spacing + 0.5)) * spacing,
                           (floor (n.position.y / spacing + 0.5)) * spacing,
                           (floor (n.position.z / spacing + 0.5)) * spacing ]
        )
        catch()
    )
    mcpRedraw()
    local p = #()
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
    for i = 1 to count do
    (
        local proto = nodes[((i - 1) mod nodes.count) + 1]
        local obj = copy proto
        local px = center.x + (random (-0.5 * size.x) (0.5 * size.x))
        local py = center.y + (random (-0.5 * size.y) (0.5 * size.y))
        local pz = center.z + (random (-0.5 * size.z) (0.5 * size.z))

        if region == "surface" and surfaceNode != undefined do
        (
            try
            (
                local rayHit = intersectRay surfaceNode (ray [px, py, 1e6] [0,0,-1])
                if rayHit != undefined do
                (
                    px = rayHit.pos.x
                    py = rayHit.pos.y
                    pz = rayHit.pos.z
                )
            )
            catch()
        )

        obj.position = [px, py, pz]
        if doRot do ( try ( obj.rotation = (eulerAngles (random -180.0 180.0) (random -180.0 180.0) (random -180.0 180.0)) as quat ) catch() )
        if doScale do
        (
            try
            (
                local sc = random sMin sMax
                obj.scale = [sc, sc, sc]
            )
            catch()
        )
        append created obj.name
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "count" created.count
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
    for n in nodes do
    (
        if keep then
        (
            local w = n.transform
            n.parent = parent
            n.transform = w
        )
        else n.parent = parent
    )
    mcpRedraw()
    local p = #()
    mcpPair p "parent" parent.name
    mcpPair p "children" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.hierarchy" a1:parent.name)
    mcpObj p
)


fn mcpH_unparent_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local keep = mcpBool params "keepTransform" default:true
    for n in nodes do
    (
        if keep then
        (
            local w = n.transform
            n.parent = undefined
            n.transform = w
        )
        else n.parent = undefined
    )
    mcpRedraw()
    local p = #()
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
    for n in nodes do ( try ( ungroup n ) catch() )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_open_group params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    for n in nodes do ( try ( setGroupOpen n true ) catch() )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_close_group params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    for n in nodes do ( try ( setGroupOpen n false ) catch() )
    mcpRedraw()
    local p = #()
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
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unhide_all params =
(
    try ( unhide objects ) catch()
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unhide_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:false silent:true
    if nodes.count == 0 then ( try ( unhide objects ) catch() )
    else ( try ( unhide nodes ) catch() )
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_freeze_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    try ( freeze nodes ) catch()
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_unfreeze_all params =
(
    try ( unfreeze objects ) catch()
    mcpRedraw()
    local p = #()
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
    for n in nodes do
    (
        for k = 1 to count do
        (
            local c = undefined
            if cloneType == "instance" then c = instance n
            else if cloneType == "reference" then c = reference n
            else ( c = copy n )
            if k > 1 do ( try ( c.position = c.position + (offset * (k - 1)) ) catch() )
            append created c.name
        )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "count" created.count
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
    local proto = nodes[1]
    if mode == "radial" then
    (
        local total = c1
        for i = 1 to total do
        (
            local ang = (i - 1) * (360.0 / (amax total 1))
            local c = copy proto
            local pos = [0,0,0]
            if axis == "x" then
                pos = [center.x, center.y + radius * (cos (degToRad ang)), center.z + radius * (sin (degToRad ang))]
            else if axis == "y" then
                pos = [center.x + radius * (cos (degToRad ang)), center.y, center.z + radius * (sin (degToRad ang))]
            else
                pos = [center.x + radius * (cos (degToRad ang)), center.y + radius * (sin (degToRad ang)), center.z]
            c.position = pos
            try ( c.rotation = (eulerAngles 0 0 ang) as quat ) catch()
            append created c.name
        )
    )
    else
    (
        for i = 1 to c1 do
            for j = 1 to c2 do
                for k = 1 to c3 do
                (
                    if i == 1 and j == 1 and k == 1 then
                    (
                        proto.position = center + [(i - 1) * s1, (j - 1) * s2, (k - 1) * s3]
                        append created proto.name
                    )
                    else
                    (
                        local c = copy proto
                        c.position = center + [(i - 1) * s1, (j - 1) * s2, (k - 1) * s3]
                        append created c.name
                    )
                )
    )
    mcpRedraw()
    local p = #()
    mcpPair p "created" created
    mcpPair p "count" created.count
    mcpPair p "message" (mcpMsg "msg.created" a1:(created.count as string))
    mcpObj p
)


fn mcpH_attach_objects params =
(
    local targetName = mcpStr params "target" default:""
    local target = mcpResolveNode targetName
    if target == undefined do mcpFail "err.node_not_found" a1:targetName
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true

    try ( convertToSplineShape target ) catch()
    for n in nodes do ( try ( attach target n ) catch() )
    mcpRedraw()
    local p = #()
    mcpPair p "target" target.name
    mcpPair p "attached" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_detach_elements params =
(
    local name = mcpStr params "name" default:""
    local n = mcpResolveNode name
    if n == undefined do mcpFail "err.node_not_found" a1:name
    try ( convertToPoly n ) catch()

    local created = #()
    local elemCount = 0
    try ( elemCount = polyOp.getNumElements n ) catch()
    for e = 1 to elemCount do
    (
        try
        (
            local faces = polyOp.getElementFaces n e
            local newName = "Det_" + n.name + "_" + (e as string)
            polyOp.detachFaces n faces delete:false asNode:true name:newName
            append created newName
        )
        catch()
    )
    mcpRedraw()
    local p = #()
    mcpPair p "detached" created
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
fn mcpH_boolean_operation params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if nodes.count < 2 do mcpFail "err.bad_value" a1:"objects"
    local op = mcpStr params "operation" default:"union"
    local opName = #union
    if op == "subtract" then opName = #subtraction
    else if op == "intersect" then opName = #intersection
    else if op == "merge" then opName = #union
    else ( opName = #union )

    local result = nodes[1]
    for i = 2 to nodes.count do
    (
        try ( result = boolean2 result nodes[i] operation:opName ) catch()
    )
    local p = #()
    mcpPair p "result" (mcpNodeInfo result)
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


fn mcpH_proboolean params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    if nodes.count < 2 do mcpFail "err.bad_value" a1:"objects"
    if not (mcpClassExists "ProBoolean") do mcpFail "err.class_missing" a1:"ProBoolean"

    local op = mcpStr params "operation" default:"union"
    local opb = 0
    if op == "subtract" then opb = 1
    else if op == "intersect" then opb = 2
    else if op == "merge" then opb = 3
    else ( opb = 0 )

    try
    (
        proBoolean.SetOperation opb
        proBoolean.SetShowNewObjectsOnly false
        proBoolean.InitialObject nodes[1] false
        for i = 2 to nodes.count do proBoolean.AddObjectToFirst nodes[1] nodes[i] false
        proBoolean.MakeSelection 4
        proBoolean.Commit()
        proBoolean.Close()
        proBoolean.Update()
    )
    catch ( mcpFail "err.bad_value" a1:(getCurrentException()) )

    mcpRedraw()
    local p = #()
    mcpPair p "result" (mcpNodeInfo nodes[1])
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
    ok
)

mcpRegisterObjects()
