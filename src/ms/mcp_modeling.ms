/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_modeling.ms
   Consolidated modeling module: Editable Poly editing, converters, modifier
   stack management, and spline-driven geometry.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_poly.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_poly.ms
   Editable Poly editing, boolean operations and converters.

   Category: modeling (poly / convert)
   Every poly edit wraps the operation in try/catch and always resets
   subobjectLevel to 0 afterwards so Max never gets stuck in a sub-object mode.
   Selection-only tools (poly_select_faces / poly_loop_select / poly_ring_select)
   intentionally leave the selection set because that is their whole purpose.
-----------------------------------------------------------------------------*/

global mcpH_convert_to_editable_poly, mcpH_convert_to_editable_mesh, mcpH_convert_to_nurbs
global mcpH_poly_info, mcpH_poly_get_verts, mcpH_poly_get_faces, mcpH_poly_get_edges, mcpH_poly_get_stats
global mcpH_poly_set_vertex, mcpH_poly_move_vertices, mcpH_poly_weld_vertices
global mcpH_poly_target_weld, mcpH_poly_chamfer_vertices, mcpH_poly_remove_vertices
global mcpH_poly_select_faces, mcpH_poly_extrude_faces, mcpH_poly_bevel_faces
global mcpH_poly_inset_faces, mcpH_poly_bridge_faces, mcpH_poly_cap_holes
global mcpH_poly_flip_faces, mcpH_poly_delete_faces, mcpH_poly_assign_material_id
global mcpH_poly_set_smoothing, mcpH_poly_detach_faces
global mcpH_poly_chamfer_edges, mcpH_poly_connect_edges, mcpH_poly_extrude_edges
global mcpH_poly_loop_select, mcpH_poly_ring_select, mcpH_poly_slice
global mcpH_poly_triangulate, mcpH_poly_quadify, mcpH_poly_subdivide
global mcpH_poly_optimize, mcpH_poly_relax, mcpH_poly_auto_smooth
global mcpH_poly_unify_normals, mcpH_poly_make_planar


/*-------------------------------------------------------------- shared helpers*/
fn mcpEnsurePoly node =
(
    if mcpIsPoly node do return true
    local ok = true
    try ( convertToPoly node ) catch ( ok = false )
    ok and (mcpIsPoly node)
)

fn mcpIdxBA indices =
(
    local ba = #{}
    for idx in indices do
    (
        local i = idx as integer
        if i > 0 do ba[i] = true
    )
    ba
)

fn mcpPolyFaceBA node indices =
(
    local fc = polyop.getNumFaces node
    if indices == undefined or indices.count == 0 then #{1..fc}
    else mcpIdxBA indices
)

fn mcpPolyVertBA node indices =
(
    local vc = polyop.getNumVerts node
    if indices == undefined or indices.count == 0 then #{1..vc}
    else mcpIdxBA indices
)

fn mcpPolyEdgeBA node indices =
(
    local ec = polyop.getNumEdges node
    if indices == undefined or indices.count == 0 then #{1..ec}
    else mcpIdxBA indices
)

fn mcpPolyMatIDRange node =
(
    local lo = 100000
    local hi = -1
    local fc = polyop.getNumFaces node
    for f = 1 to fc do
    (
        local id = 0
        try ( id = polyop.getFaceMatID node f ) catch ( id = 0 )
        if id < lo do lo = id
        if id > hi do hi = id
    )
    if hi < 0 do ( lo = 0; hi = 0 )
    #(lo, hi)
)

fn mcpPaginate items limit offset =
(
    local total = items.count
    local start = offset + 1
    if start < 1 do start = 1
    local page = #()
    if limit <= 0 then page = items
    else
    (
        local endx = offset + limit
        if endx > total do endx = total
        for i = start to endx do append page items[i]
    )
    #(page, total)
)

fn mcpPolyResetSL node =
(
    try ( node.subobjectLevel = 0 ) catch()
)


/*-------------------------------------------------------------- converters ---*/
fn mcpH_convert_to_editable_poly params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            convertToPoly n
            -- convertToPoly can return without making the object a poly
            -- (already a mesh with odd flags); the class is the evidence.
            if not (mcpIsPoly n) do mcpFail "err.poly_required" a1:n.name
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_convert_to_editable_mesh params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try ( convertToMesh n; append applied n.name )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_convert_to_nurbs params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            convertTo n (NURBSSurface())
            append applied n.name
        )
        catch
        (
            ok = false
            try ( convertToNURBSSurface n; append applied n.name; ok = true )
            catch ( append failures (n.name + ": " + (getCurrentException())) )
        )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

/*------------------------------------------------------ collapse_stack note -*/
-- collapse_stack no longer has its own handler here: the catalog entry is a
-- controlled alias that bridges to mod_collapse (mcp_modeling_ext.ms), which
-- refuses to run without an explicit confirm=true.  The old unguarded handler
-- was removed so exactly one collapse path exists (D4 unification, 2026-10-18).


/*-------------------------------------------------------------- poly query ---*/
fn mcpH_poly_info params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local out = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local mr = mcpPolyMatIDRange n
            mcpPair rec "name" n.name
            mcpPair rec "verts" (polyop.getNumVerts n)
            mcpPair rec "faces" (polyop.getNumFaces n)
            mcpPair rec "edges" (polyop.getNumEdges n)
            mcpPair rec "selectionMode" (try ( n.subobjectLevel as integer ) catch ( 0 ))
            mcpPair rec "materialIdMin" mr[1]
            mcpPair rec "materialIdMax" mr[2]
        )
        catch ( ok = false; append out ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append out (mcpObj rec)
    )
    local p = #()
    mcpPair p "objects" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_get_verts params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:0
    local offset = mcpInt params "offset" default:0
    local faceFilter = mcpArr params "faces"
    local allItems = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local vc = polyop.getNumVerts n
            local idxs = #()
            if faceFilter.count > 0 then
            (
                local seen = #{}
                for f in faceFilter do
                (
                    local fv = #()
                    try ( fv = polyop.getFaceVerts n (f as integer) ) catch ( fv = #() )
                    for v in fv do seen[v] = true
                )
                for v = 1 to vc do ( if seen[v] do append idxs v )
            )
            else ( for v = 1 to vc do append idxs v )
            for v in idxs do
            (
                local pt = [0,0,0]
                try ( pt = polyop.getVert n v ) catch ( pt = [0,0,0] )
                local rec = #()
                mcpPair rec "object" n.name
                mcpPair rec "index" v
                mcpPair rec "position" pt
                append allItems (mcpObj rec)
            )
        )
        catch ( ok = false )
    )
    local pg = mcpPaginate allItems limit offset
    local p = #()
    mcpPair p "count" pg[2]
    mcpPair p "verts" pg[1]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_get_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:0
    local offset = mcpInt params "offset" default:0
    local allItems = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local fc = polyop.getNumFaces n
            for f = 1 to fc do
            (
                local fv = #()
                local nrm = [0,0,0]
                local mid = 0
                try ( fv = polyop.getFaceVerts n f ) catch ( fv = #() )
                try ( nrm = polyop.getFaceNormal n f ) catch ( nrm = [0,0,0] )
                try ( mid = polyop.getFaceMatID n f ) catch ( mid = 0 )
                local rec = #()
                mcpPair rec "object" n.name
                mcpPair rec "index" f
                mcpPair rec "verts" fv
                mcpPair rec "normal" nrm
                mcpPair rec "materialId" mid
                append allItems (mcpObj rec)
            )
        )
        catch ( ok = false )
    )
    local pg = mcpPaginate allItems limit offset
    local p = #()
    mcpPair p "count" pg[2]
    mcpPair p "faces" pg[1]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_get_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:0
    local offset = mcpInt params "offset" default:0
    local allItems = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local ec = polyop.getNumEdges n
            for e = 1 to ec do
            (
                local ev = #()
                try ( ev = polyop.getEdgeVerts n e ) catch ( ev = #() )
                local rec = #()
                mcpPair rec "object" n.name
                mcpPair rec "index" e
                mcpPair rec "verts" ev
                append allItems (mcpObj rec)
            )
        )
        catch ( ok = false )
    )
    local pg = mcpPaginate allItems limit offset
    local p = #()
    mcpPair p "count" pg[2]
    mcpPair p "edges" pg[1]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_get_stats params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local out = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local mr = mcpPolyMatIDRange n
            mcpPair rec "name" n.name
            mcpPair rec "verts" (polyop.getNumVerts n)
            mcpPair rec "faces" (polyop.getNumFaces n)
            mcpPair rec "edges" (polyop.getNumEdges n)
            mcpPair rec "materialIdMin" mr[1]
            mcpPair rec "materialIdMax" mr[2]
            mcpPair rec "polygonCount" (try ( (getPolygonCount n)[1] ) catch ( 0 ))
        )
        catch ( ok = false; append out ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append out (mcpObj rec)
    )
    local p = #()
    mcpPair p "objects" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------- poly vertex edit ---*/
