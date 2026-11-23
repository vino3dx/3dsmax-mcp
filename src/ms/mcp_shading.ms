/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_shading.ms
   Consolidated shading module: materials, texture maps, material libraries,
   UVW mapping, lights, cameras, and environment.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_shading.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_shading.ms
   Materials, material maps and material libraries.

   Category: shading
-----------------------------------------------------------------------------*/

global mcpResolveMaterial, mcpRequireMat, mcpMatUsedBy, mcpMatDetails, mcpMatGetMap
global mcpAssignCreatedMat, mcpMapInfo, mcpShadePage
global mcpH_mat_list, mcpH_mat_get, mcpH_mat_get_for_object, mcpH_mat_slots, mcpH_mat_set_slot
global mcpH_mat_assign, mcpH_mat_set_property, mcpH_mat_set_diffuse, mcpH_mat_set_pbr
global mcpH_mat_set_specular, mcpH_mat_set_opacity, mcpH_mat_set_emission
global mcpH_mat_set_sub_material, mcpH_mat_rename, mcpH_mat_delete, mcpH_mat_duplicate
global mcpH_mat_set_map_slot, mcpH_mat_get_map_slot
global mcpH_mat_create_standard, mcpH_mat_create_physical, mcpH_mat_create_guarded
global mcpH_mat_create_generic, mcpH_mat_create_multi_sub, mcpH_mat_create_blend, mcpH_mat_create_shellac
global mcpH_map_create_bitmap, mcpH_map_set_bitmap_path, mcpH_map_create_checker
global mcpH_map_create_gradient, mcpH_map_create_gradient_ramp, mcpH_map_create_noise
global mcpH_map_create_falloff, mcpH_map_create_color_correct, mcpH_map_create_normal
global mcpH_mat_library_load, mcpH_mat_library_save


/*--------------------------------------------------------------- material helpers*/
fn mcpResolveMaterial spec =
(
  if spec == undefined do return undefined
  local s = if isKindOf spec String then spec else (try (spec as string) catch (""))
  if s == "" do return undefined
  try ( for m in sceneMaterials do ( if m.name == s do return m ) ) catch()
  try ( for i = 1 to 24 do ( local mm = meditMaterials[i]; if mm != undefined and mm.name == s do return mm ) ) catch()
  undefined
)

fn mcpRequireMat spec =
(
  local m = mcpResolveMaterial spec
  if m == undefined do mcpFail "err.not_found_in_list" a1:(spec as string) a2:"materials"
  m
)

fn mcpMatUsedBy m =
(
  local c = 0
  try ( for o in objects do ( if o.material == m do c += 1 ) ) catch()
  c
)

/* Friendly slot name -> the property the material actually stores the map in.
   "diffuse" is *not* a map property on a Standard material: setProperty would
   write the Checker into the diffuse *colour* and Max answers "unable to
   convert Checker to Point3".  The real names are diffuseMap / bumpMap /
   opacityMap / ..., and the Arnold and Physical materials use their own
   spelling (base_color_map, ...), so resolve instead of guessing. */
fn mcpMatMapAliases slot =
(
  local s = toLower slot
  case s of
  (
    "diffuse": #("diffuseMap", "base_color_map", "baseColor_map", "diffuse_color_map")
    "basecolor": #("base_color_map", "baseColor_map", "diffuseMap")
    "base_color": #("base_color_map", "baseColor_map", "diffuseMap")
    "bump": #("bumpMap", "bump_map")
    "normal": #("normals_map", "normalMap", "bumpMap", "bump_map")
    "opacity": #("opacityMap", "opacity_map")
    "specular": #("specularMap", "specular_color_map", "specularMap")
    "glossiness": #("glossinessMap", "specular_roughness_map", "glossiness_map")
    "roughness": #("specular_roughness_map", "roughnessMap", "glossinessMap")
    "reflection": #("reflectionMap", "reflection_color_map")
    "refraction": #("refractionMap", "refraction_color_map")
    "displacement": #("displacementMap")
    "emission": #("selfIllumMap", "emission_color_map", "emissionMap")
    "selfillumination": #("selfIllumMap", "emission_color_map")
    "ao": #("ao_map", "ambientOcclusionMap")
    default: #()
  )
)

fn mcpMatEndsWithMap name =
(
  local s = toLower (name as string)
  local n = s.count
  if n < 3 do return false
  (substring s (n - 2) 3) == "map" or (n > 3 and (substring s (n - 3) 4) == "_map")
)

fn mcpMatMapPropName m slot =
(
  local wanted = toLower (slot as string)
  local props = #()
  try ( props = getPropNames m ) catch ( props = #() )

  /* Order matters.  A Standard material has BOTH "Diffuse" (the colour) and
     "DiffuseMap" (the map).  Matching the exact name first resolved "diffuse"
     to the colour and then failed with "unable to convert Checker to Point3",
     so map-looking names are tried before the plain name. */
  -- 1) the caller already used a real map property name
  for p in props do
      ( if (toLower (p as string)) == wanted and (mcpMatEndsWithMap p) do return p )
  -- 2) "diffuse" -> "diffuseMap" / "diffuse_map"
  for p in props do ( if (toLower (p as string)) == (wanted + "map") do return p )
  for p in props do ( if (toLower (p as string)) == (wanted + "_map") do return p )
  -- 3) known aliases for the classes that spell it differently
  for cand in (mcpMatMapAliases wanted) do
  (
    local want = toLower cand
    for p in props do ( if (toLower (p as string)) == want do return p )
  )
  -- Deliberately NO plain exact-name fallback: on a Standard material "diffuse"
  -- matches the Diffuse *colour*, and writing a map there fails with
  -- "unable to convert Checker to Point3".  Materials that keep their maps in
  -- numbered channels instead of properties are handled by mcpMatMapChannel.
  undefined
)

/* Legacy materials (Standard, Raytrace, Architectural, ...) do not expose
   diffuseMap / bumpMap as MAXScript properties: their maps live in numbered
   sub-texmap channels, which is also what the material editor labels.  The
   numbering below is the 3ds Max Standard layout and is shared by most of the
   older material classes. */
fn mcpMatMapChannel slot =
(
  local s = toLower (slot as string)
  case s of
  (
    "ambient": 1
    "diffuse": 2
    "basecolor": 2
    "base_color": 2
    "specular": 3
    "specularlevel": 4
    "specular_level": 4
    "glossiness": 5
    "selfillum": 6
    "selfillumination": 6
    "emission": 6
    "opacity": 7
    "filter": 8
    "filtercolor": 8
    "bump": 9
    "normal": 9
    "reflection": 10
    "refraction": 11
    "displacement": 12
    default: 0
  )
)

fn mcpMatGetMap m slot =
(
  local theMap = undefined
  local prop = mcpMatMapPropName m slot
  if prop != undefined do
    try ( theMap = getProperty m prop ) catch ( theMap = undefined )
  if not (isKindOf theMap TextureMap) do
  (
    theMap = undefined
    local ch = mcpMatMapChannel slot
    if ch > 0 do
    (
      local sub = try ( getSubTexmap m ch ) catch ( undefined )
      if (isKindOf sub TextureMap) do theMap = sub
    )
  )
  theMap
)

/* Returns a short description of where the map landed ("diffuseMap" or
   "channel 2"), or undefined when the slot cannot be resolved. */
fn mcpMatSetMap m slot theMap =
(
  local prop = mcpMatMapPropName m slot
  if prop != undefined do
  (
    local ok = true
    try ( setProperty m prop theMap ) catch ( ok = false )
    if ok do return (prop as string)
  )
  local ch = mcpMatMapChannel slot
  if ch > 0 do
  (
    local ok = true
    try ( setSubTexmap m ch theMap ) catch ( ok = false )
    if ok do
    (
      local got = try ( getSubTexmap m ch ) catch ( undefined )
      if got == theMap do return ("channel " + (ch as string))
    )
  )
  undefined
)

