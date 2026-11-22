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
