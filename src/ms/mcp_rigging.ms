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

fn mcpFindBoneIndex skinMod boneName =
(
    local nb = 0
    try ( nb = skinOps.getNumberBones skinMod ) catch ( nb = 0 )
    for i = 1 to nb do
    (
        local bn = try ( skinOps.getBoneName skinMod i ) catch ("")
        if bn == boneName do return i
    )
    -1
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
    try ( b.width = w; b.height = h ) catch()
    local nm = mcpStr params "name" default:""
    if nm != "" do try ( b.name = nm ) catch()
    local p = #()
    mcpPair p "bone" (mcpNodeInfo b)
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
    for i = 1 to (n - 1) do
    (
        local a = startP + (endP - startP) * ((i - 1) as float / (n - 1))
        local bpt = startP + (endP - startP) * (i as float / (n - 1))
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
    local sz = mcpPoint3From (mcpGet params "size") default:[10,10,10]
    try ( d.boxSize = sz ) catch()
    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    try ( d.position = pos ) catch()
    local nm = mcpStr params "name" default:""
    if nm != "" do try ( d.name = nm ) catch()
    local p = #()
    mcpPair p "object" (mcpNodeInfo d)
    mcpPair p "message" (mcpMsg "msg.created" a1:d.name)
    mcpObj p
)

fn mcpH_rig_create_point_helper params =
(
    local pt = Point()
    local sz = mcpNum params "size" default:1.0
    try ( pt.size = sz ) catch()
    local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
    try ( pt.position = pos ) catch()
    local nm = mcpStr params "name" default:""
    if nm != "" do try ( pt.name = nm ) catch()
    local p = #()
    mcpPair p "object" (mcpNodeInfo pt)
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
    for node in nodes do
    (
        if w >= 0 do try ( node.width = w ) catch()
        if h >= 0 do try ( node.height = h ) catch()
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for o in candidates do ( if (classof o) == BoneGeometry do append bones o )
    local all = for b in bones collect (mcpNodeInfo b)
    local p = #()
    mcpPair p "count" all.count
    mcpPaginateInto p all (mcpInt params "limit" default:500) (mcpInt params "offset" default:0)
    mcpObj p
)


/*------------------------------------------------------------ rigging: skin */
fn mcpH_rig_skin_add params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    for node in nodes do try ( addModifier node (Skin()) ) catch()
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "message" (mcpMsg "msg.skin_added" a1:(nodes.count as string))
    mcpObj p
)

fn mcpH_rig_skin_add_bone params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local boneNode = mcpResolveNode (mcpReqStr params "bone")
    local failed = #()
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
            try ( skinOps.addBone skinMod boneNode 0 ) catch ( append failed (node.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "bone" boneNode.name
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
            else
                try ( skinOps.setWeight skinMod bi vertex weight ) catch ( append failed (node.name + ": " + (getCurrentException())) )
        )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "vertex" vertex
    mcpPair p "failures" failed
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_skin_auto_weight params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local failed = #()
    for node in nodes do
    (
        local skinMod = mcpGetSkinMod node
        if skinMod == undefined then
            append failed (node.name + ": no Skin")
        else
            try ( skinOps.autoWeight skinMod ) catch ( append failed (node.name + ": " + (getCurrentException())) )
    )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
                try ( bi = skinOps.getVertexWeightBone skinMod v i ) catch ( bi = 0 )
                local bn = ""
                try ( bn = skinOps.getBoneName skinMod bi ) catch ( bn = "" )
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
    mcpPair p "objects" (for n in nodes collect n.name)
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
    mcpPair p "objects" (for n in nodes collect n.name)
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
    for node in nodes do
        try ( node.ikEnabled = true ) catch ( try ( node.isIKNode = true ) catch() )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "ikEnabled" true
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_rig_ik_disable params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    for node in nodes do
        try ( node.ikEnabled = false ) catch ( try ( node.isIKNode = false ) catch() )
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
    mcpPair p "ikEnabled" false
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*------------------------------------------------------------------ morph */
fn mcpH_rig_morpher_add params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    for node in nodes do try ( addModifier node (Morpher()) ) catch()
    local p = #()
    mcpPair p "objects" (for n in nodes collect n.name)
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
    mcpPair p "objects" (for n in nodes collect n.name)
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
