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

fn mcpMatGetMap m slot =
(
  local theMap = undefined
  try ( theMap = getProperty m (slot as name) ) catch ( theMap = undefined )
  if not (isKindOf theMap TextureMap) do theMap = undefined
  theMap
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
  local p = #()
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
    try ( if n.material != undefined then mcpPair it "material" (mcpMatDetails n.material) else mcpPair it "material" undefined ) catch()
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
  for n in nodes do ( try ( n.material = m; append applied n.name ) catch() )
  local p = #()
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "applied" applied
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
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_pbr params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  if (mcpGet params "baseColor") != undefined do
  (
    local col = mcpColorFrom (mcpGet params "baseColor")
    try ( m.base_color = col ) catch ( try ( m.diffuse = col ) catch() )
  )
  if (mcpGet params "metallic") != undefined do ( try ( m.metallic = mcpNum params "metallic" ) catch() )
  if (mcpGet params "roughness") != undefined do ( try ( m.roughness = mcpNum params "roughness" ) catch() )
  if (mcpGet params "ior") != undefined do
  (
    try ( m.reflection_iOR = mcpNum params "ior" ) catch ( try ( m.IOR = mcpNum params "ior" ) catch() )
  )
  local p = #()
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
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "opacity" o
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_set_emission params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  if (mcpGet params "color") != undefined do
  (
    local col = mcpColorFrom (mcpGet params "color")
    try ( m.emission_color = col ) catch ( try ( m.selfIllumColor = col ) catch() )
  )
  if (mcpGet params "amount") != undefined do
  (
    try ( m.emission = mcpNum params "amount" ) catch ( try ( m.selfIllumAmount = mcpNum params "amount" ) catch() )
  )
  local p = #()
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
  local p = #()
  mcpPair p "name" nm
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
  mcpPair p "original" (try (m.name) catch (""))
  mcpPair p "copy" newName
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
  try ( setProperty m (slot as name) theMap ) catch ( mcpFail "err.invalid_argument" a1:slot a2:(getCurrentException() as string) )
  local p = #()
  mcpPair p "material" (try (m.name) catch (""))
  mcpPair p "slot" slot
  mcpPair p "mapClass" (try ((classof theMap) as string) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_mat_get_map_slot params =
(
  local m = mcpRequireMat (mcpStr params "material" default:"")
  local slot = mcpReqStr params "slot"
  local theMap = mcpMatGetMap m slot
  local p = #()
  mcpPair p "slot" slot
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

fn mcpH_mat_create_guarded params =
(
  local className = mcpReqStr params "className"
  local nm = mcpStr params "name" default:""
  mcpEnsureClass className
  local m = execute (className + "()")
  if m == undefined do mcpFail "err.class_missing" a1:className
  if nm != "" do m.name = nm
  mcpAssignCreatedMat m params
)

fn mcpH_mat_create_generic params =
(
  local className = mcpReqStr params "className"
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
