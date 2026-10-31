/* Camera + sun aiming.
   The catalog cam_create / light_create handlers set position before the target
   node exists, so `c.target` is undefined at that moment and the node keeps its
   default orientation (camera looks straight down). Rebuild the transform
   explicitly with matrix3 so the aim is deterministic. */
(
    local out = ""

    -- ---------------------------------------------------------------- camera
    local camPos = [-70.0, -560.0, 175.0]
    local camTgt = [10.0, 80.0, 35.0]
    local old = getNodeByName "CAM_Main"
    if old != undefined do delete old
    local c = Freecamera pos:camPos fov:48.0
    c.name = "CAM_Main"
    local dv = normalize (camTgt - camPos)
    local zA = -dv
    local xA = normalize (cross [0.0, 0.0, 1.0] zA)
    local yA = normalize (cross zA xA)
    c.transform = matrix3 xA yA zA camPos
    out += "camera dir=" + (c.dir as string) + "\n"

    -- ------------------------------------------------------------------ sun
    local oldS = getNodeByName "SUN"
    if oldS != undefined do delete oldS
    local sunPos = [300.0, -500.0, 650.0]
    local sunTgt = [0.0, 150.0, 0.0]
    local s = Directionallight pos:sunPos
    s.name = "SUN"
    s.color = color 255 244 224
    s.multiplier = 1.0
    s.castShadows = true
    local sv = normalize (sunTgt - sunPos)
    local szA = -sv
    local sxA = normalize (cross [0.0, 0.0, 1.0] szA)
    local syA = normalize (cross szA sxA)
    s.transform = matrix3 sxA syA szA sunPos
    out += "sun dir=" + (s.dir as string) + "\n"

    -- shadow settings
    try ( s.shadowMapSize = 2048 ) catch()
    try ( s.raytracedShadows = true ) catch()

    -- ------------------------------------------------------------------ fill
    local oldF = getNodeByName "FILL"
    if oldF != undefined do delete oldF
    local f = Omnilight pos:[-260.0, -260.0, 220.0]
    f.name = "FILL"
    f.color = color 176 202 235
    f.multiplier = 0.22
    f.castShadows = false
    try ( f.decayType = 0 ) catch()

    out
)