fn mcpMatDetails m =
(
  local p = #()
  mcpPair p "class" (try ((classof m) as string) catch (""))
  mcpPair p "name" (try (m.name) catch (""))
  mcpPair p "diffuse" (try (m.diffuse) catch (undefined))
  mcpPair p "specular" (try (m.specular) catch (undefined))
  mcpPair p "baseColor" (try (m.base_color) catch (undefined))
  mcpPair p "metallic" (try (m.metallic) catch (undefined))
  mcpPair p "roughness" (try (m.roughness) catch (undefined))
  mcpPair p "ior" (try (m.reflection_iOR) catch (try (m.IOR) catch (undefined)))
  mcpPair p "opacity" (try (m.opacity) catch (undefined))
  mcpPair p "emission" (try (m.emission_color) catch (try (m.selfIllumColor) catch (undefined)))
  local slots = #()
  try
  (
    for prop in (getPropNames m) do
    (
      local v = getProperty m prop
      if isKindOf v TextureMap do
      (
        local sp = #()
        mcpPair sp "slot" (prop as string)
        mcpPair sp "mapClass" (try ((classof v) as string) catch (""))
        mcpPair sp "filename" (try (v.filename) catch (""))
        append slots (mcpObj sp)
      )
    )
  )
  catch()
  mcpPair p "mapSlots" slots
  local subs = #()
  try ( for sm in (getSubMtls m) do append subs (try ((classof sm) as string) catch ("")) ) catch()
  mcpPair p "subMaterials" subs
  mcpObj p
)

fn mcpShadePage arr limit offset =
(
  if limit < 1 do limit = 100
  local total = arr.count
  local lo = offset + 1
  local hi = offset + limit
  if hi > total do hi = total
  local out = #()
  if lo <= total do ( for i = lo to hi do append out arr[i] )
  #(out, total)
)

fn mcpAssignCreatedMat m params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:false silent:true
  for n in nodes do ( try ( n.material = m ) catch() )
  -- register the created material so mat_get / mat_assign / mat_list can
  -- find it by name afterwards (mcpResolveMaterial searches sceneMaterials
  -- and the medit slots); skip if it is already registered
  try (
    if (try ( m.name ) catch ("")) != "" do
    (
      local nm = try ( m.name ) catch ("")
      local known = false
      for m2 in sceneMaterials do ( if (try ( m2.name ) catch ("?")) == nm do known = true )
      if not known do append sceneMaterials m
    )
  ) catch()
  local p = #()
  -- Declare the outcome: by this point the material object exists, so this is a
  -- real success rather than an assumption.  Without it the reliability mode
  -- (--profile core) reported every mat_create_* call as missing_success,
  -- because the Python runtime only accepted an explicit success/ok flag.
  mcpPair p "success" (m != undefined)
  mcpPair p "class" (try ((classof m) as string) catch (""))
  mcpPair p "name" (try (m.name) catch (""))
  local assigned = #()
  for n in nodes do append assigned (try (n.name) catch (""))
  mcpPair p "assignedTo" assigned
  mcpPair p "message" (mcpMsg "msg.created" a1:(try (m.name) catch ("")))
  mcpObj p
)

fn mcpMapInfo m =
(
  local p = #()
  -- Only reached from handlers that just built or attached a map, so a reply
  -- means the map object exists; declare that instead of making the runtime
  -- guess from a class name.
  mcpPair p "success" true
  mcpPair p "class" (try ((classof m) as string) catch (""))
  mcpPair p "filename" (try (m.filename) catch (""))
  mcpObj p
)


/*----------------------------------------------------------------- material list*/
fn mcpH_mat_list params =
(
  local limit = mcpInt params "limit" default:100
  local offset = mcpInt params "offset" default:0
  local all = #()
  try
  (
    for m in sceneMaterials do
    (
      local it = #()
      mcpPair it "class" (try ((classof m) as string) catch (""))
      mcpPair it "name" (try (m.name) catch (""))
      mcpPair it "usedBy" (mcpMatUsedBy m)
      append all (mcpObj it)
    )
  )
  catch()
  local pg = mcpShadePage all limit offset
  local p = #()
  mcpPair p "count" pg[2]
  mcpPair p "offset" offset
  mcpPair p "limit" limit
  mcpPair p "materials" pg[1]
  mcpObj p
)

fn mcpH_mat_get params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  mcpMatDetails m
)

fn mcpH_mat_get_for_object params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local out = #()
  for n in nodes do
  (
    local it = #()
    mcpPair it "object" (try (n.name) catch (""))
    try ( if n.material != undefined then mcpPair it "material" (mcpMatDetails n.material) else
    mcpPair it "material" undefined ) catch()
    append out (mcpObj it)
  )
  local p = #()
  mcpPair p "count" out.count
  mcpPair p "objects" out
  mcpObj p
)

fn mcpH_mat_slots params =
(
  local out = #()
  local cnt = 0
  for i = 1 to 24 do
  (
    local m = undefined
    try ( m = meditMaterials[i] ) catch ( m = undefined )
    if m != undefined do
    (
      cnt += 1
      local it = #()
      mcpPair it "slot" i
      mcpPair it "class" (try ((classof m) as string) catch (""))
      mcpPair it "name" (try (m.name) catch (""))
      append out (mcpObj it)
    )
  )
  local p = #()
  mcpPair p "count" cnt
  mcpPair p "slots" out
  mcpObj p
)

fn mcpH_mat_set_slot params =
(
  local slot = mcpReqInt params "slot"
  local m = mcpRequireMat (mcpStr params "material" default:"")
  if slot < 1 or slot > 24 do mcpFail "err.bad_value" a1:"slot"
  try ( meditMaterials[slot] = m ) catch ( mcpFail "err.invalid_argument" a1:"slot" a2:(getCurrentException() as string) )
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "slot" slot
  mcpPair p "name" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)


