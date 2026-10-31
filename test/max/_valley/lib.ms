/* =====================================================================
   Stylized mountain valley - shared math library
   All units are metres, Z is up, +Y is upstream (away from camera).
   Analytic height field: no grid-aligned high frequency noise, so the
   10 m mesh cannot produce moire.
   ===================================================================== */

global mcpRV_X0 = -460.0
global mcpRV_X1 = 460.0
global mcpRV_Y0 = -720.0
global mcpRV_Y1 = 720.0
global mcpRV_CELL = 10.0

global mcpRV_FY = 10.0        -- waterfall y
global mcpRV_DROP = 12.0      -- waterfall height

-- ridge profile control points (t = distance from valley floor edge, v = 0..1)
global mcpRV_RP = #( #(0.0,0.0), #(55.0,0.085), #(85.0,0.37), #(150.0,0.46), #(185.0,0.74), #(250.0,0.885), #(330.0,1.0), #(430.0,1.0) )

fn mcpRV_clamp v a b = ( if v < a then a else ( if v > b then b else v ) )

fn mcpRV_ss e0 e1 x =
(
    local t = mcpRV_clamp ((x - e0) / (e1 - e0)) 0.0 1.0
    t * t * (3.0 - 2.0 * t)
)

fn mcpRV_lerp a b t = ( a + (b - a) * t )

-- river centreline
fn mcpRV_riverX y = ( 55.0 * sin(y / 230.0) + 22.0 * sin(y / 95.0 + 1.1) )

fn mcpRV_waterBase y = ( 26.0 + 0.004 * y )

-- waterfall step: 0 downstream, +DROP upstream
fn mcpRV_stepH y = ( mcpRV_DROP * mcpRV_ss (mcpRV_FY - 6.0) (mcpRV_FY + 6.0) y )

-- lateral falloff of the waterfall step, so the whole valley floor does not lift
fn mcpRV_stepFall d = ( 1.0 - mcpRV_ss 55.0 95.0 (abs d) )

fn mcpRV_waterZ y = ( mcpRV_waterBase y + mcpRV_stepH y )

fn mcpRV_ridgeProf t =
(
    local P = mcpRV_RP
    local n = P.count
    if t <= P[1][1] do return P[1][2]
    if t >= P[n][1] do return P[n][2]
    for i = 1 to (n - 1) do
    (
        if (t >= P[i][1]) and (t <= P[i+1][1]) do
        (
            local u = (t - P[i][1]) / (P[i+1][1] - P[i][1])
            return (mcpRV_lerp P[i][2] P[i+1][2] (mcpRV_ss 0.0 1.0 u))
        )
    )
    P[n][2]
)

-- main height field
fn mcpRV_terrainH x y =
(
    local cx = mcpRV_riverX y
    local d  = x - cx
    local a  = abs d
    local wb = mcpRV_waterBase y
    local bed  = wb - 6.0
    local bank = wb + 5.0
    local h = 0.0

    if a < 22.0 then
        h = bed
    else if a < 44.0 then
        h = mcpRV_lerp bed bank (mcpRV_ss 22.0 44.0 a)
    else
    (
        -- warp the ridge profile laterally along Y so the cliff bands are not
        -- perfectly parallel to the river
        local warp = 20.0 * sin(y / 150.0 + 0.8) + 11.0 * sin(y / 67.0 + 2.1)
        local t = a - 44.0 + warp
        if t < 0.0 do t = 0.0
        local crest = 190.0
        if d > 0.0 do crest = 128.0
        local rv = 0.86 + 0.14 * sin(y / 260.0 + 1.3) + 0.06 * sin(y / 97.0)
        h = bank + 0.05 * t + crest * (mcpRV_ridgeProf t) * rv
    )

    -- large scale undulation, wavelength >= 120 m (>= 12 cells)
    local big = (5.5 * sin(x / 40.0 + 0.7) * cos(y / 52.0)) + (3.0 * sin((x + y) / 55.0 - 0.4)) + (2.0 * sin(y / 61.0 + x / 47.0))
    local bigF = 0.30 + 0.70 * mcpRV_ss 44.0 130.0 a

    local step = mcpRV_stepH y * mcpRV_stepFall d
    local head = 100.0 * mcpRV_ss 590.0 720.0 y

    h + big * bigF + step + head
)

-- gradient magnitude of the height field
fn mcpRV_slope x y =
(
    local e = 6.0
    local gx = (mcpRV_terrainH (x + e) y) - (mcpRV_terrainH (x - e) y)
    local gy = (mcpRV_terrainH x (y + e)) - (mcpRV_terrainH x (y - e))
    (sqrt (gx * gx + gy * gy)) / (2.0 * e)
)

/* ------------------------------------------------------------ curve helpers */
fn mcpRV_crPoint p0 p1 p2 p3 t =
(
    local t2 = t * t
    local t3 = t2 * t
    local a = p1 * 2.0
    local b = (p2 - p0) * t
    local c = (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
    local e = (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3
    (a + b + c + e) * 0.5
)

fn mcpRV_sampleCurve pts steps =
(
    local out = #()
    local n = pts.count
    for i = 1 to (n - 1) do
    (
        local p0 = pts[(if (i - 1) < 1 then 1 else (i - 1))]
        local p1 = pts[i]
        local p2 = pts[i + 1]
        local p3 = pts[(if (i + 2) > n then n else (i + 2))]
        for s = 0 to (steps - 1) do
            append out (mcpRV_crPoint p0 p1 p2 p3 ((s as float) / (steps as float)))
    )
    append out pts[n]
    out
)

/* --------------------------------------------------------- geometry helpers */
-- build a quad strip from a 2D sample list; returns a mesh
-- cols: array of #(offsetFn, zFn) handled by caller instead
fn mcpRV_makeRibbon verts faces nm =
(
    local m = mesh vertices:verts faces:faces
    m.name = nm
    update m
    m
)
