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
global mcpSetOneModParam, mcpApplyModParams
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

/* Apply a name->value object to a modifier and report every parameter.
   Returns #(applied, rejected, failures):
     applied  - array of property names that were set successfully
     rejected - array of "name: reason" strings for names the modifier does not
                expose (unknown / unsupported property), checked via getPropNames
     failures - array of "name: reason" strings for properties that exist but
                whose assignment threw (invalid value, type mismatch, read-only)
   No exception is ever treated as success: a name ends up in exactly one bucket.
   getPropNames is the authoritative list of settable names for a MAXScript
   modifier; setProperty on an unknown name raises, which used to be swallowed
   by an empty catch() and reported as success. */
fn mcpApplyModParams mod paramsObj =
(
    local applied = #()
    local rejected = #()
    local failures = #()
    if paramsObj == undefined do return #(applied, rejected, failures)
    if not (mcpIsObj paramsObj) do return #(applied, rejected, failures)

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
            local err = ""
            try ( setProperty mod k v )
            catch ( err = (getCurrentException() as string) )
            if err == "" then append applied ks
            else append failures (ks + ": " + err)
        )
    )
    #(applied, rejected, failures)
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
    if explicit != undefined do ( for e in (mcpPairs explicit) do mcpPair extra (e[1]) (e[2]) )

    local applied = #()
    local failures = #()
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
            if customName != "" and n.modifiers.count > before do newMod.name = customName
            mcpApplyModParams newMod extra
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
        if ok do append applied n.name
    )
    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)


/*-------------------------------------------------------------- mod_remove ---*/
fn mcpH_mod_remove params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local spec = mcpReqStr params "modifier"
    local removed = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local m = mcpFindModifier n spec
            if m == undefined do mcpFail "msg.no_modifier" a1:n.name a2:spec
            deleteModifier n m
            append removed n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
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
        )
    )

    local p = #()
    mcpPair p "applied" applied
    mcpPair p "appliedParams" appliedParams
    mcpPair p "rejected" rejected
    mcpPair p "failures" failures
    if applied.count == 0 do
        mcpFail "err.mod_params_failed" a1:(rejected.count as string) a2:(failures.count as string)
    local partial = (rejected.count > 0 or failures.count > 0)
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
        )
    )

    local p = #()
    mcpPair p "applied" applied
    mcpPair p "appliedParams" appliedParams
    mcpPair p "rejected" rejected
    mcpPair p "failures" failures
    if appliedParams.count == 0 do
        mcpFail "err.mod_params_failed" a1:(rejected.count as string) a2:(failures.count as string)
    local partial = (rejected.count > 0 or failures.count > 0)
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
            try ( m.subobjectLevel = level ) catch()
            if sel.count > 0 do
            (
                local ba = #{}
                for idx in sel do
                (
                    local i = idx as integer
                    if i > 0 do ba[i] = true
                )
                try ( m.selectedVerts = ba ) catch()
                try ( m.selectedEdges = ba ) catch()
                try ( m.selectedFaces = ba ) catch()
                try ( m.selectedCP = ba ) catch()
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
            addModifier n m
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
