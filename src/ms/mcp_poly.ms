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
        try ( convertToPoly n; append applied n.name )
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
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.weldVertsByThreshold n (mcpIdxBA verts) thr
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

fn mcpH_poly_target_weld params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local v1 = mcpReqInt params "vertex"
    local v2 = mcpReqInt params "target"
    local thr = mcpNum params "threshold" default:0.1
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 1
            polyop.setVertSelection n #{v1}
            n.weldTarget (v2 as integer) thr
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

fn mcpH_poly_chamfer_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local amt = mcpNum params "amount" default:0.0
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.chamferVertices n (mcpIdxBA verts) amt
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

fn mcpH_poly_remove_vertices params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local verts = mcpArr params "vertices"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.deleteVerts n (mcpIdxBA verts)
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
        catch ( ok = false; append outAll ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do
        (
            local idxs = #()
            for f = 1 to (polyop.getNumFaces n) do ( if sel[f] do append idxs f )
            append outAll (mcpObj #(#("object", n.name), #("faces", idxs), #("count", idxs.count)))
        )
    )
    local p = #()
    mcpPair p "results" outAll
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
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local ba = mcpPolyFaceBA n faces
            if d3 != undefined then ( polyop.extrudeFaces n ba amount direction:d3 )
            else ( polyop.extrudeFaces n ba amount )
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

fn mcpH_poly_bevel_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local height = mcpNum params "height" default:0.0
    local outline = mcpNum params "outline" default:0.0
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.bevelFaces n (mcpPolyFaceBA n faces) height outline
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

fn mcpH_poly_inset_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local faces = mcpArr params "faces"
    local outline = mcpNum params "outline" default:0.0
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.insetFaces n (mcpPolyFaceBA n faces) outline
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

fn mcpH_poly_bridge_faces params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local f1 = mcpArr params "faces1"
    local f2 = mcpArr params "faces2"
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.bridgeFaces n (mcpIdxBA f1) (mcpIdxBA f2)
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

fn mcpH_poly_cap_holes params =
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
            polyop.capHoles n (mcpPolyFaceBA n faces)
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
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.deleteFaces n (mcpIdxBA faces) delIsoVerts:true
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
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.chamferEdges n (mcpIdxBA edges) amt
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

fn mcpH_poly_connect_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edges = mcpArr params "edges"
    local segs = mcpInt params "segments" default:1
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            polyop.connectEdges n (mcpIdxBA edges) segments:segs
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

fn mcpH_poly_extrude_edges params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edges = mcpArr params "edges"
    local amount = mcpNum params "amount" default:0.0
    local dir = mcpArr params "direction"
    local d3 = mcpPoint3From dir default:undefined
    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            n.subobjectLevel = 2
            polyop.setEdgeSelection n (mcpIdxBA edges)
            if d3 != undefined then ( n.extrude amount direction:d3 )
            else ( n.extrude amount )
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

fn mcpH_poly_loop_select params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edgesArg = mcpArr params "edges"
    local outAll = #()
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
        catch ( ok = false; append outAll ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append outAll (mcpObj #(#("object", n.name), #("edges", res), #("count", res.count)))
    )
    local p = #()
    mcpPair p "results" outAll
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_poly_ring_select params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local edgesArg = mcpArr params "edges"
    local outAll = #()
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
        catch ( ok = false; append outAll ("ERROR " + n.name + ": " + (getCurrentException())) )
        if ok do append outAll (mcpObj #(#("object", n.name), #("edges", res), #("count", res.count)))
    )
    local p = #()
    mcpPair p "results" outAll
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
    for n in nodes do
    (
        local ok = true
        try
        (
            if not (mcpEnsurePoly n) do mcpFail "err.poly_required" a1:n.name
            local nrm = if axis == "x" then [1,0,0] else ( if axis == "y" then [0,1,0] else [0,0,1] )
            local plane = matrixFromNormal nrm
            plane.row4 = nrm * offsetVal
            polyop.slice n plane (#{1..(polyop.getNumEdges n)}) split:splitFlag
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


/*--------------------------------------------------------- poly overall edit -*/
fn mcpH_poly_triangulate params =
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
            try ( n.subobjectLevel = 4 ) catch()
            polyop.setFaceSelection n (mcpPolyFaceBA n faces)
            n.triangulate()
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

fn mcpH_poly_quadify params =
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
            n.quadify()
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
            addModifier n m
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
            addModifier n m
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
            addModifier n m
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
