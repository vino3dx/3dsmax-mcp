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
