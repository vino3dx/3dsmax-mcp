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

-- Count the set bits of a bit array up to max (never relies on optional
-- bitarray properties; MAXScript bit arrays do not document a count).
fn mcpExtBACount ba max =
(
    local c = 0
    if ba == undefined do return 0
    for i = 1 to max do ( if ba[i] do c += 1 )
    c
)

-- Materialise the set bits of a bit array up to max (optionally capped).
fn mcpExtBAIndices ba max limit:0 =
(
    local idxs = #()
    if ba == undefined do return idxs
    for i = 1 to max do
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
            if before == 0 do
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
        if verts.count > 0 do level = 1
        else if edges.count > 0 do level = 2
        else if borders.count > 0 do level = 3
        else if faces.count > 0 or elements.count > 0 do level = 4
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
    mcpRegister "poly_select" mcpH_poly_select label:"Select Sub-Objects"
    mcpRegister "poly_get_elements" mcpH_poly_get_elements undoable:false label:"Get Poly Elements"
    ok
)

mcpRegisterModelingExt()
