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
    "area": ( mcpEnsureClass "mr_Area_Omni"; l = mr_Area_Omni() )
    "sun": ( mcpEnsureClass "Daylight"; l = Daylight() )
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
  if (mcpGet params "name") != undefined do ( try ( l.name = mcpStr params "name" ) catch() )
  if (mcpGet params "color") != undefined do ( try ( l.color = mcpColorFrom (mcpGet params "color") ) catch() )
  if (mcpGet params "multiplier") != undefined do ( try ( l.multiplier = mcpNum params "multiplier" ) catch ( try ( l.intensity = mcpNum params "multiplier" ) catch() ) )
  if (mcpGet params "intensity") != undefined do ( try ( l.intensity = mcpNum params "intensity" ) catch ( try ( l.multiplier = mcpNum params "intensity" ) catch() ) )
  if (mcpGet params "castShadows") != undefined do ( try ( l.castShadows = mcpBool params "castShadows" ) catch() )
  if (mcpGet params "enabled") != undefined do ( try ( l.enabled = mcpBool params "enabled" ) catch() )
  if (mcpGet params "coneAngle") != undefined do ( try ( l.hotspot = mcpNum params "coneAngle" ) catch() )
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
    try ( l.falloff = (base + (mcpNum params "penumbra")) ) catch ( try ( l.spread = (mcpNum params "penumbra") ) catch() )
  )
  if (mcpGet params "decay") != undefined do
  (
    local d = toLower (mcpStr params "decay" default:"none")
    local dt = 0
    if d == "inverse" do dt = 1
    if d == "inverse_square" or d == "inversesquare" do dt = 2
    try ( l.decayType = dt ) catch()
  )
  if (mcpGet params "position") != undefined do ( try ( l.position = mcpPoint3From (mcpGet params "position") ) catch() )
  local p = #()
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
  if (mcpGet params "name") != undefined do ( try ( c.name = mcpStr params "name" ) catch() )
  if (mcpGet params "position") != undefined do ( try ( c.position = mcpPoint3From (mcpGet params "position") ) catch() )
  if (mcpGet params "target") != undefined do ( try ( if isKindOf c Targetcamera do c.target.position = mcpPoint3From (mcpGet params "target") ) catch() )
  if (mcpGet params "fov") != undefined do ( try ( c.fov = mcpNum params "fov" ) catch() )
  if (mcpGet params "focalLength") != undefined do ( try ( c.focal_length = mcpNum params "focalLength" ) catch() )
  if (mcpGet params "fStop") != undefined do ( try ( c.f_stop = mcpNum params "fStop" ) catch ( try ( c.aperture = mcpNum params "fStop" ) catch() ) )
  if (mcpGet params "shutterSpeed") != undefined do ( try ( c.shutter_speed = mcpNum params "shutterSpeed" ) catch() )
  if (mcpGet params "iso") != undefined do ( try ( c.iso = mcpNum params "iso" ) catch() )
  if (mcpGet params "depthOfField") != undefined do ( try ( c.depth_of_field = mcpBool params "depthOfField" ) catch() )
  local p = #()
  mcpPair p "name" (try (c.name) catch (""))
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_cam_look_through params =
(
  local c = mcpRequireCam (mcpStr params "camera" default:"")
  try ( viewport.setCamera c ) catch ( mcpFail "err.invalid_argument" a1:"look_through" a2:(getCurrentException() as string) )
  local p = #()
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
  for n in nodes do
  (
    try
    (
      mcpEnsureClass "Uvwmap"
      local mod = Uvwmap()
      mod.mapping = mt
      mod.u_Tiling = u
      mod.v_Tiling = v
      mod.w_Tiling = w
      if sx > 0 do mod.length = sx
      if sy > 0 do mod.width = sy
      if sz > 0 do mod.height = sz
      addModifier n mod
      append applied n.name
    )
    catch()
  )
  local p = #()
  mcpPair p "mapping" mapping
  mcpPair p "applied" applied
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_uvw_unwrap params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local applied = #()
  for n in nodes do
  (
    try ( mcpEnsureClass "Unwrap_UVW"; addModifier n (Unwrap_UVW()); append applied n.name ) catch()
  )
  local p = #()
  mcpPair p "applied" applied
  mcpPair p "message" (mcpMsg "msg.ok")
  mcpObj p
)

fn mcpH_uvw_quick_peel params =
(
  local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
  local applied = #()
  for n in nodes do
  (
    try
    (
      mcpEnsureClass "Unwrap_UVW"
      local mod = Unwrap_UVW()
      addModifier n mod
      try ( mod.quickPeel() ) catch()
      append applied n.name
    )
    catch()
  )
  local p = #()
  mcpPair p "applied" applied
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