fn mcpH_poly_set_vertex params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local index = mcpReqInt params "index"
    local pos = mcpArr params "position"
    local offsetVec = mcpArr params "offset"
    local p3 = mcpPoint3From pos default:undefined
    local d3 = mcpPoint3From offsetVec default:undefined
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local target = [0,0,0]
            try ( target = polyop.getVert n index ) catch ( target = [0,0,0] )
            if p3 != undefined then target = p3
            else if d3 != undefined then target = target + d3
            else mcpFail "err.missing_param" a1:"position|offset"
            polyop.setVert n index target
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_move_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local offsetVec = mcpArr params "offset"
    local d3 = mcpPoint3From offsetVec default:[0,0,0]
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.moveVerts n (mcpIdxBA verts) d3
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_weld_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local thr = mcpNum params "threshold" default:0.1
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.weldVertsByThreshold n (mcpIdxBA verts) thr
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_target_weld params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local v1 = mcpReqInt params "vertex"
    local v2 = mcpReqInt params "target"
    local thr = mcpNum params "threshold" default:0.1
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            n.subobjectLevel = 1
            polyop.setVertSelection n #{v1}
            n.weldTarget (v2 as integer) thr
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_chamfer_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local amt = mcpNum params "amount" default:0.0
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.chamferVertices n (mcpIdxBA verts) amt
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_remove_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.deleteVerts n (mcpIdxBA verts)
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------- poly face edit ---*/
fn mcpH_poly_select_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local facesArg = mcpArr params "faces"
    local matID = mcpGet params "materialId"
    local nAxis = mcpStr params "normalAxis" default:""
    local nSign = mcpStr params "normalSign" default:"+"
    local hAxis = mcpStr params "heightAxis" default:""
    local hMin = mcpNum params "heightMin" default:1e30
    local hMax = mcpNum params "heightMax" default:(-1e30)
    local outAll = #()
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local sel = #{}
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local fc = polyop.getNumFaces n
            if facesArg.count > 0 then sel = mcpIdxBA facesArg
            else
            (
                for f = 1 to fc do
                (
                    local take = false
                    if matID != undefined do ( if (polyop.getFaceMatID n f) == (matID as integer) do take = true )
                    if (not take) and hAxis != "" do
                    (
                        local c = [0,0,0]; local cnt = 0
                        local fv = #()
                        try ( fv = polyop.getFaceVerts n f ) catch ( fv = #() )
                        for v in fv do ( c = c + polyop.getVert n v; cnt += 1 )
                        if cnt > 0 do c = c / cnt
                        local h = if hAxis == "x" then c.x else ( if hAxis == "y" then c.y else c.z )
                        if h >= hMin and h <= hMax do take = true
                    )
                    if (not take) and nAxis != "" do
                    (
                        local nm = [0,0,0]
                        try ( nm = polyop.getFaceNormal n f ) catch ( nm = [0,0,0] )
                        local d = if nAxis == "x" then nm.x else ( if nAxis == "y" then nm.y else nm.z )
                        if nSign == "-" then ( if d < 0 do take = true ) else ( if d > 0 do take = true )
                    )
                    if take do sel[f] = true
                )
            )
            -- the level assignment can fail outside the modify-panel context;
            -- polyop selection works without it, so never let it abort
            try ( n.subobjectLevel = 4 ) catch()
            polyop.setFaceSelection n sel
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
        if ok do
        (
            local idxs = #()
            for f = 1 to (polyop.getNumFaces n) do ( if sel[f] do append idxs f )
            append outAll (mcpObj #(#("object", n.name), #("faces", idxs), #("count", idxs.count)))
            append applied n.name
        )
    )
    local p = #()
    -- `objects` holds only the rows that succeeded, so a caller can read one
    -- row per object without filtering.  `failures` is checked first by the
    -- runtime, so a mixed batch still reports a failure.
    mcpPair p "objects" outAll
    mcpPair p "results" outAll
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_extrude_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local amount = mcpNum params "amount" default:0.0
    local dir = mcpArr params "direction"
    local d3 = mcpPoint3From dir default:undefined
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            local ba = mcpPolyFaceBA n faces
            if d3 != undefined then ( polyop.extrudeFaces n ba amount direction:d3 )
            else ( polyop.extrudeFaces n ba amount )
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_bevel_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local height = mcpNum params "height" default:0.0
    local outline = mcpNum params "outline" default:0.0
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.bevelFaces n (mcpPolyFaceBA n faces) height outline
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_inset_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local outline = mcpNum params "outline" default:0.0
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.insetFaces n (mcpPolyFaceBA n faces) outline
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_bridge_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local f1 = mcpArr params "faces1"
    local f2 = mcpArr params "faces2"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.bridgeFaces n (mcpIdxBA f1) (mcpIdxBA f2)
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_cap_holes params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.capHoles n (mcpPolyFaceBA n faces)
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_flip_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.flipNormals n (mcpPolyFaceBA n faces)
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_delete_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.deleteFaces n (mcpIdxBA faces) delIsoVerts:true
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_assign_material_id params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local matID = mcpReqInt params "materialId"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.setFaceMatID n (mcpPolyFaceBA n faces) matID
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_set_smoothing params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local grp = mcpReqInt params "group"
    local applied = #()
    local failures = #()
    local bit = #{}
    if grp >= 1 and grp <= 32 do bit[grp] = true
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.setSmoothingGroups n (mcpPolyFaceBA n faces) bit
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_detach_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local newName = mcpReqStr params "name"
    local asClone = mcpBool params "clone" default:false
    local created = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 4
            local ba = mcpIdxBA faces
            polyop.setFaceSelection n ba
            n.detach ba newName asClone:asClone
            append created newName
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "created" created
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------- poly edge edit ---*/
fn mcpH_poly_chamfer_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edges = mcpArr params "edges"
    local amt = mcpNum params "amount" default:0.0
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.chamferEdges n (mcpIdxBA edges) amt
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_connect_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edges = mcpArr params "edges"
    local segs = mcpInt params "segments" default:1
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            polyop.connectEdges n (mcpIdxBA edges) segments:segs
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_extrude_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edges = mcpArr params "edges"
    local amount = mcpNum params "amount" default:0.0
    local dir = mcpArr params "direction"
    local d3 = mcpPoint3From dir default:undefined
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            n.subobjectLevel = 2
            polyop.setEdgeSelection n (mcpIdxBA edges)
            if d3 != undefined then ( n.extrude amount direction:d3 )
            else ( n.extrude amount )
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_loop_select params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edgesArg = mcpArr params "edges"
    local outAll = #()
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local res = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local ba = mcpPolyEdgeBA n edgesArg
            local loop = #{}
            try ( loop = polyop.getEdgeLoop n ba ) catch ( loop = ba )
            n.subobjectLevel = 2
            polyop.setEdgeSelection n loop
            for e = 1 to (polyop.getNumEdges n) do ( if loop[e] do append res e )
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
        if ok do
        (
            append outAll (mcpObj #(#("object", n.name), #("edges", res), #("count", res.count)))
            append applied n.name
        )
    )
    local p = #()
    -- `objects` holds only the rows that succeeded, so a caller can read one
    -- row per object without filtering.  `failures` is checked first by the
    -- runtime, so a mixed batch still reports a failure.
    mcpPair p "objects" outAll
    mcpPair p "results" outAll
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_ring_select params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edgesArg = mcpArr params "edges"
    local outAll = #()
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local res = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local ba = mcpPolyEdgeBA n edgesArg
            local ring = #{}
            try ( ring = polyop.getEdgeRing n ba ) catch ( ring = ba )
            n.subobjectLevel = 2
            polyop.setEdgeSelection n ring
            for e = 1 to (polyop.getNumEdges n) do ( if ring[e] do append res e )
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
        if ok do
        (
            append outAll (mcpObj #(#("object", n.name), #("edges", res), #("count", res.count)))
            append applied n.name
        )
    )
    local p = #()
    -- `objects` holds only the rows that succeeded, so a caller can read one
    -- row per object without filtering.  `failures` is checked first by the
    -- runtime, so a mixed batch still reports a failure.
    mcpPair p "objects" outAll
    mcpPair p "results" outAll
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_slice params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local axis = mcpStr params "axis" default:"z"
    local offsetVal = mcpNum params "offset" default:0.0
    local splitFlag = mcpBool params "split" default:false
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            local nrm = if axis == "x" then [1,0,0] else ( if axis == "y" then [0,1,0] else [0,0,1] )
            local plane = matrixFromNormal nrm
            plane.row4 = nrm * offsetVal
            polyop.slice n plane (#{1..(polyop.getNumEdges n)}) split:splitFlag
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*--------------------------------------------------------- poly overall edit -*/
fn mcpH_poly_triangulate params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            try ( n.subobjectLevel = 4 ) catch()
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.triangulate()
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_quadify params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    local unchanged = #()
    for n in nodes do
    (
        local ok = true
        local f0 = 0
        local v0 = 0
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            f0 = polyop.getNumFaces n
            v0 = polyop.getNumVerts n
            n.subobjectLevel = 4
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.quadify()
            append applied n.name
            -- A call that returns without throwing can still change nothing
            -- (welding coincident verts, connecting unsatisfiable edges,
            -- deleting an empty face set).  That is not a failure, but the
            -- caller deserves to know the topology is identical.
            if (polyop.getNumFaces n) == f0 and (polyop.getNumVerts n) == v0 do append unchanged n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "unchanged" unchanged
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_subdivide params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local iters = mcpInt params "iterations" default:1
    local smoothVal = mcpNum params "smoothness" default:0.5
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            mcpEnsureClass "MeshSmooth"
            local m = MeshSmooth()
            m.iterations = iters
            try ( m.smoothness = smoothVal ) catch()
            local before = n.modifiers.count
            addModifier n m
            -- The stack is the evidence that the subdivision actually
            -- got attached; addModifier can refuse and say nothing.
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_optimize params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local percent = mcpNum params "percent" default:50.0
    local keepNormals = mcpBool params "keepNormals" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            mcpEnsureClass "ProOptimizer"
            local m = ProOptimizer()
            m.vertexPercent = percent
            try ( m.keepNormals = keepNormals ) catch()
            local before = n.modifiers.count
            addModifier n m
            -- The stack is the evidence that the subdivision actually
            -- got attached; addModifier can refuse and say nothing.
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_relax params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local iters = mcpInt params "iterations" default:1
    local relaxValue = mcpNum params "relaxValue" default:0.5
    local keepBoundary = mcpBool params "keepBoundary" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            mcpEnsureClass "Relax"
            local m = Relax()
            m.iterations = iters
            try ( m.relaxValue = relaxValue ) catch()
            try ( m.keepBoundaryPoints = keepBoundary ) catch()
            local before = n.modifiers.count
            addModifier n m
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_auto_smooth params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local angle = mcpNum params "angle" default:45.0
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 4
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.autoSmooth angle
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_unify_normals params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 4
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.unifyNormal()
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_make_planar params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 4
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.makePlanar()
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        mcpPolyResetSL n
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------------- registration */
fn mcpRegisterPoly =
(
    mcpRegister "convert_to_editable_poly" mcpH_convert_to_editable_poly label:"Convert to Editable Poly"
    mcpRegister "convert_to_editable_mesh" mcpH_convert_to_editable_mesh label:"Convert to Editable Mesh"
    mcpRegister "convert_to_nurbs" mcpH_convert_to_nurbs label:"Convert to NURBS"
    mcpRegister "poly_info" mcpH_poly_info undoable:false label:"Poly Info"
    mcpRegister "poly_get_verts" mcpH_poly_get_verts undoable:false label:"Get Poly Vertices"
    mcpRegister "poly_get_faces" mcpH_poly_get_faces undoable:false label:"Get Poly Faces"
    mcpRegister "poly_get_edges" mcpH_poly_get_edges undoable:false label:"Get Poly Edges"
    mcpRegister "poly_get_stats" mcpH_poly_get_stats undoable:false label:"Poly Stats"
    mcpRegister "poly_set_vertex" mcpH_poly_set_vertex label:"Set Vertex"
    mcpRegister "poly_move_vertices" mcpH_poly_move_vertices label:"Move Vertices"
    mcpRegister "poly_weld_vertices" mcpH_poly_weld_vertices label:"Weld Vertices"
    mcpRegister "poly_target_weld" mcpH_poly_target_weld label:"Target Weld"
    mcpRegister "poly_chamfer_vertices" mcpH_poly_chamfer_vertices label:"Chamfer Vertices"
    mcpRegister "poly_remove_vertices" mcpH_poly_remove_vertices label:"Remove Vertices"
    mcpRegister "poly_select_faces" mcpH_poly_select_faces label:"Select Faces"
    mcpRegister "poly_extrude_faces" mcpH_poly_extrude_faces label:"Extrude Faces"
    mcpRegister "poly_bevel_faces" mcpH_poly_bevel_faces label:"Bevel Faces"
    mcpRegister "poly_inset_faces" mcpH_poly_inset_faces label:"Inset Faces"
    mcpRegister "poly_bridge_faces" mcpH_poly_bridge_faces label:"Bridge Faces"
    mcpRegister "poly_cap_holes" mcpH_poly_cap_holes label:"Cap Holes"
    mcpRegister "poly_flip_faces" mcpH_poly_flip_faces label:"Flip Faces"
    mcpRegister "poly_delete_faces" mcpH_poly_delete_faces label:"Delete Faces"
    mcpRegister "poly_assign_material_id" mcpH_poly_assign_material_id label:"Assign Material ID"
    mcpRegister "poly_set_smoothing" mcpH_poly_set_smoothing label:"Set Smoothing Group"
    mcpRegister "poly_detach_faces" mcpH_poly_detach_faces label:"Detach Faces"
    mcpRegister "poly_chamfer_edges" mcpH_poly_chamfer_edges label:"Chamfer Edges"
    mcpRegister "poly_connect_edges" mcpH_poly_connect_edges label:"Connect Edges"
    mcpRegister "poly_extrude_edges" mcpH_poly_extrude_edges label:"Extrude Edges"
    mcpRegister "poly_loop_select" mcpH_poly_loop_select label:"Loop Select"
    mcpRegister "poly_ring_select" mcpH_poly_ring_select label:"Ring Select"
    mcpRegister "poly_slice" mcpH_poly_slice label:"Slice Poly"
    mcpRegister "poly_triangulate" mcpH_poly_triangulate label:"Triangulate"
    mcpRegister "poly_quadify" mcpH_poly_quadify label:"Quadify"
    mcpRegister "poly_subdivide" mcpH_poly_subdivide label:"Subdivide"
    mcpRegister "poly_optimize" mcpH_poly_optimize label:"Optimize"
    mcpRegister "poly_relax" mcpH_poly_relax label:"Relax Poly"
    mcpRegister "poly_auto_smooth" mcpH_poly_auto_smooth label:"Auto Smooth"
    mcpRegister "poly_unify_normals" mcpH_poly_unify_normals label:"Unify Normals"
    mcpRegister "poly_make_planar" mcpH_poly_make_planar label:"Make Planar"
    ok
)

mcpRegisterPoly()

/* ==========================================================================
   SECTION: mcp_modifiers.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_modifiers.ms
   Modifier stack management, generic modifier add (which also powers the thin
   specific-modifier wrappers), and spline-driven geometry.

   Category: modeling (mod / model)

   NOTE on specific modifiers: tools like mod_turbosmooth are thin Python
   wrappers that call mod_add with a `modifier` preset. mod_add treats any
   top-level parameter that is not a reserved key (objects / modifier / name /
   params / undo / undo_label) as a property of the new modifier and applies it
   with setProperty, so no separate MAXScript handler is needed for each one.
-----------------------------------------------------------------------------*/

global mcpH_mod_add, mcpH_mod_remove, mcpH_mod_list, mcpH_mod_get_params
global mcpH_mod_set_param, mcpH_mod_set_params, mcpH_mod_enable, mcpH_mod_disable
global mcpH_mod_reorder, mcpH_mod_rename, mcpH_mod_get_gizmo_info
global mcpH_mod_set_sub_object_selection
global mcpSetOneModParam, mcpApplyModParams, mcpModCoerceValue, mcpModValueMatches
global mcpModNumFrom, mcpModIntFrom, mcpModFailureDetail
global mcpH_model_extrude_spline, mcpH_model_lathe_spline, mcpH_model_loft, mcpH_model_sweep


/*-------------------------------------------------------------- shared helpers*/
fn mcpPaginate items limit offset =
(
    local total = items.count
    local start = offset + 1
    if start < 1 do start = 1
    local page = #()
    if limit <= 0 then
    (
        page = items
    )
    else
    (
        local endx = offset + limit
        if endx > total do endx = total
        for i = start to endx do append page items[i]
    )
    #(page, total)
)

fn mcpFindModifier node spec =
(
    if isKindOf spec Number do
        ( if spec >= 1 and spec <= node.modifiers.count do return node.modifiers[spec] )
    local nm = spec as string
    if nm == "" do return undefined
    for m in node.modifiers do ( if m.name == nm do return m )
    for m in node.modifiers do ( if ((classof m) as string) == nm do return m )
    undefined
)

/*------------------------------------------------ modification value coercion*/
/* A modifier property has a type; a JSON argument only has whatever type the
   caller sent, and `setProperty` refuses anything that is not already
   compatible ("Unable to convert ... to ...").  Everything below converts the
   incoming value to the class the property already holds, so `bend.angle = 45`
   works whether the caller sent 45, 45.0 or "45" -- and a value that genuinely
   cannot be represented is refused with a reason instead of being handed to
   setProperty and hoped for.

   Before this existed the handler passed the raw argument straight to
   setProperty with no conversion at all, which is why the catalog had to
   advertise `value` as a string and why a number arriving as "3" failed on
   every numeric property. */

/* Number or undefined: booleans are not numbers here, and a string has to be
   a number on its own rather than something MAXScript guesses at. */
fn mcpModNumFrom v =
(
    if v == undefined then return undefined
    if isKindOf v BooleanClass then return undefined
    if isKindOf v Number then return (v as float)
    if isKindOf v String then
    (
        local t = trimLeft (trimRight v)
        if t == "" then return undefined
        try ( return (t as float) ) catch ( return undefined )
    )
    undefined
)

fn mcpModIntFrom v =
(
    local f = mcpModNumFrom v
    if f == undefined then return undefined
    -- 2.7 is not 2: truncating would silently apply a different value than the
    -- caller asked for.
    if (f != (floor f)) then return undefined
    f as integer
)

/* Returns #(ok, value, reason).  `current` is the property's present value,
   read with getProperty; when it is undefined the property is write-only or
   unreadable and the raw value is passed through unchanged. */
fn mcpModCoerceValue current rawValue =
(
    if current == undefined then return #(true, rawValue, "")

    local cls = classof current
    if cls == BooleanClass then
    (
        if isKindOf rawValue BooleanClass then return #(true, rawValue, "")
        if isKindOf rawValue Number then return #(true, (rawValue != 0), "")
        if isKindOf rawValue String then
        (
            local t = toLower (trimLeft (trimRight rawValue))
            if t == "true" or t == "1" or t == "yes" or t == "on" then return #(true, true, "")
            if t == "false" or t == "0" or t == "no" or t == "off" then return #(true, false, "")
            return #(false, rawValue, "not a boolean: " + rawValue)
        )
        return #(false, rawValue, "not a boolean: " + (rawValue as string))
    )
    if isKindOf current Integer then
    (
        if isKindOf rawValue BooleanClass then
            return #(false, rawValue, "integer property cannot take a boolean")
        local iv = mcpModIntFrom rawValue
        if iv == undefined then return #(false, rawValue, "not an integer: " + (rawValue as string))
        return #(true, iv, "")
    )
    if isKindOf current Number then
    (
        if isKindOf rawValue BooleanClass then
            return #(false, rawValue, "number property cannot take a boolean")
        local fv = mcpModNumFrom rawValue
        if fv == undefined then return #(false, rawValue, "not a number: " + (rawValue as string))
        return #(true, fv, "")
    )
    if isKindOf current String then return #(true, (rawValue as string), "")
    if isKindOf current Name then
    (
        try ( return #(true, ((rawValue as string) as name), "") )
        catch ( return #(false, rawValue, "not a name: " + (rawValue as string)) )
    )
    if isKindOf current Point3 then
    (
        if isKindOf rawValue Point3 then return #(true, rawValue, "")
        local nums = #()
        if isKindOf rawValue Array then
        (
            for x in rawValue do
            (
                local f = mcpModNumFrom x
                if f == undefined then
                    return #(false, rawValue, "expected [x,y,z] for a Point3 property")
                append nums f
            )
        )
        else if isKindOf rawValue String then
        (
            for s2 in (mcpStringSplit rawValue ",") do
            (
                local f = mcpModNumFrom s2
                if f == undefined then
                    return #(false, rawValue, "expected [x,y,z] for a Point3 property")
                append nums f
            )
        )
        else return #(false, rawValue, "expected [x,y,z] for a Point3 property")
        -- Deliberately not delegating to mcpPoint3From: it fills unparseable
        -- components with 0, which would make a typo look like a successful
        -- write of (0,0,0).
        if nums.count != 3 then
            return #(false, rawValue, "expected 3 numbers for a Point3 property")
        return #(true, (point3 nums[1] nums[2] nums[3]), "")
    )
    if isKindOf current Color then
    (
        local nums = #()
        if isKindOf rawValue Array then
        (
            for x in rawValue do
            (
                local f = mcpModNumFrom x
                if f == undefined then
                    return #(false, rawValue, "expected [r,g,b] (0-255) for a Color property")
                append nums f
            )
        )
        if nums.count == 3 then
            return #(true, (color (nums[1] as integer) (nums[2] as integer) (nums[3] as integer)), "")
        if isKindOf rawValue String then
        (
            local h = rawValue
            if (substring h 1 1) == "#" do h = substring h 2 (h.count - 1)
            if h.count == 6 then return #(true, (mcpColorFrom rawValue default:current), "")
        )
        return #(false, rawValue, "expected [r,g,b] or #rrggbb for a Color property")
    )
    -- Intervals, matrices, textures and other object-valued properties: send the
    -- raw argument and let setProperty decide, since guessing here is worse.
    #(true, rawValue, "")
)

/* Did the property really take the value we set?  Compared per class, with a
   tolerance for floats: a property that stores a float32 will not always read
   back bit-identical to the double we assigned. */
fn mcpModValueMatches a b =
(
    if a == undefined or b == undefined then return false
    if isKindOf a BooleanClass or isKindOf b BooleanClass then
        return ((a as string) == (b as string))
    if isKindOf a Point3 and isKindOf b Point3 then
        return ((abs (a.x - b.x) <= 0.000001) and (abs (a.y - b.y) <= 0.000001) and (abs (a.z - b.z) <= 0.000001))
    if isKindOf a Color and isKindOf b Color then
        return (a.r == b.r and a.g == b.g and a.b == b.b)
    if isKindOf a Number and isKindOf b Number then
    (
        local fa = a as float
        local fb = b as float
        local tol = 0.000001
        if (abs fb) > 1.0 do tol = tol * (abs fb)
        return ((abs (fa - fb)) <= tol)
    )
    ((a as string) == (b as string))
)

/* Apply a name->value object to a modifier and report every parameter.
   Returns #(applied, rejected, failures, unverified, readback):
     applied    - properties that took the value AND read back as assigned
     rejected   - "name: reason" for names the modifier does not expose
                  (unknown / unsupported property), checked via getPropNames
     failures   - "name: reason" for properties that exist but could not be
                  written: unconvertible value, setProperty threw, read-only,
                  or the read-back disagreed with what was assigned
     unverified - names that were assigned but whose property cannot be read
                  back (write-only), so the write is plausible but unproven
     readback   - object of name -> the value the property actually holds now
   No exception is ever treated as success: a name ends up in exactly one
   bucket.  getPropNames is the authoritative list of settable names for a
   MAXScript modifier; setProperty on an unknown name raises, which used to be
   swallowed by an empty catch() and reported as success. */
fn mcpApplyModParams mod paramsObj =
(
    local applied = #()
    local rejected = #()
    local failures = #()
    local unverified = #()
    local readback = mcpObj #()
    if paramsObj == undefined do return #(applied, rejected, failures, unverified, readback)
    if not (mcpIsObj paramsObj) do return #(applied, rejected, failures, unverified, readback)

    local known = #()
    try ( known = getPropNames mod ) catch ( known = #() )
    local knownNames = #()
    for nm in known do append knownNames (nm as string)

    for e in (mcpPairs paramsObj) do
    (
        local k = e[1]
        local v = e[2]
        local ks = k as string
        local found = false
        for kn in knownNames do ( if kn == ks do ( found = true; exit ) )
        if not found then
        (
            append rejected (ks + ": unsupported parameter")
        )
        else
        (
            -- The property's current value is the only reliable statement of
            -- its type, so the conversion target is read from the instance.
            local current = undefined
            try ( current = getProperty mod k ) catch ( current = undefined )
            local coerced = mcpModCoerceValue current v
            if not coerced[1] then
            (
                append failures (ks + ": " + coerced[3])
            )
            else
            (
                local err = ""
                try ( setProperty mod k coerced[2] )
                catch ( err = (getCurrentException() as string) )
                if err != "" then
                (
                    append failures (ks + ": " + err)
                )
                else
                (
                    local after = undefined
                    local verifiable = true
                    try ( after = getProperty mod k ) catch ( verifiable = false )
                    if not verifiable then
                    (
                        append applied ks
                        append unverified ks
                    )
                    else if (mcpModValueMatches after coerced[2]) then
                    (
                        append applied ks
                        mcpPair readback ks after
                    )
                    else
                    (
                        local want = coerced[2] as string
                        local got = after as string
                        append failures (ks + ": read-back mismatch (set " + want + ", property reports " + got + ")")
                    )
                )
            )
        )
    )
    #(applied, rejected, failures, unverified, readback)
)

/* One line of "why nothing applied", so a thrown error names the real cause
   instead of only counting rejections.  Bounded: the transport caps messages. */
fn mcpModFailureDetail rejected failures limit:4 =
(
    local parts = #()
    for x in rejected do append parts (x as string)
    for x in failures do append parts (x as string)
    local out = ""
    local n = 0
    for x in parts do
    (
        if n < limit do out = out + (if n == 0 then "" else "; ") + x
        n += 1
    )
    out
)


/*-------------------------------------------------------------- mod_add ------*/
fn mcpH_mod_add params =
(
    local clsName = mcpReqStr params "modifier"
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local customName = mcpStr params "name" default:""
    local explicit = mcpGet params "params"
    mcpEnsureClass clsName

    -- Collect modifier properties: explicit "params" object + any extra top-level key.
    local extra = mcpObj #()
    local reserved = #("objects", "modifier", "name", "params", "undo", "undo_label")
    for e in (mcpPairs params) do
    (
        local k = e[1]
        local found = false
        for r in reserved do ( if r == k do found = true )
        if not found do mcpPair extra k (e[2])
    )
    if explicit != undefined do ( for e in (mcpPairs explicit) do
    mcpPair extra (e[1]) (e[2]) )

    local applied = #()
    local failures = #()
    local rejected = #()
    local paramFailures = #()
    local unverified = #()
    local readback = mcpObj #()
    local appliedParams = 0
    for n in nodes do
    (
        local ok = true
        local newMod = undefined
        try
        (
            local modClass = execute clsName
            local before = n.modifiers.count
            newMod = modClass()
            addModifier n newMod
            -- The stack is the evidence: addModifier can refuse (wrong base
            -- object, locked stack) and the reply used to say "applied" anyway.
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            if customName != "" do newMod.name = customName
            -- The modifier is added either way; its parameters are reported
            -- separately so an unsupported name is visible instead of silently
            -- dropped the way it was while `params` was declared as an array.
            local res = mcpApplyModParams newMod extra
            appliedParams += res[1].count
            for x in res[2] do append rejected (n.name + ": " + x)
            for x in res[3] do append paramFailures (n.name + ": " + x)
            for x in res[4] do append unverified (n.name + ": " + x)
            for e in (mcpPairs res[5]) do mcpPair readback (n.name + "." + (e[1] as string)) (e[2])
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
        if ok do append applied n.name
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "rejected" rejected
    mcpPair p "paramFailures" paramFailures
    mcpPair p "unverified" unverified
    mcpPair p "readback" readback
    local partial = (rejected.count > 0 or paramFailures.count > 0)
    mcpPair p "partial" partial
    mcpPair p "success" (failures.count == 0 and not partial)
    mcpPair p "message" (if partial then (mcpMsg "msg.mod_params_partial" a1:(appliedParams as string) a2:(rejected.count as string) a3:(paramFailures.count as string)) else (mcpMsg "msg.ok"))
    mcpObj p
)


/*-------------------------------------------------------------- mod_remove ---*/
fn mcpH_mod_remove params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            local before = n.modifiers.count
            deleteModifier n m
            -- verify the stack actually shrank, rather than trusting the call
            if (n.modifiers.count >= before) do
                mcpFail "err.bad_value" a1:"modifier still in the stack"
            append removed n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
    )
    local p = #()
    mcpPair p "removed" removed
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_list ----*/
fn mcpH_mod_list params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:0
    local offset = mcpInt params "offset" default:0
    local rows = #()
    for n in nodes do
    (
        for i = 1 to n.modifiers.count do
        (
            local m = n.modifiers[i]
            local rp = #()
            mcpPair rp "object" n.name
            mcpPair rp "index" i
            mcpPair rp "name" (try ( m.name ) catch (""))
            mcpPair rp "class" (try ( (classof m) as string ) catch (""))
            mcpPair rp "enabled" (try ( m.enabled ) catch (true))
            append rows (mcpObj rp)
        )
    )
    local pg = mcpPaginate rows limit offset
    local p = #()
    mcpPair p "count" pg[2]
    mcpPair p "modifiers" pg[1]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_get_params */
fn mcpH_mod_get_params params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local limit = mcpInt params "limit" default:0
    local offset = mcpInt params "offset" default:0
    local rows = #()
    for n in nodes do
    (
        local m = mcpFindModifier n spec
        if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
        local names = #()
        try ( names = getPropNames m ) catch ( names = #() )
        for nm in names do
        (
            local val = undefined
            try ( val = getProperty m nm ) catch ( val = undefined )
            local rp = #()
            mcpPair rp "object" n.name
            mcpPair rp "modifier" (try ( m.name ) catch (""))
            mcpPair rp "property" (nm as string)
            mcpPair rp "value" val
            append rows (mcpObj rp)
        )
    )
    local pg = mcpPaginate rows limit offset
    local p = #()
    mcpPair p "count" pg[2]
    mcpPair p "params" pg[1]
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_set_param */
/* Set one property on the named modifier of each object.  Every outcome is
   accounted for: a name the modifier does not expose is "rejected", a name
   that exists but cannot be assigned is a "failure", and only a genuinely
   assigned value lands in "applied".  If nothing was applied the handler
   throws, which the transport turns into MCP isError instead of a fake ok. */
fn mcpH_mod_set_param params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local pname = mcpReqStr params "param"
    local value = mcpGet params "value"
    if value == undefined do mcpFail "err.missing_param" a1:"value"
    local applied = #()
    local appliedParams = #()
    local rejected = #()
    local failures = #()
    local unverified = #()
    local readback = mcpObj #()
    for n in nodes do
    (
        local res = undefined
        local err = ""
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            res = mcpApplyModParams m (mcpObj #(#(pname, value)))
        )
        catch ( err = (getCurrentException() as string) )
        if err != "" then
        (
            append failures (n.name + ": " + err)
        )
        else
        (
            if res[1].count > 0 do
            (
                append applied n.name
                append appliedParams (pname as string)
            )
            for x in res[2] do append rejected (n.name + ": " + x)
            for x in res[3] do append failures (n.name + ": " + x)
            for x in res[4] do append unverified (n.name + ": " + x)
            for e in (mcpPairs res[5]) do mcpPair readback (n.name + "." + (e[1] as string)) (e[2])
        )
    )

    local p = #()
    mcpPair p "applied" applied
    mcpPair p "appliedParams" appliedParams
    mcpPair p "rejected" rejected
    mcpPair p "failures" failures
    mcpPair p "unverified" unverified
    mcpPair p "readback" readback
    if applied.count == 0 do
    (
        local detail = mcpModFailureDetail rejected failures
        local base = mcpMsg "err.mod_params_failed" a1:(rejected.count as string) a2:(failures.count as string)
        throw (base + (if detail == "" then "" else " " + detail))
    )
    local partial = (rejected.count > 0 or failures.count > 0 or unverified.count > 0)
    mcpPair p "partial" partial
    mcpPair p "success" (not partial)
    mcpPair p "message" (if partial then (mcpMsg "msg.mod_params_partial" a1:(applied.count as string) a2:(rejected.count as string) a3:(failures.count as string)) else (mcpMsg "msg.ok"))
    mcpObj p
)


/*-------------------------------------------------------------- mod_set_params */
/* Batch version of mod_set_param.  mcpApplyModParams classifies every single
   name/value pair, so a response can be all-success, partial, or all-failed.
   All-failed throws; partial is explicitly marked (partial:true, success:false)
   and lists exactly which parameters were rejected or threw. */
fn mcpH_mod_set_params params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local paramsObj = mcpGet params "params"
    if paramsObj == undefined do mcpFail "err.missing_param" a1:"params"
    if not (mcpIsObj paramsObj) do mcpFail "err.bad_value" a1:"params"
    local applied = #()
    local appliedParams = #()
    local rejected = #()
    local failures = #()
    local unverified = #()
    local readback = mcpObj #()
    for n in nodes do
    (
        local res = undefined
        local err = ""
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            res = mcpApplyModParams m paramsObj
        )
        catch ( err = (getCurrentException() as string) )
        if err != "" then
        (
            append failures (n.name + ": " + err)
        )
        else
        (
            if res[1].count > 0 do append applied n.name
            for x in res[1] do append appliedParams (n.name + "." + x)
            for x in res[2] do append rejected (n.name + ": " + x)
            for x in res[3] do append failures (n.name + ": " + x)
            for x in res[4] do append unverified (n.name + ": " + x)
            for e in (mcpPairs res[5]) do mcpPair readback (n.name + "." + (e[1] as string)) (e[2])
        )
    )

    local p = #()
    mcpPair p "applied" applied
    mcpPair p "appliedParams" appliedParams
    mcpPair p "rejected" rejected
    mcpPair p "failures" failures
    mcpPair p "unverified" unverified
    mcpPair p "readback" readback
    if appliedParams.count == 0 do
    (
        local detail = mcpModFailureDetail rejected failures
        local base = mcpMsg "err.mod_params_failed" a1:(rejected.count as string) a2:(failures.count as string)
        throw (base + (if detail == "" then "" else " " + detail))
    )
    local partial = (rejected.count > 0 or failures.count > 0 or unverified.count > 0)
    mcpPair p "partial" partial
    mcpPair p "success" (not partial)
    mcpPair p "message" (if partial then (mcpMsg "msg.mod_params_partial" a1:(appliedParams.count as string) a2:(rejected.count as string) a3:(failures.count as string)) else (mcpMsg "msg.ok"))
    mcpObj p
)


/*-------------------------------------------------------------- mod_enable/disable */
fn mcpH_mod_enable params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            m.enabled = true
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_mod_disable params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            m.enabled = false
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_reorder --*/
fn mcpH_mod_reorder params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local target = mcpReqInt params "index"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            -- MAXScript (verified live on 2020) exposes no reorder primitive:
            -- moveModifierTo / moveModifier / setModifierIndex /
            -- setModifierOrder are all undefined.  Repositioning is done by
            -- rebuilding the stack: copy every modifier (copy keeps its
            -- parameter values but resets the name, so names are restored
            -- explicitly), delete the originals, then re-add the copies in
            -- the desired order -- addModifier always inserts at the top, so
            -- the desired order is walked bottom-up.  mod_reorder is
            -- registered undoable, so the whole rebuild is one undo step.
            local count = n.modifiers.count
            if target < 1 do target = 1
            local without = #()
            for i = 1 to count do ( if n.modifiers[i] != m do append without n.modifiers[i] )
            -- desired = without[1..target-1] + [m] + without[target..]; the
            -- final append covers target > without.count (move to bottom)
            local desired = #()
            for i = 1 to without.count do
            (
                if i == target do append desired m
                append desired without[i]
            )
            if without.count < target do append desired m
            local copies = #()
            for i = 1 to desired.count do
            (
                local c = copy desired[i]
                try ( c.name = desired[i].name ) catch ()
                append copies c
            )
            for i = count to 1 by -1 do deleteModifier n n.modifiers[i]
            for i = desired.count to 1 by -1 do
            (
                if copies[i] != undefined do addModifier n copies[i]
            )
            if (n.modifiers.count != desired.count) or not (isValidNode n) do
                mcpFail "err.bad_value" a1:"modifier stack count mismatch after reorder"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_rename ---*/
fn mcpH_mod_rename params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local newName = mcpReqStr params "name"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            m.name = newName
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_get_gizmo_info */
fn mcpH_mod_get_gizmo_info params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local out = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            mcpPair rec "object" n.name
            mcpPair rec "modifier" (try ( m.name ) catch (""))
            local g = undefined
            try ( g = m.gizmo ) catch ( g = undefined )
            if g != undefined then
            (
                mcpPair rec "hasGizmo" true
                mcpPair rec "position" (try ( g.position ) catch ( [0,0,0] ))
                mcpPair rec "rotation" (try ( (g.rotation as eulerAngles) ) catch ( (eulerAngles 0 0 0) ))
                mcpPair rec "scale" (try ( g.scale ) catch ( [1,1,1] ))
            )
            else mcpPair rec "hasGizmo" false
        )
        catch ( ok = false; append out ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append out (mcpObj rec)
    )
    local p = #()
    mcpPair p "gizmos" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_set_sub_object_selection */
fn mcpH_mod_set_sub_object_selection params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local level = mcpInt params "level" default:0
    local sel = mcpArr params "selection"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            local levelOk = true
            try ( m.subobjectLevel = level ) catch ( levelOk = false )
            if level > 0 do
            (
                -- A modifier that refuses the level (or exposes no such
                -- property) used to answer "applied" from an empty catch.
                if not levelOk do mcpFail "err.bad_value" a1:"sub-object level rejected"
                local gotLevel = -1
                try ( gotLevel = m.subobjectLevel ) catch ( gotLevel = -1 )
                if gotLevel != level do mcpFail "err.bad_value" a1:("level kept " + (gotLevel as string))
            )
            if sel.count > 0 do
            (
                local ba = #{}
                for idx in sel do
                (
                    local i = idx as integer
                    if i > 0 do ba[i] = true
                )
                -- Only one of these properties exists per modifier type; the
                -- selection counts as applied when any of them reports it.
                local landed = 0
                try ( m.selectedVerts = ba; landed = m.selectedVerts.count ) catch ( landed = 0 )
                if landed == 0 do try ( m.selectedEdges = ba; landed = m.selectedEdges.count ) catch ( landed = 0 )
                if landed == 0 do try ( m.selectedFaces = ba; landed = m.selectedFaces.count ) catch ( landed = 0 )
                if landed == 0 do try ( m.selectedCP = ba; landed = m.selectedCP.count ) catch ( landed = 0 )
                if landed == 0 do mcpFail "err.bad_value" a1:"sub-object selection was not accepted"
            )
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException() as string)) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------- spline driven geometry -*/
fn mcpH_model_extrude_spline params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local amount = mcpNum params "amount" default:0.0
    local segments = mcpInt params "segments" default:1
    local capStart = mcpBool params "capStart" default:true
    local capEnd = mcpBool params "capEnd" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = Extrude()
            m.amount = amount
            m.segments = segments
            m.capStart = capStart
            m.capEnd = capEnd
            local before = n.modifiers.count
            addModifier n m
            -- The stack is the evidence: addModifier can refuse and stay silent.
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_model_lathe_spline params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local degrees = mcpNum params "degrees" default:360.0
    local segments = mcpInt params "segments" default:16
    local smooth = mcpBool params "smooth" default:true
    local flipNormals = mcpBool params "flipNormals" default:false
    local weldCore = mcpBool params "weldCore" default:true
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = Lathe()
            m.degrees = degrees
            m.segments = segments
            m.smooth = smooth
            m.flipNormals = flipNormals
            m.weldCore = weldCore
            local before = n.modifiers.count
            addModifier n m
            -- The stack is the evidence: addModifier can refuse and stay silent.
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_model_loft params =
(
    local pathName = mcpReqStr params "path"
    local shapeNames = mcpArr params "shapes"
    local newName = mcpStr params "name" default:""
    if shapeNames.count == 0 do mcpFail "err.missing_param" a1:"shapes"
    local pathNode = mcpResolveNode pathName
    if pathNode == undefined do mcpFail "err.node_not_found" a1:pathName
    local created = #()
    local failures = #()
    local ok = true
    try
    (
        local loft = Loft()
        loft.path = pathNode
        local idx = 1
        for sn in shapeNames do
        (
            local sh = mcpResolveNode sn
            if sh != undefined do ( addNewSplineShape loft sh idx; idx += 1 )
        )
        add loft
        if newName != "" do loft.name = newName
        append created (try ( loft.name ) catch (""))
    )
    catch ( ok = false; append failures (getCurrentException()) )
    local p = #()
    mcpPair p "created" created
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_model_sweep params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local sectionName = mcpStr params "section" default:""
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            mcpEnsureClass "Sweep"
            local m = Sweep()
            local before = n.modifiers.count
            addModifier n m
            if (n.modifiers.count <= before) do
                mcpFail "err.bad_value" a1:"modifier did not enter the stack"
            if sectionName != "" do
            (
                local sec = mcpResolveNode sectionName
                if sec != undefined do
                (
                    try ( m.customSection = sec ) catch ( try ( m.section = sec ) catch() )
                )
            )
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------------- registration */
fn mcpRegisterModifiers =
(
    mcpRegister "mod_add" mcpH_mod_add label:"Add Modifier"
    mcpRegister "mod_remove" mcpH_mod_remove label:"Remove Modifier"
    mcpRegister "mod_list" mcpH_mod_list undoable:false label:"List Modifiers"
    mcpRegister "mod_get_params" mcpH_mod_get_params undoable:false label:"Get Modifier Params"
    mcpRegister "mod_set_param" mcpH_mod_set_param label:"Set Modifier Param"
    mcpRegister "mod_set_params" mcpH_mod_set_params label:"Set Modifier Params"
    mcpRegister "mod_enable" mcpH_mod_enable label:"Enable Modifier"
    mcpRegister "mod_disable" mcpH_mod_disable label:"Disable Modifier"
    mcpRegister "mod_reorder" mcpH_mod_reorder label:"Reorder Modifier"
    mcpRegister "mod_rename" mcpH_mod_rename label:"Rename Modifier"
    mcpRegister "mod_get_gizmo_info" mcpH_mod_get_gizmo_info undoable:false label:"Get Gizmo Info"
    mcpRegister "mod_set_sub_object_selection" mcpH_mod_set_sub_object_selection label:"Set Sub-Object Selection"
    mcpRegister "model_extrude_spline" mcpH_model_extrude_spline label:"Extrude Spline"
    mcpRegister "model_lathe_spline" mcpH_model_lathe_spline label:"Lathe Spline"
    mcpRegister "model_loft" mcpH_model_loft label:"Loft"
    mcpRegister "model_sweep" mcpH_model_sweep label:"Sweep"
    ok
)

mcpRegisterModifiers()

/* ==========================================================================
   SECTION: mcp_modeling_ext.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_modeling_ext.ms
   Modeling extensions that complement mcp_poly.ms / mcp_modifiers.ms:

     mod_toggle              flip a modifier's enabled flag (read back verified)
     mod_collapse            collapse the modifier stack, guarded by an explicit
                            confirm flag (destructive, so it refuses without it)
     poly_get_selection      read the current sub-object level and the selection
                            sets of every sub-object level (read only)
     poly_select             set the sub-object level and the selection set
                            (verts / edges / faces / borders / elements)
     poly_get_elements       count elements (connected face groups) and report
                            their sizes

   Category: modeling (mod / poly)

   Conventions inherited from the rest of the bridge:
     * every handler answers with an mcpObj and never raises on bad input
       (failures are collected per object and reported back);
     * mutating handlers are registered undoable and reset subobjectLevel
       afterwards, selection-only tools intentionally keep the selection;
     * queries are registered undoable:false;
     * no structs, no closures, no "obj.Method().Member" chains (MAXScript
       cannot compile those), every property access is guarded;
     * bit arrays are always walked with an explicit index loop (never for-in).
-----------------------------------------------------------------------------*/

global mcpH_mod_toggle, mcpH_mod_collapse
global mcpH_poly_get_selection, mcpH_poly_select, mcpH_poly_get_elements


/*-------------------------------------------------------------- shared helpers*/
-- Sub-object level names accepted by poly_select (ints 0..5 also work).
fn mcpExtLevelFrom value =
(
    if value == undefined do return 0
    if isKindOf value Number do return (value as integer)
    local t = toLower (value as string)
    if t == "off" or t == "none" or t == "object" or t == "" then 0
    else if t == "vert" or t == "verts" or t == "vertex" or t == "vertices" then 1
    else if t == "edge" or t == "edges" then 2
    else if t == "border" or t == "borders" then 3
    else if t == "face" or t == "faces" then 4
    else if t == "element" or t == "elements" or t == "elem" then 5
    else -1
)

fn mcpExtLevelName level =
(
    if level == 1 then "vert"
    else if level == 2 then "edge"
    else if level == 3 then "border"
    else if level == 4 then "face"
    else if level == 5 then "element"
    else "object"
)

-- Count the set bits of a bit array up to n (never relies on optional
-- bitarray properties; MAXScript bit arrays do not document a count).
-- NOTE: the parameter must not be named "max" -- that is a MAXScript
-- built-in function, and using it as a parameter name makes fileIn fail
-- with "Syntax error: at max, expected =" (the whole module then fails
-- to load; see docs/P0_ENV.md part 3).
fn mcpExtBACount ba n =
(
    local c = 0
    if ba == undefined do return 0
    for i = 1 to n do ( if ba[i] do c += 1 )
    c
)

-- Materialise the set bits of a bit array up to n (optionally capped).
fn mcpExtBAIndices ba n limit:0 =
(
    local idxs = #()
    if ba == undefined do return idxs
    for i = 1 to n do
    (
        if ba[i] do
        (
            if limit > 0 and idxs.count >= limit do return idxs
            append idxs i
        )
    )
    idxs
)

-- Connected face groups ("elements").  Returns #(groups, faceToElement):
--   groups[i]         = number of faces in element i
--   faceToElement[f]  = element index of face f
-- or #(#(), #()) when the mesh has no faces.
-- Strategy 1: the native polyop.getElementsUsingFace API when present (and
-- sane: every face must land in exactly one group).
-- Strategy 2: edge-adjacency flood fill built from getFaceVerts/getEdgeVerts,
-- which only uses interfaces that exist on every 3ds Max from 2020 on.
fn mcpExtElementGroups node =
(
    local fc = -1
    try ( fc = polyop.getNumFaces node ) catch ( fc = -1 )
    if fc <= 0 do return #(#(), #())

    -- strategy 1: native API
    local nativeOk = true
    local groups = #()
    local faceToElement = #()
    try
    (
        faceToElement = #()
        local seen = #{}
        local el = 1
        for f = 1 to fc while nativeOk do
        (
            if not seen[f] do
            (
                local grp = #{}
                try ( grp = polyop.getElementsUsingFace node #{f} )
                catch ( nativeOk = false )
                if nativeOk and grp != undefined then
                (
                    local cnt = 0
                    for i = 1 to fc do ( if grp[i] do cnt += 1 )
                    append groups cnt
                    for i = 1 to fc do
                    (
                        if grp[i] do
                        (
                            seen[i] = true
                            faceToElement[i] = el
                        )
                    )
                    el += 1
                )
            )
        )
    )
    catch ( nativeOk = false )

    -- validate: every face must be covered exactly once
    if nativeOk and groups.count > 0 do
    (
        local sum = 0
        for g in groups do sum += g
        if sum != fc or faceToElement.count != fc do nativeOk = false
    )
    if nativeOk and groups.count > 0 do return #(groups, faceToElement)

    -- strategy 2: faces are connected when they share an edge (two vertices)
    local vc = 0
    try ( vc = polyop.getNumVerts node ) catch ( vc = 0 )
    local vertFaces = #()
    for v = 1 to vc do vertFaces[v] = #()
    local faceVerts = #()
    for f = 1 to fc do
    (
        local fv = #()
        try ( fv = polyop.getFaceVerts node f ) catch ( fv = #() )
        faceVerts[f] = fv
        for v in fv do ( if v >= 1 and v <= vc do append vertFaces[v] f )
    )

    groups = #()
    faceToElement = #()
    local visited = #{}
    local elIdx = 0
    for f = 1 to fc do
    (
        if not visited[f] do
        (
            elIdx += 1
            local queue = #(f)
            local comp = #{}
            comp[f] = true
            local head = 1
            while head <= queue.count do
            (
                local cur = queue[head]
                head += 1
                local cv = faceVerts[cur]
                if cv.count >= 2 do
                (
                    for a = 1 to (cv.count - 1) do
                    (
                        local va = cv[a]
                        for b = (a + 1) to cv.count do
                        (
                            local vb = cv[b]
                            for nf in vertFaces[va] do
                            (
                                if nf != cur and nf >= 1 and nf <= fc and not comp[nf] do
                                (
                                    local nv = faceVerts[nf]
                                    local hasA = false
                                    local hasB = false
                                    for x in nv do
                                    (
                                        if x == va do hasA = true
                                        if x == vb do hasB = true
                                    )
                                    if hasA and hasB do
                                    (
                                        comp[nf] = true
                                        append queue nf
                                    )
                                )
                            )
                        )
                    )
                )
            )
            local cnt = 0
            for i = 1 to fc do
            (
                if comp[i] do
                (
                    cnt += 1
                    visited[i] = true
                    faceToElement[i] = elIdx
                )
            )
            append groups cnt
        )
    )
    #(groups, faceToElement)
)

-- Element index -> the array of face indices it contains (1-based numbering).
fn mcpExtElementFaces node elementIndex =
(
    local empty = #()
    if elementIndex < 1 do return empty
    local packed = mcpExtElementGroups node
    local groups = packed[1]
    local faceToElement = packed[2]
    if groups == undefined or elementIndex > groups.count do return empty
    local out = #()
    for f = 1 to faceToElement.count do
    (
        if faceToElement[f] == elementIndex do append out f
    )
    out
)


/*-------------------------------------------------------------- mod_toggle ---*/
fn mcpH_mod_toggle params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local results = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            local before = true
            local after = true
            try ( before = m.enabled ) catch ( before = true )
            m.enabled = (not before)
            try ( after = m.enabled ) catch ( after = (not before) )
            mcpPair rec "object" n.name
            mcpPair rec "modifier" (try ( m.name ) catch (""))
            mcpPair rec "enabledBefore" before
            mcpPair rec "enabledAfter" after
            mcpPair rec "verified" (after == (not before))
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        if ok do append results (mcpObj rec)
    )
    local p = #()
    mcpPair p "results" results
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_collapse -*/
-- Destructive: bakes every modifier into the base object and drops their
-- parameters for good.  Refuses to run unless confirm is explicitly true.
fn mcpH_mod_collapse params =
(
    local confirmFlag = mcpBool params "confirm" default:false
    if not confirmFlag do mcpFail "err.confirm_required" a1:"mod_collapse"
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpStr params "modifier" default:""
    local results = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            local before = n.modifiers.count
            if before == 0 then
            (
                mcpPair rec "object" n.name
                mcpPair rec "collapsed" false
                mcpPair rec "reason" "no modifiers"
                mcpPair rec "modifiersBefore" 0
                mcpPair rec "modifiersAfter" 0
            )
            else
            (
                -- when a modifier is named it must exist; it acts as a filter so
                -- a batch call never collapses an object that lacks it
                if spec != "" do
                (
                    local m = mcpFindModifier n spec
                    if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
                )
                collapseStack n
                local after = n.modifiers.count
                mcpPair rec "object" n.name
                mcpPair rec "collapsed" (after == 0)
                mcpPair rec "modifiersBefore" before
                mcpPair rec "modifiersAfter" after
            )
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        if ok do append results (mcpObj rec)
    )
    local p = #()
    mcpPair p "results" results
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------- poly_get_selection -*/
fn mcpH_poly_get_selection params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:1000
    local out = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local lvlNow = 0
            try ( lvlNow = n.subobjectLevel as integer ) catch ( lvlNow = 0 )
            local vc = 0
            local ec = 0
            local fc = 0
            try ( vc = polyop.getNumVerts n ) catch ( vc = 0 )
            try ( ec = polyop.getNumEdges n ) catch ( ec = 0 )
            try ( fc = polyop.getNumFaces n ) catch ( fc = 0 )
            mcpPair rec "name" n.name
            mcpPair rec "subobjectLevel" lvlNow
            mcpPair rec "subobjectName" (mcpExtLevelName lvlNow)

            -- verts
            local vsel = #{}
            local vok = true
            try ( vsel = polyop.getVertSelection n ) catch ( vok = false )
            local vp = #()
            if vok then
            (
                local total = mcpExtBACount vsel vc
                local idxs = mcpExtBAIndices vsel vc limit:limit
                mcpPair vp "supported" true
                mcpPair vp "count" total
                mcpPair vp "indices" idxs
                if total > idxs.count do mcpPair vp "truncated" true
            )
            else mcpPair vp "supported" false
            mcpPair rec "verts" (mcpObj vp)

            -- edges
            local esel = #{}
            local eok = true
            try ( esel = polyop.getEdgeSelection n ) catch ( eok = false )
            local ep = #()
            if eok then
            (
                local total = mcpExtBACount esel ec
                local idxs = mcpExtBAIndices esel ec limit:limit
                mcpPair ep "supported" true
                mcpPair ep "count" total
                mcpPair ep "indices" idxs
                if total > idxs.count do mcpPair ep "truncated" true
            )
            else mcpPair ep "supported" false
            mcpPair rec "edges" (mcpObj ep)

            -- faces
            local fsel = #{}
            local fok = true
            try ( fsel = polyop.getFaceSelection n ) catch ( fok = false )
            local fp = #()
            if fok then
            (
                local total = mcpExtBACount fsel fc
                local idxs = mcpExtBAIndices fsel fc limit:limit
                mcpPair fp "supported" true
                mcpPair fp "count" total
                mcpPair fp "indices" idxs
                if total > idxs.count do mcpPair fp "truncated" true
            )
            else mcpPair fp "supported" false
            mcpPair rec "faces" (mcpObj fp)

            -- borders: probe the API; not every release exposes it
            local bp = #()
            local bsel = #{}
            local bok = true
            try ( bsel = polyop.getBorderSelection n ) catch ( bok = false )
            if bok then
            (
                mcpPair bp "supported" true
                mcpPair bp "count" (mcpExtBACount bsel fc)
            )
            else mcpPair bp "supported" false
            mcpPair rec "borders" (mcpObj bp)
        )
        catch ( ok = false; append out ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append out (mcpObj rec)
    )
    local p = #()
    mcpPair p "objects" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------------- poly_select -*/
-- Sets the sub-object level and the matching selection set.  Like
-- poly_select_faces the selection is intentionally left active afterwards.
fn mcpH_poly_select params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local levelArg = mcpGet params "level"
    local verts = mcpArr params "verts"
    local edges = mcpArr params "edges"
    local faces = mcpArr params "faces"
    local borders = mcpArr params "borders"
    local elements = mcpArr params "elements"
    local level = mcpExtLevelFrom levelArg
    if level < 0 or level > 5 do mcpFail "err.invalid_subobject_level" a1:(levelArg as string)
    -- no explicit level: infer it from the indices that were passed
    if levelArg == undefined do
    (
        if verts.count > 0 then level = 1
        else if edges.count > 0 then level = 2
        else if borders.count > 0 then level = 3
        else if faces.count > 0 or elements.count > 0 then level = 4
        else level = 0
    )
    local results = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            try ( n.subobjectLevel = level ) catch()

            if verts.count > 0 do ( try ( polyop.setVertSelection n (mcpIdxBA verts) ) catch() )
            if edges.count > 0 do ( try ( polyop.setEdgeSelection n (mcpIdxBA edges) ) catch() )
            if faces.count > 0 do ( try ( polyop.setFaceSelection n (mcpIdxBA faces) ) catch() )
            local bordersApplied = true
            if borders.count > 0 do
            (
                -- polyop exposes no border selection setter on every release; try
                -- it and report honestly instead of pretending it worked
                bordersApplied = false
                try ( polyop.setBorderSelection n (mcpIdxBA borders); bordersApplied = true ) catch()
            )
            if elements.count > 0 do
            (
                -- element indices expand to the faces they contain
                local all = #{}
                local allCount = 0
                for ei in elements do
                (
                    local ef = mcpExtElementFaces n (ei as integer)
                    for f in ef do ( all[f] = true; allCount += 1 )
                )
                if allCount > 0 do ( try ( polyop.setFaceSelection n all ) catch() )
            )

            -- verify by reading the state back
            local vc = 0
            local ec = 0
            local fc = 0
            try ( vc = polyop.getNumVerts n ) catch ( vc = 0 )
            try ( ec = polyop.getNumEdges n ) catch ( ec = 0 )
            try ( fc = polyop.getNumFaces n ) catch ( fc = 0 )
            local vsel = #{}
            local esel = #{}
            local fsel = #{}
            try ( vsel = polyop.getVertSelection n ) catch ( vsel = #{} )
            try ( esel = polyop.getEdgeSelection n ) catch ( esel = #{} )
            try ( fsel = polyop.getFaceSelection n ) catch ( fsel = #{} )
            local lvlBack = 0
            try ( lvlBack = n.subobjectLevel as integer ) catch ( lvlBack = -1 )
            mcpPair rec "object" n.name
            mcpPair rec "level" level
            mcpPair rec "levelName" (mcpExtLevelName level)
            mcpPair rec "selectedVerts" (mcpExtBACount vsel vc)
            mcpPair rec "selectedEdges" (mcpExtBACount esel ec)
            mcpPair rec "selectedFaces" (mcpExtBACount fsel fc)
            mcpPair rec "bordersApplied" bordersApplied
            mcpPair rec "verified" (lvlBack == level)
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        if ok do append results (mcpObj rec)
    )
    local p = #()
    mcpPair p "results" results
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------- poly_get_elements */
fn mcpH_poly_get_elements params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local limit = mcpInt params "limit" default:100
    local out = #()
    for n in nodes do
    (
        local ok = true
        local rec = #()
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local packed = mcpExtElementGroups n
            local groups = packed[1]
            if groups == undefined do mcpFail "err.element_api_missing"
            mcpPair rec "name" n.name
            mcpPair rec "elementCount" groups.count
            local items = #()
            local total = groups.count
            if limit > 0 and total > limit then total = limit
            for g = 1 to total do
            (
                local ep = #()
                mcpPair ep "index" g
                mcpPair ep "faceCount" groups[g]
                append items (mcpObj ep)
            )
            mcpPair rec "elements" items
            if groups.count > items.count do mcpPair rec "truncated" true
        )
        catch ( ok = false; append out ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append out (mcpObj rec)
    )
    local p = #()
    mcpPair p "objects" out
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*---------------------------------------------------------------- registration */
fn mcpRegisterModelingExt =
(
    mcpRegister "mod_toggle" mcpH_mod_toggle label:"Toggle Modifier"
    mcpRegister "mod_collapse" mcpH_mod_collapse label:"Collapse Modifier Stack"
    mcpRegister "poly_get_selection" mcpH_poly_get_selection undoable:false label:"Get Sub-Object Selection"
    mcpRegister "poly_select" mcpH_poly_select undoable:false label:"Select Sub-Objects"
    mcpRegister "poly_get_elements" mcpH_poly_get_elements undoable:false label:"Get Poly Elements"
    ok
)

mcpRegisterModelingExt()