/*------------------------------------------------------------------ material edit*/
fn mcpH_mat_assign params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local applied = #()
  local failures = #()
  for n in nodes do
  (
    try
    (
      n.material = m
      if n.material == m then append applied n.name
      else append failures (n.name + ": material did not stick")
    )
    catch ( append failures (n.name + ": " + (getCurrentException() as string)) )
  )
  local p = #()
  mcpPair p "success" (failures.count == 0 and applied.count > 0)
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "applied" applied
  mcpPair p "failures" failures
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_property params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local prop = mcpReqStr params "property"
  local raw = mcpGet params "value"
  if raw == undefined do mcpFail "err.missing_param" a1:"value"
  local target = undefined
  try ( target = getProperty m (prop as name) ) catch ( target = undefined )
  local val = undefined
  if isKindOf target Color then val = mcpColorFrom raw default:target
  else if isKindOf target Number then ( try ( val = raw as float ) catch ( val = 0.0 ) )
  else if classof target == BooleanClass then val = mcpBool params "value" default:false
  else val = (try ( raw as string ) catch (""))
  try ( setProperty m (prop as name) val ) catch ( mcpFail "err.invalid_argument" a1:prop a2:(getCurrentException() as string) )
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "property" prop
  mcpPair p "value" val
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_diffuse params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local rawC = mcpGet params "color"
  if rawC == undefined do mcpFail "err.missing_param" a1:"color"
  local col = mcpColorFrom rawC
  local done = false
  try ( m.diffuse = col; done = true ) catch()
  if not done do ( try ( m.base_color = col; done = true ) catch() )
  if not done do mcpFail "err.invalid_argument" a1:"diffuse" a2:"material has no diffuse/base_color property"
  local p = #()
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_pbr params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  -- Track which properties actually took: a material class that lacks one of
  -- them used to swallow the error and answer "ok" as if everything was set.
  local applied = #()
  local skipped = #()
  if (mcpGet params "baseColor") != undefined do
  (
    local col = mcpColorFrom (mcpGet params "baseColor")
    local ok = false
    try ( m.base_color = col; ok = true ) catch ( try ( m.diffuse = col; ok = true ) catch() )
    if ok then append applied "baseColor" else append skipped "baseColor"
  )
  if (mcpGet params "metallic") != undefined do
  (
    local v = mcpNum params "metallic"
    local ok = false
    try ( m.metallic = v; ok = true ) catch()
    if ok then append applied "metallic" else append skipped "metallic"
  )
  if (mcpGet params "roughness") != undefined do
  (
    local v = mcpNum params "roughness"
    local ok = false
    try ( m.roughness = v; ok = true ) catch()
    if ok then append applied "roughness" else append skipped "roughness"
  )
  if (mcpGet params "ior") != undefined do
  (
    local v = mcpNum params "ior"
    local ok = false
    try ( m.reflection_iOR = v; ok = true ) catch ( try ( m.IOR = v; ok = true ) catch() )
    if ok then append applied "ior" else append skipped "ior"
  )
  if applied.count == 0 do mcpFail "err.invalid_argument" a1:"pbr" a2:"no requested property exists on this material"
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "skipped" skipped
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_specular params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local rawC = mcpGet params "color"
  if rawC == undefined do mcpFail "err.missing_param" a1:"color"
  local col = mcpColorFrom rawC
  local done = false
  try ( m.specular = col; done = true ) catch()
  if not done do ( try ( m.reflection_color = col; done = true ) catch() )
  if not done do mcpFail "err.invalid_argument" a1:"specular" a2:"material has no specular/reflection_color property"
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_opacity params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local o = mcpNum params "opacity" default:-1.0
  if o < 0 do mcpFail "err.missing_param" a1:"opacity"
  try ( m.opacity = o ) catch ( mcpFail "err.invalid_argument" a1:"opacity" a2:(getCurrentException() as string) )
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "opacity" o
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_emission params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local applied = #()
  local skipped = #()
  if (mcpGet params "color") != undefined do
  (
    local col = mcpColorFrom (mcpGet params "color")
    local ok = false
    try ( m.emission_color = col; ok = true ) catch ( try ( m.selfIllumColor = col; ok = true ) catch() )
    if ok then append applied "color" else append skipped "color"
  )
  if (mcpGet params "amount") != undefined do
  (
    local value = mcpNum params "amount"
    local ok = false
    try ( m.emission = value; ok = true ) catch ( try ( m.selfIllumAmount = value; ok = true ) catch() )
    if ok then append applied "amount" else append skipped "amount"
  )
  if applied.count == 0 do mcpFail "err.invalid_argument" a1:"emission" a2:"no requested property exists on this material"
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "skipped" skipped
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_sub_material params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local index = mcpReqInt params "index"
  local subClass = mcpStr params "subClass" default:""
  local source = mcpStr params "sourceMaterial" default:""
  local sub = undefined
  if source != "" do sub = mcpResolveMaterial source
  if sub == undefined and subClass != "" do ( mcpEnsureClass subClass; sub = execute (subClass + "()") )
  if sub == undefined do ( mcpEnsureClass "Standardmaterial"; sub = Standardmaterial() )
  if sub == undefined do mcpFail "err.class_missing" a1:(if subClass != "" then subClass else "Standardmaterial")
  try ( if m.materialList == undefined do m.materialList = #() ) catch()
  local n = 1
  try ( n = m.numsubs ) catch()
  if index < 1 or index > n do mcpFail "err.bad_value" a1:("index=" + (index as string))
  try ( m.materialList[index] = sub ) catch ( mcpFail "err.invalid_argument" a1:"index" a2:(getCurrentException() as string) )
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "index" index
  mcpPair p "subMaterial" (try (sub.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_rename params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local nm = mcpReqStr params "name"
  try ( m.name = nm ) catch ( mcpFail "err.invalid_argument" a1:"name" a2:(getCurrentException() as string) )
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "name" nm
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_delete params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local nm = try (m.name) catch ("")
  try ( for o in objects do ( if o.material == m do o.material = undefined ) ) catch()
  try ( for i = 1 to 24 do ( if meditMaterials[i] == m do meditMaterials[i] = undefined ) ) catch()
  -- Max has no "delete material", only reference counting, so the honest
  -- question is "is it still used anywhere?" - read that back instead of
  -- assuming the two loops above did their job.
  local usedBy = #()
  local inSlots = #()
  try ( for o in objects do ( if o.material == m do append usedBy (try (o.name) catch ("?")) ) ) catch()
  try ( for i = 1 to 24 do ( if meditMaterials[i] == m do append inSlots ("slot " + (i as string)) ) ) catch()
  local p = #()
  mcpPair p "name" nm
  mcpPair p "usedBy" usedBy
  mcpPair p "inSlots" inSlots
  mcpPair p "failures" (usedBy + inSlots)
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_duplicate params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local newName = mcpStr params "name" default:""
  local newMat = undefined
  try ( newMat = copy m ) catch ( try ( newMat = execute ((classof m) as string + "()") ) catch() )
  if newMat == undefined do mcpFail "err.bad_value" a1:"duplicate failed"
  if newName == "" do newName = (try (m.name) catch ("")) + "_copy"
  try ( newMat.name = newName ) catch()
  local p = #()

  -- Every failure path above mcpFails, so reaching here means the change
  -- was applied; state that instead of leaving the caller to guess.
  mcpPair p "success" true
  mcpPair p "original" (try (m.name) catch (""))
  mcpPair p "copy" newName
  mcpPair p "created" newName
  mcpPair p "class" (try ((classof newMat) as string) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_map_slot params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local slot = mcpReqStr params "slot"
  local mapClass = mcpStr params "mapClass" default:"Bitmaptexture"
  local path = mcpStr params "path" default:""
  mcpEnsureClass mapClass
  local theMap = execute (mapClass + "()")
  if theMap == undefined do mcpFail "err.class_missing" a1:mapClass
  if path != "" do ( try ( theMap.filename = path ) catch() )
  local slotWhere = mcpMatSetMap m slot theMap
  if slotWhere == undefined do
    mcpFail "err.invalid_argument" a1:slot a2:("no map slot matches on " + ((classof m) as string))
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "slot" slot
  mcpPair p "property" slotWhere
  mcpPair p "mapClass" (try ((classof theMap) as string) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_get_map_slot params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local slot = mcpReqStr params "slot"
  local theMap = mcpMatGetMap m slot
  local prop = mcpMatMapPropName m slot
  local slotWhere = if prop != undefined then (prop as string)
                else ( local ch = mcpMatMapChannel slot
                       if ch > 0 then ("channel " + (ch as string)) else "" )
  local p = #()
  mcpPair p "slot" slot
  mcpPair p "property" slotWhere
  mcpPair p "mapClass" (try ((classof theMap) as string) catch (""))
  mcpPair p "filename" (try (theMap.filename) catch (""))
  mcpObj p
)


/*------------------------------------------------------------ material creation*/
fn mcpH_mat_create_standard params =
(
  local nm = mcpStr params "name" default:""
  local col = mcpColorFrom (mcpGet params "diffuse") default:undefined
  mcpEnsureClass "Standardmaterial"
  local m = Standardmaterial()
  if nm != "" do m.name = nm
  if col != undefined do ( try ( m.diffuse = col ) catch() )
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_physical params =
(
  local nm = mcpStr params "name" default:""
  mcpEnsureClass "PhysicalMaterial"
  local m = PhysicalMaterial()
  if nm != "" do m.name = nm
  if (mcpGet params "baseColor") != undefined do ( try ( m.base_color = mcpColorFrom (mcpGet params "baseColor") ) catch() )
  if (mcpGet params "metallic") != undefined do ( try ( m.metallic = mcpNum params "metallic" ) catch() )
  if (mcpGet params "roughness") != undefined do ( try ( m.roughness = mcpNum params "roughness" ) catch() )
  mcpAssignCreatedMat m params
)

/* A creatable class can be renamed between releases: Arnold's Standard Surface
   has always been "ai_standard_surface" internally, while the catalog used to
   ask for "aiStandardSurface".  Accept a comma/semicolon separated candidate
   list in className and bind the first one the installation actually has. */
fn mcpResolveMatClass spec =
(
    local names = filterString (spec as string) ",;|"
    for n in names do ( if (mcpClassExists n) do return n )
    undefined
)

fn mcpH_mat_create_guarded params =
(
  local spec = mcpReqStr params "className"
  local className = mcpResolveMatClass spec
  if className == undefined do mcpFail "err.class_missing" a1:spec
  local nm = mcpStr params "name" default:""
  mcpEnsureClass className
  local m = execute (className + "()")
  if m == undefined do mcpFail "err.class_missing" a1:className
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_generic params =
(
  local spec = mcpReqStr params "className"
  local className = mcpResolveMatClass spec
  if className == undefined do mcpFail "err.class_missing" a1:spec
  local nm = mcpStr params "name" default:""
  mcpEnsureClass className
  local m = execute (className + "()")
  if m == undefined do mcpFail "err.class_missing" a1:className
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_multi_sub params =
(
  local count = mcpInt params "count" default:2
  if count < 1 do count = 1
  if count > 100 do count = 100
  local nm = mcpStr params "name" default:""
  mcpEnsureClass "MultiMaterial"
  local m = MultiMaterial()
  try ( m.numsubs = count ) catch ( mcpFail "err.bad_value" a1:"count" )
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_blend params =
(
  local nm = mcpStr params "name" default:""
  mcpEnsureClass "Blend"
  local m = Blend()
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_shellac params =
(
  local nm = mcpStr params "name" default:""
  mcpEnsureClass "Shellac"
  local m = Shellac()
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)


/*------------------------------------------------------------------------ maps*/
fn mcpH_map_create_bitmap params =
(
  local path = mcpStr params "path" default:""
  local rws = mcpBool params "realWorldScale" default:false
  local u = mcpNum params "uTiling" default:1.0
  local v = mcpNum params "vTiling" default:1.0
  mcpEnsureClass "Bitmaptexture"
  local m = Bitmaptexture()
  if path != "" do ( try ( m.filename = path ) catch() )
  try ( m.coordinates.realWorldScale = rws ) catch()
  try ( m.coordinates.u_Tiling = u ) catch()
  try ( m.coordinates.v_Tiling = v ) catch()
  mcpMapInfo m
)

fn mcpH_map_set_bitmap_path params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local slot = mcpReqStr params "slot"
  local path = mcpReqStr params "path"
  local theMap = mcpMatGetMap m slot
  if theMap == undefined do
  (
    mcpEnsureClass "Bitmaptexture"
    theMap = Bitmaptexture()
    try ( setProperty m (slot as name) theMap ) catch ( mcpFail "err.invalid_argument" a1:slot a2:(getCurrentException() as string) )
  )
  try ( theMap.filename = path ) catch ( mcpFail "err.file_missing" a1:path )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "slot" slot
  mcpPair p "path" path
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_map_create_checker params =
(
  local c1 = mcpColorFrom (mcpGet params "color1") default:undefined
  local c2 = mcpColorFrom (mcpGet params "color2") default:undefined
  mcpEnsureClass "Checker"
  local m = Checker()
  if c1 != undefined do ( try ( m.color1 = c1 ) catch() )
  if c2 != undefined do ( try ( m.color2 = c2 ) catch() )
  mcpMapInfo m
)

fn mcpH_map_create_gradient params =
(
  local c1 = mcpColorFrom (mcpGet params "color1") default:undefined
  local c2 = mcpColorFrom (mcpGet params "color2") default:undefined
  local c3 = mcpColorFrom (mcpGet params "color3") default:undefined
  mcpEnsureClass "Gradient"
  local m = Gradient()
  if c1 != undefined do ( try ( m.color1 = c1 ) catch() )
  if c2 != undefined do ( try ( m.color2 = c2 ) catch() )
  if c3 != undefined do ( try ( m.color3 = c3 ) catch() )
  mcpMapInfo m
)

fn mcpH_map_create_gradient_ramp params =
(
  mcpEnsureClass "Gradient_Ramp"
  local m = Gradient_Ramp()
  mcpMapInfo m
)

fn mcpH_map_create_noise params =
(
  local typeN = mcpInt params "noiseType" default:0
  local size = mcpNum params "size" default:1.0
  local seed = mcpInt params "seed" default:12345
  local c1 = mcpColorFrom (mcpGet params "color1") default:undefined
  local c2 = mcpColorFrom (mcpGet params "color2") default:undefined
  mcpEnsureClass "Noise_Map"
  local m = Noise_Map()
  try ( if typeN >= 1 and typeN <= 3 do m.noiseType = typeN ) catch()
  try ( m.size = size ) catch()
  try ( m.seed = seed ) catch()
  if c1 != undefined do ( try ( m.color1 = c1 ) catch() )
  if c2 != undefined do ( try ( m.color2 = c2 ) catch() )
  mcpMapInfo m
)

fn mcpH_map_create_falloff params =
(
  local c1 = mcpColorFrom (mcpGet params "color1") default:undefined
  local c2 = mcpColorFrom (mcpGet params "color2") default:undefined
  mcpEnsureClass "Falloff"
  local m = Falloff()
  if c1 != undefined do ( try ( m.color1 = c1 ) catch() )
  if c2 != undefined do ( try ( m.color2 = c2 ) catch() )
  mcpMapInfo m
)

fn mcpH_map_create_color_correct params =
(
  local bright = mcpNum params "brightness" default:-999.0
  mcpEnsureClass "Color_Correction"
  local m = Color_Correction()
  if bright > -999.0 do ( try ( m.brightness = bright ) catch() )
  mcpMapInfo m
)

fn mcpH_map_create_normal params =
(
  mcpEnsureClass "Normal_Bump"
  local m = Normal_Bump()
  mcpMapInfo m
)


/*-------------------------------------------------------- material libraries*/
fn mcpH_mat_library_save params =
(
  local path = mcpReqStr params "path"
  local names = mcpArr params "materials"
  local mats = #()
  if names.count == 0 do
  (
    try ( for i = 1 to 24 do ( local mm = meditMaterials[i]; if mm != undefined do append mats mm ) ) catch()
  )
  for n in names do ( local mm = mcpResolveMaterial n; if mm != undefined do append mats mm )
  if mats.count == 0 do mcpFail "err.missing_param" a1:"materials"
  local ok = false
  local errTxt = ""
  try ( ok = matLibMgr.saveTempMaterialLibrary path mats ) catch ( errTxt = getCurrentException() as string )
  if not ok do ( try ( ok = saveTempMaterialLibrary path mats ) catch ( errTxt = getCurrentException() as string ) )
  if not ok do mcpFail "err.bad_value" a1:("save library: " + errTxt)
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "path" path
  mcpPair p "count" mats.count
  mcpPair p "message" (mcpMsg "msg.saved" a1:path)
  mcpObj p
)

fn mcpH_mat_library_load params =
(
  local path = mcpReqStr params "path"
  if not (doesFileExist path) do mcpFail "err.file_missing" a1:path
  local mats = #()
  local ok = false
  local errTxt = ""
  try ( mats = matLibMgr.loadTempMaterialLibrary path; ok = true ) catch ( errTxt = getCurrentException() as string )
  if not ok do ( try ( mats = loadTempMaterialLibrary path; ok = true ) catch ( errTxt = getCurrentException() as string ) )
  if not ok do mcpFail "err.bad_value" a1:("load library: " + errTxt)
  local names = #()
  local slotIdx = 1
  for m in mats do
  (
    append names (try (m.name) catch (""))
    try ( if slotIdx <= 24 do ( meditMaterials[slotIdx] = m; slotIdx += 1 ) ) catch()
  )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "path" path
  mcpPair p "count" mats.count
  mcpPair p "materials" names
  mcpPair p "message" (mcpMsg "msg.loaded" a1:path)
  mcpObj p
)


/*------------------------------------------------------------------- registry*/
fn mcpRegisterShading =
(
  mcpRegister "mat_list" mcpH_mat_list undoable:false
  mcpRegister "mat_get" mcpH_mat_get undoable:false
  mcpRegister "mat_get_for_object" mcpH_mat_get_for_object undoable:false
  mcpRegister "mat_slots" mcpH_mat_slots undoable:false
  mcpRegister "mat_set_slot" mcpH_mat_set_slot
  mcpRegister "mat_assign" mcpH_mat_assign
  mcpRegister "mat_set_property" mcpH_mat_set_property
  mcpRegister "mat_set_diffuse" mcpH_mat_set_diffuse
  mcpRegister "mat_set_pbr" mcpH_mat_set_pbr
  mcpRegister "mat_set_specular" mcpH_mat_set_specular
  mcpRegister "mat_set_opacity" mcpH_mat_set_opacity
  mcpRegister "mat_set_emission" mcpH_mat_set_emission
  mcpRegister "mat_set_sub_material" mcpH_mat_set_sub_material
  mcpRegister "mat_rename" mcpH_mat_rename
  mcpRegister "mat_delete" mcpH_mat_delete
  mcpRegister "mat_duplicate" mcpH_mat_duplicate
  mcpRegister "mat_set_map_slot" mcpH_mat_set_map_slot
  mcpRegister "mat_get_map_slot" mcpH_mat_get_map_slot undoable:false
  mcpRegister "mat_create_standard" mcpH_mat_create_standard label:"Create Standard Material"
  mcpRegister "mat_create_physical" mcpH_mat_create_physical label:"Create Physical Material"
  mcpRegister "mat_create_guarded" mcpH_mat_create_guarded label:"Create Renderer Material"
  mcpRegister "mat_create_generic" mcpH_mat_create_generic label:"Create Material By Class"
  mcpRegister "mat_create_multi_sub" mcpH_mat_create_multi_sub label:"Create Multi/Sub-Object Material"
  mcpRegister "mat_create_blend" mcpH_mat_create_blend label:"Create Blend Material"
  mcpRegister "mat_create_shellac" mcpH_mat_create_shellac label:"Create Shellac Material"
  mcpRegister "map_create_bitmap" mcpH_map_create_bitmap label:"Create Bitmap Map"
  mcpRegister "map_set_bitmap_path" mcpH_map_set_bitmap_path label:"Set Bitmap Path"
  mcpRegister "map_create_checker" mcpH_map_create_checker label:"Create Checker Map"
  mcpRegister "map_create_gradient" mcpH_map_create_gradient label:"Create Gradient Map"
  mcpRegister "map_create_gradient_ramp" mcpH_map_create_gradient_ramp label:"Create Gradient Ramp Map"
  mcpRegister "map_create_noise" mcpH_map_create_noise label:"Create Noise Map"
  mcpRegister "map_create_falloff" mcpH_map_create_falloff label:"Create Falloff Map"
  mcpRegister "map_create_color_correct" mcpH_map_create_color_correct label:"Create Color Correction Map"
  mcpRegister "map_create_normal" mcpH_map_create_normal label:"Create Normal Map"
  mcpRegister "mat_library_load" mcpH_mat_library_load label:"Load Material Library"
  mcpRegister "mat_library_save" mcpH_mat_library_save label:"Save Material Library"
  ok
)

mcpRegisterShading()

/* ==========================================================================
   SECTION: mcp_lights.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_lights.ms
   Lights, cameras, environment and UVW mapping.

   Category: shading
-----------------------------------------------------------------------------*/

global mcpResolveLight, mcpRequireLight, mcpResolveCam, mcpRequireCam
global mcpH_light_create, mcpH_light_list, mcpH_light_get, mcpH_light_set
global mcpH_light_delete, mcpH_light_align_to_object, mcpH_light_set_sun
global mcpH_cam_create, mcpH_cam_create_physical, mcpH_cam_get, mcpH_cam_set
global mcpH_cam_look_through, mcpH_cam_align_to_view, mcpH_cam_set_viewport
global mcpH_cam_list, mcpH_cam_delete
global mcpH_env_get, mcpH_env_set_background_color, mcpH_env_set_background_map
global mcpH_env_set_ambient, mcpH_env_set_exposure
global mcpH_uvw_map, mcpH_uvw_unwrap, mcpH_uvw_quick_peel, mcpH_uvw_get_channels


/*------------------------------------------------------------ light / cam helpers*/
fn mcpResolveLight spec =
(
  if spec == undefined do return undefined
  local s = if isKindOf spec String then spec else (try (spec as string) catch (""))
  if s == "" do return undefined
  for l in lights do ( if l.name == s do return l )
  undefined
)

fn mcpRequireLight spec =
(
  local l = mcpResolveLight spec
  if l == undefined do mcpFail "err.node_not_found" a1:(spec as string)
  l
)

fn mcpResolveCam spec =
(
  if spec == undefined do return undefined
  local s = if isKindOf spec String then spec else (try (spec as string) catch (""))
  if s == "" do return undefined
  for c in cameras do ( if c.name == s do return c )
  undefined
)

fn mcpRequireCam spec =
(
  local c = mcpResolveCam spec
  if c == undefined do mcpFail "err.node_not_found" a1:(spec as string)
  c
)


/*-------------------------------------------------------------------------- lights*/
fn mcpH_light_create params =
(
  local typeStr = toLower (mcpStr params "type" default:"omni")
  local nm = mcpStr params "name" default:""
  local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
  local col = mcpColorFrom (mcpGet params "color") default:(color 255 255 255)
  local mult = mcpNum params "intensity" default:-1.0
  local multiplier = mcpNum params "multiplier" default:-1.0
  if multiplier < 0 and mult >= 0 do multiplier = mult
  local castShadows = mcpBool params "castShadows" default:false
  local decay = toLower (mcpStr params "decay" default:"none")
  local coneAngle = mcpNum params "coneAngle" default:-1.0
  local penumbra = mcpNum params "penumbra" default:-1.0
  local azimuth = mcpNum params "azimuth" default:-999.0
  local altitude = mcpNum params "altitude" default:-999.0

  local l = undefined
  case typeStr of
  (
    "omni": ( mcpEnsureClass "Omnilight"; l = Omnilight() )
    "free_spot": ( mcpEnsureClass "Spotlight"; l = Spotlight() )
    "spot": ( mcpEnsureClass "Targetspot"; l = Targetspot() )
    "free_directional": ( mcpEnsureClass "Directionallight"; l = Directionallight() )
    "directional": ( mcpEnsureClass "Targetdirectionallight"; l = Targetdirectionallight() )
    "target_directional": ( mcpEnsureClass "Targetdirectionallight"; l = Targetdirectionallight() )
    "mr_area_omni": ( mcpEnsureClass "mr_Area_Omni"; l = mr_Area_Omni() )
    "mr_area_spot": ( mcpEnsureClass "mr_Area_Spot"; l = mr_Area_Spot() )
    "fstorm": ( mcpEnsureClass "FStormLight"; l = FStormLight() )
    "vray": ( mcpEnsureClass "VRayLight"; l = VRayLight() )
    "corona": ( mcpEnsureClass "CoronaLight"; l = CoronaLight() )
    -- mental ray was removed in 3ds Max 2018, so mr_Area_* no longer exists on
    -- any release this bridge supports.  Photometric Free_Light / Target_Light
    -- are the built-in area lights from 2018 on; the mr_* branch is kept only
    -- so an ancient installation still resolves.
    "area": (
        if (mcpClassExists "Free_Light") then ( l = Free_Light() )
        else ( mcpEnsureClass "mr_Area_Omni"; l = mr_Area_Omni() )
    )
    -- Sunlight and Daylight are both *System* objects: MAXScript refuses to
    -- create them ("Cannot create System objects").  SunPositioner is the
    -- creatable physical sun on 2022+; fall back to a directional light.
    "sun": (
        if (mcpClassExists "SunPositioner") then ( l = SunPositioner() )
        else if (mcpClassExists "Sunlight") then ( l = Sunlight() )
        else ( mcpEnsureClass "Directionallight"; l = Directionallight() )
    )
    default: ( mcpFail "err.bad_value" a1:("type=" + typeStr) )
  )
  if l == undefined do mcpFail "err.bad_value" a1:("type=" + typeStr)

  try ( l.position = pos ) catch()
  try ( if l.target != undefined do l.target.position = (pos + [0,0,-50]) ) catch()
  try ( l.color = col ) catch()
  try ( l.castShadows = castShadows ) catch()
  local dt = 0
  if decay == "inverse" do dt = 1
  if decay == "inverse_square" or decay == "inversesquare" do dt = 2
  try ( l.decayType = dt ) catch()
  if multiplier >= 0 do ( try ( l.multiplier = multiplier ) catch ( try ( l.intensity = multiplier ) catch() ) )
  if coneAngle >= 0 do ( try ( l.hotspot = coneAngle ) catch() )
  if penumbra >= 0 do
  (
    -- penumbra is the angle *beyond* the hotspot: the base is the cone angle
    -- when one was supplied, otherwise the hotspot the light already has.
    -- Adding the raw -1.0 "not supplied" sentinel used to yield
    -- falloff = penumbra - 1, which can end up below the hotspot.
    local base = coneAngle
    if base < 0 do ( try ( base = l.hotspot ) catch ( base = 0.0 ) )
    try ( l.falloff = (base + penumbra) ) catch ( try ( l.spread = penumbra ) catch() )
  )
  if typeStr == "sun" do
  (
    if azimuth > -999.0 do ( try ( l.azimuth = azimuth ) catch ( try ( l.sun.azimuth = azimuth ) catch() ) )
    if altitude > -999.0 do ( try ( l.altitude = altitude ) catch ( try ( l.sun.altitude = altitude ) catch() ) )
  )
  if nm != "" do ( try ( l.name = nm ) catch() )

  local p = #()
  -- An unknown type or missing class already failed above, so a reply here means
  -- the light object exists.  Without this flag reliability mode reported a
  -- successfully created light as missing_success.
  mcpPair p "success" true
  mcpPair p "class" (try ((classof l) as string) catch (""))
  mcpPair p "name" (try (l.name) catch (""))
  mcpPair p "type" typeStr
  mcpPair p "message" (mcpMsg "msg.created" a1:(try (l.name) catch ("")))
  mcpObj p
)

fn mcpH_light_list params =
(
  local limit = mcpInt params "limit" default:200
  local offset = mcpInt params "offset" default:0
  local all = #()
  for l in lights do
  (
    local it = #()
    mcpPair it "name" (try (l.name) catch (""))
    mcpPair it "class" (try ((classof l) as string) catch (""))
    mcpPair it "position" (try (l.position) catch ([0,0,0]))
    append all (mcpObj it)
  )
  local pg = mcpShadePage all limit offset
  local p = #()
  mcpPair p "count" pg[2]
  mcpPair p "offset" offset
  mcpPair p "limit" limit
  mcpPair p "lights" pg[1]
  mcpObj p
)

fn mcpH_light_get params =
(
  local l = mcpRequireLight (mcpStr params "light" default:"")
  local p = #()
  mcpPair p "name" (try (l.name) catch (""))
  mcpPair p "class" (try ((classof l) as string) catch (""))
  mcpPair p "position" (try (l.position) catch ([0,0,0]))
  local intensityVal = 0.0
  try ( intensityVal = l.multiplier ) catch ( try ( intensityVal = l.intensity ) catch ( intensityVal = 0.0 ) )
  mcpPair p "multiplier" intensityVal
  mcpPair p "color" (try (l.color) catch ((color 255 255 255)))
  mcpPair p "castShadows" (try (l.castShadows) catch (false))
  mcpPair p "enabled" (try (l.enabled) catch (true))
  mcpObj p
)

fn mcpH_light_set params =
(
  local l = mcpRequireLight (mcpStr params "light" default:"")
  -- Light classes disagree about property names (multiplier vs intensity,
  -- falloff vs spread), so each assignment is its own try.  The bug was that
  -- every miss was swallowed and the reply still said "ok" - now the misses are
  -- named, and a call where nothing landed fails outright.
  local applied = #()
  local skipped = #()
  if (mcpGet params "name") != undefined do
  (
    local value = mcpStr params "name"
    local ok = false
    try ( l.name = value; ok = true ) catch()
    if ok then append applied "name" else append skipped "name"
  )
  if (mcpGet params "color") != undefined do
  (
    local value = mcpColorFrom (mcpGet params "color")
    local ok = false
    try ( l.color = value; ok = true ) catch()
    if ok then append applied "color" else append skipped "color"
  )
  if (mcpGet params "multiplier") != undefined do
  (
    local value = mcpNum params "multiplier"
    local ok = false
    try ( l.multiplier = value; ok = true ) catch ( try ( l.intensity = value; ok = true ) catch() )
    if ok then append applied "multiplier" else append skipped "multiplier"
  )
  if (mcpGet params "intensity") != undefined do
  (
    local value = mcpNum params "intensity"
    local ok = false
    try ( l.intensity = value; ok = true ) catch ( try ( l.multiplier = value; ok = true ) catch() )
    if ok then append applied "intensity" else append skipped "intensity"
  )
  if (mcpGet params "castShadows") != undefined do
  (
    local value = mcpBool params "castShadows"
    local ok = false
    try ( l.castShadows = value; ok = true ) catch()
    if ok then append applied "castShadows" else append skipped "castShadows"
  )
  if (mcpGet params "enabled") != undefined do
  (
    local value = mcpBool params "enabled"
    local ok = false
    try ( l.enabled = value; ok = true ) catch()
    if ok then append applied "enabled" else append skipped "enabled"
  )
  if (mcpGet params "coneAngle") != undefined do
  (
    local value = mcpNum params "coneAngle"
    local ok = false
    try ( l.hotspot = value; ok = true ) catch()
    if ok then append applied "coneAngle" else append skipped "coneAngle"
  )
  if (mcpGet params "penumbra") != undefined do
  (
    -- Same rule as light_create: penumbra sits on top of the hotspot, so the
    -- base is the supplied cone angle or the hotspot already on the light
    -- (the old 0.0 default ignored the current hotspot entirely).
    local base = 0.0
    if (mcpGet params "coneAngle") != undefined then
      ( base = (mcpNum params "coneAngle") )
    else
      ( try ( base = l.hotspot ) catch ( base = 0.0 ) )
    local value = (mcpNum params "penumbra")
    local ok = false
    try ( l.falloff = (base + value); ok = true ) catch ( try ( l.spread = value; ok = true ) catch() )
    if ok then append applied "penumbra" else append skipped "penumbra"
  )
  if (mcpGet params "decay") != undefined do
  (
    local d = toLower (mcpStr params "decay" default:"none")
    local dt = 0
    if d == "inverse" do dt = 1
    if d == "inverse_square" or d == "inversesquare" do dt = 2
    local ok = false
    try ( l.decayType = dt; ok = true ) catch()
    if ok then append applied "decay" else append skipped "decay"
  )
  if (mcpGet params "position") != undefined do
  (
    local value = mcpPoint3From (mcpGet params "position")
    local ok = false
    try ( l.position = value; ok = true ) catch()
    if ok then append applied "position" else append skipped "position"
  )
  -- Nothing was requested at all is not a failure; something was requested and
  -- nothing landed is.
  if applied.count == 0 and skipped.count > 0 do
    mcpFail "err.invalid_argument" a1:"light" a2:"no requested property exists on this light"
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "skipped" skipped
  mcpPair p "name" (try (l.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_light_delete params =
(
  local l = mcpRequireLight (mcpStr params "light" default:"")
  local nm = try (l.name) catch ("")
  try ( delete l ) catch ( mcpFail "err.invalid_argument" a1:"delete" a2:(getCurrentException() as string) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" nm
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_light_align_to_object params =
(
  local l = mcpRequireLight (mcpStr params "light" default:"")
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:false silent:true
  if nodes.count == 0 do mcpFail "err.missing_param" a1:"objects"
  local tgt = nodes[1]
  local tp = [0,0,0]
  try ( tp = tgt.position ) catch()
  try ( l.position = (tp + [0,0,50]) ) catch()
  try ( if l.target != undefined do l.target.position = tp ) catch()
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "light" (try (l.name) catch (""))
  mcpPair p "target" (try (tgt.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_light_set_sun params =
(
  local azimuth = mcpNum params "azimuth" default:-999.0
  local altitude = mcpNum params "altitude" default:-999.0
  local sys = undefined
  try
  (
    for o in objects do
    (
      local c = (classof o) as string
      if c == "Daylight" or c == "Sunlight" or c == "IES_Sun" do ( sys = o; exit )
    )
  )
  catch()
  if sys == undefined do mcpFail "err.class_missing" a1:"Daylight/Sun system"
  if azimuth > -999.0 do ( try ( sys.azimuth = azimuth ) catch ( try ( sys.sun.azimuth = azimuth ) catch() ) )
  if altitude > -999.0 do ( try ( sys.altitude = altitude ) catch ( try ( sys.sun.altitude = altitude ) catch() ) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" (try (sys.name) catch (""))
  mcpPair p "azimuth" azimuth
  mcpPair p "altitude" altitude
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)


/*------------------------------------------------------------------------ cameras*/
fn mcpH_cam_create params =
(
  local typeStr = toLower (mcpStr params "type" default:"free")
  local nm = mcpStr params "name" default:""
  local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
  local target = mcpPoint3From (mcpGet params "target") default:[0,0,-100]
  local fov = mcpNum params "fov" default:-1.0
  local c = undefined
  case typeStr of
  (
    "free": ( c = FreeCamera() )
    "target": ( c = Targetcamera() )
    default: ( mcpFail "err.bad_value" a1:("type=" + typeStr) )
  )
  try ( c.position = pos ) catch()
  try ( if isKindOf c Targetcamera do c.target.position = target ) catch()
  if fov > 0 do ( try ( c.fov = fov ) catch() )
  if nm != "" do ( try ( c.name = nm ) catch() )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "class" (try ((classof c) as string) catch (""))
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "type" typeStr
  mcpPair p "message" (mcpMsg "msg.created" a1:(try (c.name) catch ("")))
  mcpObj p
)

fn mcpH_cam_create_physical params =
(
  local nm = mcpStr params "name" default:""
  local pos = mcpPoint3From (mcpGet params "position") default:[0,0,0]
  local target = mcpPoint3From (mcpGet params "target") default:[0,0,-100]
  local focal = mcpNum params "focalLength" default:-1.0
  local fstop = mcpNum params "fStop" default:-1.0
  local shutter = mcpNum params "shutterSpeed" default:-1.0
  local iso = mcpNum params "iso" default:-1.0
  local dof = mcpBool params "depthOfField" default:false
  local fov = mcpNum params "fov" default:-1.0
  mcpEnsureClass "Physical_Camera"
  local c = Physical_Camera()
  try ( c.position = pos ) catch()
  try ( if isKindOf c Targetcamera do c.target.position = target ) catch()
  if focal > 0 do ( try ( c.focal_length = focal ) catch() )
  if fstop > 0 do ( try ( c.f_stop = fstop ) catch ( try ( c.aperture = fstop ) catch() ) )
  if shutter > 0 do ( try ( c.shutter_speed = shutter ) catch() )
  if iso > 0 do ( try ( c.iso = iso ) catch() )
  try ( c.depth_of_field = dof ) catch()
  if fov > 0 do ( try ( c.fov = fov ) catch() )
  if nm != "" do ( try ( c.name = nm ) catch() )
  local p = #()

  -- Reaching here means a failure here throws instead of being ignored.
  mcpPair p "success" true
  mcpPair p "class" (try ((classof c) as string) catch (""))
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.created" a1:(try (c.name) catch ("")))
  mcpObj p
)

fn mcpH_cam_get params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  local p = #()
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "class" (try ((classof c) as string) catch (""))
  mcpPair p "position" (try (c.position) catch ([0,0,0]))
  mcpPair p "fov" (try (c.fov) catch (0.0))
  -- focal_length only exists on Physical cameras.  Returning the catch
  -- default 0.0 pretended the read had succeeded for every other camera
  -- class; now the flag says so, the value serialises as null, and a note
  -- explains why.
  local focal = undefined
  local focalOk = false
  try ( focal = c.focal_length; focalOk = true ) catch ( focalOk = false )
  mcpPair p "focalLengthSupported" focalOk
  mcpPair p "focalLength" (if focalOk then focal else undefined)
  if not focalOk do mcpPair p "note" (mcpMsg "msg.focal_physical_only")
  mcpPair p "isActive" (try (viewport.getCamera() == c) catch (false))
  mcpObj p
)

fn mcpH_cam_set params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  -- Same rule as light_set: a physical camera has f_stop, a free camera has no
  -- target, and the misses used to vanish into "ok".
  local applied = #()
  local skipped = #()
  if (mcpGet params "name") != undefined do
  (
    local ok = false
    try ( c.name = mcpStr params "name"; ok = true ) catch()
    if ok then append applied "name" else append skipped "name"
  )
  if (mcpGet params "position") != undefined do
  (
    local ok = false
    try ( c.position = mcpPoint3From (mcpGet params "position"); ok = true ) catch()
    if ok then append applied "position" else append skipped "position"
  )
  if (mcpGet params "target") != undefined do
  (
    local ok = false
    try ( if isKindOf c Targetcamera do ( c.target.position = mcpPoint3From (mcpGet params "target") ); ok = true ) catch()
    if ok then append applied "target" else append skipped "target"
  )
  if (mcpGet params "fov") != undefined do
  (
    local ok = false
    try ( c.fov = mcpNum params "fov"; ok = true ) catch()
    if ok then append applied "fov" else append skipped "fov"
  )
  if (mcpGet params "focalLength") != undefined do
  (
    local ok = false
    try ( c.focal_length = mcpNum params "focalLength"; ok = true ) catch()
    if ok then append applied "focalLength" else append skipped "focalLength"
  )
  if (mcpGet params "fStop") != undefined do
  (
    local value = mcpNum params "fStop"
    local ok = false
    try ( c.f_stop = value; ok = true ) catch ( try ( c.aperture = value; ok = true ) catch() )
    if ok then append applied "fStop" else append skipped "fStop"
  )
  if (mcpGet params "shutterSpeed") != undefined do
  (
    local ok = false
    try ( c.shutter_speed = mcpNum params "shutterSpeed"; ok = true ) catch()
    if ok then append applied "shutterSpeed" else append skipped "shutterSpeed"
  )
  if (mcpGet params "iso") != undefined do
  (
    local ok = false
    try ( c.iso = mcpNum params "iso"; ok = true ) catch()
    if ok then append applied "iso" else append skipped "iso"
  )
  if (mcpGet params "depthOfField") != undefined do
  (
    local ok = false
    try ( c.depth_of_field = mcpBool params "depthOfField"; ok = true ) catch()
    if ok then append applied "depthOfField" else append skipped "depthOfField"
  )
  if applied.count == 0 and skipped.count > 0 do
    mcpFail "err.invalid_argument" a1:"camera" a2:"no requested property exists on this camera"
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "skipped" skipped
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_cam_look_through params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  try ( viewport.setCamera c ) catch ( mcpFail "err.invalid_argument" a1:"look_through" a2:(getCurrentException() as string) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_cam_align_to_view params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  local tm = undefined
  try ( tm = viewport.getTM() ) catch ( tm = undefined )
  if tm == undefined do mcpFail "err.invalid_argument" a1:"align_to_view" a2:"no active viewport transform"
  try ( c.position = tm.pos ) catch()
  try ( if isKindOf c Targetcamera do c.target.position = (tm.pos - (tm.row3 * 100.0)) ) catch()
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_cam_set_viewport params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  local vp = mcpInt params "viewport" default:0
  if vp > 0 do ( try ( setActiveViewport vp ) catch() )
  try ( viewport.setCamera c ) catch ( mcpFail "err.invalid_argument" a1:"set_viewport" a2:(getCurrentException() as string) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_cam_list params =
(
  local limit = mcpInt params "limit" default:200
  local offset = mcpInt params "offset" default:0
  local all = #()
  for c in cameras do
  (
    local it = #()
    mcpPair it "name" (try (c.name) catch (""))
    mcpPair it "class" (try ((classof c) as string) catch (""))
    mcpPair it "position" (try (c.position) catch ([0,0,0]))
    append all (mcpObj it)
  )
  local pg = mcpShadePage all limit offset
  local p = #()
  mcpPair p "count" pg[2]
  mcpPair p "offset" offset
  mcpPair p "limit" limit
  mcpPair p "cameras" pg[1]
  mcpObj p
)

fn mcpH_cam_delete params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  local nm = try (c.name) catch ("")
  try ( delete c ) catch ( mcpFail "err.invalid_argument" a1:"delete" a2:(getCurrentException() as string) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "name" nm
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)


/*------------------------------------------------------------------- environment*/
fn mcpH_env_get params =
(
  local p = #()
  mcpPair p "backgroundColor" (try ( backgroundColor ) catch (undefined))
  mcpPair p "ambientColor" (try ( ambientColor ) catch (undefined))
  mcpPair p "backgroundMap" (try ( if environmentMap != undefined then (classof environmentMap) as string else "" ) catch (""))
  mcpPair p "exposureControl" (try ( (classof exposureControl) as string ) catch (""))
  mcpObj p
)

fn mcpH_env_set_background_color params =
(
  local rawC = mcpGet params "color"
  if rawC == undefined do mcpFail "err.missing_param" a1:"color"
  backgroundColor = mcpColorFrom rawC
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_env_set_background_map params =
(
  local path = mcpStr params "path" default:""
  mcpEnsureClass "Bitmaptexture"
  local m = Bitmaptexture()
  if path != "" do ( try ( m.filename = path ) catch() )
  environmentMap = m
  local p = #()

  -- Reaching here means the assignment above throws instead of ignoring errors.
  mcpPair p "success" true
  mcpPair p "path" path
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_env_set_ambient params =
(
  local rawC = mcpGet params "color"
  if rawC == undefined do mcpFail "err.missing_param" a1:"color"
  ambientColor = mcpColorFrom rawC
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_env_set_exposure params =
(
  local typeStr = toLower (mcpStr params "type" default:"physical")
  local ev = mcpNum params "exposureValue" default:-999.0
  local ctrl = undefined
  case typeStr of
  (
    "physical": ( mcpEnsureClass "Physical_Exposure_Control"; ctrl = Physical_Exposure_Control() )
    "logarithmic": ( mcpEnsureClass "Logarithmic_Exposure_Control"; ctrl = Logarithmic_Exposure_Control() )
    "automatic": ( mcpEnsureClass "Automatic_Exposure_Control"; ctrl = Automatic_Exposure_Control() )
    "linear": ( mcpEnsureClass "Linear_Exposure_Control"; ctrl = Linear_Exposure_Control() )
    "none": ( ctrl = undefined )
    default: ( mcpFail "err.bad_value" a1:("type=" + typeStr) )
  )
  if typeStr != "none" and ctrl == undefined do mcpFail "err.class_missing" a1:typeStr
  if typeStr != "none" do ( try ( exposureControl = ctrl ) catch ( mcpFail "err.invalid_argument" a1:"exposureControl" a2:(getCurrentException() as string) ) )
  if ev > -999.0 and ctrl != undefined do ( try ( ctrl.exposureValue = ev ) catch ( try ( ctrl.brightness = ev ) catch() ) )
  local p = #()

  -- Reaching here means every failure path above mcpFails.
  mcpPair p "success" true
  mcpPair p "type" typeStr
  mcpPair p "exposureValue" ev
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)


/*--------------------------------------------------------------------------- uvw*/
fn mcpH_uvw_map params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local mapping = toLower (mcpStr params "mapping" default:"planar")
  local mt = 1
  case mapping of
  (
    "planar": mt = 1
    "cylindrical": mt = 2
    "spherical": mt = 3
    "shrink_wrap": mt = 4
    "box": mt = 5
    "face": mt = 6
    "xyz": mt = 7
    default: mt = 1
  )
  local u = mcpNum params "uTiling" default:1.0
  local v = mcpNum params "vTiling" default:1.0
  local w = mcpNum params "wTiling" default:1.0
  local sx = mcpNum params "sizeX" default:-1.0
  local sy = mcpNum params "sizeY" default:-1.0
  local sz = mcpNum params "sizeZ" default:-1.0
  local applied = #()
  local failures = #()
  for n in nodes do
  (
    try
    (
      mcpEnsureClass "Uvwmap"
      local mod = Uvwmap()
      -- verified live on 2020: the type property is "maptype" and the tiling
      -- properties are "utile"/"vtile"/"wtile" (mapping / u_Tiling / v_Tiling
      -- / w_Tiling do not exist and used to fail silently under catch())
      mod.maptype = mt
      mod.utile = u
      mod.vtile = v
      mod.wtile = w
      if sx > 0 do mod.length = sx
      if sy > 0 do mod.width = sy
      if sz > 0 do mod.height = sz
      local before = n.modifiers.count
      addModifier n mod
      if (n.modifiers.count <= before) do mcpFail "err.bad_value" a1:"modifier did not enter the stack"
      append applied n.name
    )
    catch ( append failures (n.name + ": " + (getCurrentException())) )
  )
  local p = #()
  mcpPair p "mapping" mapping
  mcpPair p "applied" applied
  mcpPair p "failures" failures
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_uvw_unwrap params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local applied = #()
  local failures = #()
  for n in nodes do
  (
    local ok = true
    try
    (
      mcpEnsureClass "Unwrap_UVW"
      local before = n.modifiers.count
      addModifier n (Unwrap_UVW())
      if (n.modifiers.count <= before) do mcpFail "err.bad_value" a1:"modifier did not enter the stack"
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

fn mcpH_uvw_quick_peel params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local applied = #()
  local failures = #()
  for n in nodes do
  (
    try
    (
      mcpEnsureClass "Unwrap_UVW"
      local mod = Unwrap_UVW()
      local before = n.modifiers.count
      addModifier n mod
      if (n.modifiers.count <= before) do mcpFail "err.bad_value" a1:"modifier did not enter the stack"
      try ( mod.quickPeel() ) catch()
      append applied n.name
    )
    catch ( append failures (n.name + ": " + (getCurrentException() as string)) )
  )
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "failures" failures
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_uvw_get_channels params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local out = #()
  for n in nodes do
  (
    local it = #()
    mcpPair it "object" (try (n.name) catch (""))
    local chans = #()
    try
    (
      local mesh = n.mesh
      local num = getNumMaps mesh
      for i = 1 to num do ( if (meshop.getMapSupport mesh i) do append chans i )
    )
    catch()
    mcpPair it "channels" chans
    append out (mcpObj it)
  )
  local p = #()
  mcpPair p "count" out.count
  mcpPair p "objects" out
  mcpObj p
)


/*------------------------------------------------------------------- registry*/
fn mcpRegisterLights =
(
  mcpRegister "light_create" mcpH_light_create label:"Create Light"
  mcpRegister "light_list" mcpH_light_list undoable:false
  mcpRegister "light_get" mcpH_light_get undoable:false
  mcpRegister "light_set" mcpH_light_set label:"Set Light"
  mcpRegister "light_delete" mcpH_light_delete label:"Delete Light"
  mcpRegister "light_align_to_object" mcpH_light_align_to_object label:"Align Light To Object"
  mcpRegister "light_set_sun" mcpH_light_set_sun label:"Set Sun Position"
  mcpRegister "cam_create" mcpH_cam_create label:"Create Camera"
  mcpRegister "cam_create_physical" mcpH_cam_create_physical label:"Create Physical Camera"
  mcpRegister "cam_get" mcpH_cam_get undoable:false
  mcpRegister "cam_set" mcpH_cam_set label:"Set Camera"
  mcpRegister "cam_look_through" mcpH_cam_look_through label:"Look Through Camera"
  mcpRegister "cam_align_to_view" mcpH_cam_align_to_view label:"Align Camera To View"
  mcpRegister "cam_set_viewport" mcpH_cam_set_viewport label:"Set Camera Viewport"
  mcpRegister "cam_list" mcpH_cam_list undoable:false
  mcpRegister "cam_delete" mcpH_cam_delete label:"Delete Camera"
  mcpRegister "env_get" mcpH_env_get undoable:false
  mcpRegister "env_set_background_color" mcpH_env_set_background_color label:"Set Background Color"
  mcpRegister "env_set_background_map" mcpH_env_set_background_map label:"Set Background Map"
  mcpRegister "env_set_ambient" mcpH_env_set_ambient label:"Set Ambient Color"
  mcpRegister "env_set_exposure" mcpH_env_set_exposure label:"Set Exposure Control"
  mcpRegister "uvw_map" mcpH_uvw_map label:"Add UVW Map"
  mcpRegister "uvw_unwrap" mcpH_uvw_unwrap label:"Add Unwrap UVW"
  mcpRegister "uvw_quick_peel" mcpH_uvw_quick_peel label:"Quick Peel UVW"
  mcpRegister "uvw_get_channels" mcpH_uvw_get_channels undoable:false
  ok
)

mcpRegisterLights()
