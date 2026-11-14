/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_context.ms
   The scene context store: one place that answers "what is in this scene right
   now", with a revision so a caller can ask only for what changed.

   Why a cache instead of a scan per call
   --------------------------------------
   Measured on the live 65 object scene: building full node info for every
   object costs 7 ms inside Max, but list_objects costs 62 ms end to end.  The
   expensive half is serialising all that text, not reading the scene.  So the
   context never pushes everything: each domain is a bounded summary, rebuilt
   only when its revision moved, and the caller pages into the detail tools for
   the rest.

   Revision model
   --------------
   * mcpEvRevision (mcp_events.ms) is the global counter, bumped by every
     callback and by every mutating MCP command.
   * every domain keeps its own counter, so a material edit does not force the
     render section to be rebuilt.
   * a cache entry remembers the domain revision it was built from.  Stale
     entries are rebuilt on demand; nothing here runs on a timer.

   What this module does NOT do
   ----------------------------
   No polling of the scene graph on a timer, no watcher thread, no second
   socket.  mcpCtxTick rides the existing 25 ms bridge pump and does O(1) work
   (one clock string, one identity comparison every 8th tick).

   Data honesty rules (project principle 6/7/15)
   --------------------------------------------
   Every section carries `source`, `valid`, `supported`, `stale`, `revision`,
   `updatedAt` and, when a read failed, an `error` string -- never a fabricated
   zero.  `valid` is about this read, `supported` is about the API existing on
   this build, `stale` is about age; three different questions, three fields.
   A section whose underlying API is missing says `supported:false` and why.
-----------------------------------------------------------------------------*/

global mcpCtxDomains, mcpCtxRev, mcpCtxCache, mcpCtxBuilds, mcpCtxTickCount
global mcpCtxStamp, mcpCtxSent
global mcpCtxIdentity, mcpCtxLastError, mcpCtxLastFullScan, mcpCtxSlowMs
global mcpCtxMarkDirty, mcpCtxTick, mcpCtxDomainIndex, mcpCtxRevFor, mcpCtxPayload
global mcpCtxWrap, mcpCtxPayloadFull, mcpCtxCachedEntry
global mcpCtxBuildScene, mcpCtxBuildSelection, mcpCtxBuildObjects, mcpCtxBuildMaterials
global mcpCtxBuildAssets, mcpCtxBuildAnimation, mcpCtxBuildRigging, mcpCtxBuildRender
global mcpCtxBuildProject, mcpCtxSuperKind, mcpCtxNodeRow, mcpCtxReset
global mcpH_context_get, mcpH_context_refresh, mcpH_context_stats, mcpH_context_events
global mcpContextGet, mcpContextRefresh, mcpContextStats, mcpContextSections
global mcpErrText, mcpToBool

if mcpCtxDomains == undefined do mcpCtxDomains = #(
    "scene", "selection", "objects", "materials", "assets",
    "animation", "rigging", "render", "project"
)
if mcpCtxRev == undefined do mcpCtxRev = #(0, 0, 0, 0, 0, 0, 0, 0, 0)
if mcpCtxStamp == undefined do mcpCtxStamp = #(0, 0, 0, 0, 0, 0, 0, 0, 0)
/* The changedAt value that was current when this domain last went out over the
   wire; -1 means "never sent".  Without it, a domain that has not changed since
   the engine started (changedAt 0) would be skipped for a caller that has never
   received it, which is a silent data gap, not an optimisation. */
if mcpCtxSent == undefined do mcpCtxSent = #(-1, -1, -1, -1, -1, -1, -1, -1, -1)
if mcpCtxCache == undefined do mcpCtxCache = #()
if mcpCtxBuilds == undefined do mcpCtxBuilds = 0
if mcpCtxTickCount == undefined do mcpCtxTickCount = 0
if mcpCtxIdentity == undefined do mcpCtxIdentity = #(-1, -1, "")
if mcpCtxLastError == undefined do mcpCtxLastError = ""
if mcpCtxLastFullScan == undefined do mcpCtxLastFullScan = 0
if mcpCtxSlowMs == undefined do mcpCtxSlowMs = 0


/*---------------------------------------------------------------- revision API*/
fn mcpCtxDomainIndex domain =
(
    local d = toLower (domain as string)
    local idx = 0
    for i = 1 to mcpCtxDomains.count while idx == 0 do
        ( if mcpCtxDomains[i] == d do idx = i )
    idx
)

fn mcpCtxRevFor domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then 0 else mcpCtxRev[i]
)

/* Called from mcp_events.ms on every change.  Must stay O(domains): it runs
   inside synchronous callbacks such as #selectionSetChanged.

   Two counters per domain, on purpose:
     mcpCtxRev[i]   - the cache key.  Bumped so the cached copy is dropped.
     mcpCtxStamp[i] - the value of the *global* revision at the moment this
                      domain last changed.  This is what `since` compares
                      against.
   Comparing `since` (a global revision) with mcpCtxRev would silently lose
   updates: a domain that changed once has rev 1 while the global revision may
   already be 40, so `rev <= since` would call a real change "unchanged". */
fn mcpCtxMarkDirty domains =
(
    local touched = 0
    local stamp = 0
    if mcpEvRevision != undefined do stamp = mcpEvRevision
    for d in domains do
    (
        local i = mcpCtxDomainIndex d
        if i > 0 do
        (
            mcpCtxRev[i] = mcpCtxRev[i] + 1
            mcpCtxStamp[i] = stamp
            touched += 1
        )
    )
    if touched > 0 and mcpEvClock != undefined and mcpEvClock == "" do
        ( try ( mcpEvClockUpdate() ) catch() )
    touched
)

fn mcpCtxReset =
(
    mcpCtxCache = #()
    local stamp = 0
    if mcpEvRevision != undefined do stamp = mcpEvRevision
    for i = 1 to mcpCtxRev.count do
    (
        mcpCtxRev[i] = mcpCtxRev[i] + 1
        mcpCtxStamp[i] = stamp
        -- An explicit refresh means "re-read", so the next context_get sends
        -- everything again instead of trusting the caller's cursor.
        mcpCtxSent[i] = -1
    )
    mcpCtxLastError = ""
    mcpCtxCache.count
)


/*------------------------------------------------------------ classification*/
/* `superclassof` does not answer in one spelling: measured on 2022 it returns
   "GeometryClass" but "shape", "light", "camera", "helper" in lower case, so
   the old `sc == "Geometry"` comparisons in scene_statistics never matched and
   every object landed in "other".  Normalise once, here, and let both this
   module and the statistics tool use the same answer. */
fn mcpCtxSuperKind n =
(
    local v = ""
    try ( v = toLower ((superclassof n) as string) ) catch ( v = "" )
    local cls = ""
    try ( cls = (classof n) as string ) catch ( cls = "" )

    -- Early returns instead of a long if/else chain: MAXScript closes an
    -- `if ... then <expr>` statement at the end of the line, so a following
    -- `else` on its own line is a syntax error ("at else, expected <factor>").
    if cls == "BoneGeometry" do return "bone"
    if cls == "Biped_Object" do return "bone"
    if cls == "CATBone" do return "bone"
    if (findString v "spacewarp") != undefined do return "spacewarp"
    if (findString v "geometry") != undefined do return "geometry"
    if (findString v "shape") != undefined do return "shape"
    if (findString v "spline") != undefined do return "shape"
    if (findString v "light") != undefined do return "light"
    if (findString v "camera") != undefined do return "camera"
    if (findString v "helper") != undefined do return "helper"
    if (findString v "system") != undefined do return "system"
    if (findString v "particle") != undefined do return "particle"
    "other"
)

/* Compact row for the selection section.  `mcpNodeInfo` is the full record used
   by get_object_info; this one is deliberately smaller because the selection
   section is rebuilt on every click. */
fn mcpCtxNodeRow n detail:"brief" =
(
    local p = #()
    mcpPair p "name" (try ( n.name ) catch ( "" ))
    mcpPair p "handle" (try ( (getHandleByAnim n) as integer ) catch ( 0 ))
    mcpPair p "class" (try ( (classof n) as string ) catch ( "" ))
    mcpPair p "kind" (mcpCtxSuperKind n)
    mcpPair p "parent" (try ( if n.parent != undefined then n.parent.name else "" ) catch ( "" ))
    mcpPair p "layer" (try ( n.layer.name ) catch ( "" ))
    mcpPair p "material" (try ( if n.material != undefined then n.material.name else "" ) catch ( "" ))
    mcpPair p "hidden" (try ( n.isHidden ) catch ( false ))
    mcpPair p "frozen" (try ( n.isFrozen ) catch ( false ))
    mcpPair p "modifierCount" (try ( n.modifiers.count ) catch ( 0 ))
    mcpPair p "faces" (try ( (getPolygonCount n)[1] ) catch ( 0 ))
    mcpPair p "verts" (try ( (getPolygonCount n)[2] ) catch ( 0 ))

    if detail == "full" do
    (
        mcpPair p "position" (try ( n.position ) catch ( [0,0,0] ))
        mcpPair p "rotation" (try ( (n.rotation as eulerAngles) ) catch ( (eulerAngles 0 0 0) ))
        mcpPair p "scale" (try ( n.scale ) catch ( [1,1,1] ))
        local mn = [0,0,0]
        local mx = [0,0,0]
        try
        (
            local bb = nodeGetBoundingBox n (matrix3 1)
            mn = bb[1]
            mx = bb[2]
        )
        catch()
        mcpPair p "bboxMin" mn
        mcpPair p "bboxMax" mx
        mcpPair p "size" (mx - mn)
        local mods = #()
        try ( for m in n.modifiers do append mods #((classof m) as string, (try (m.name) catch (""))) )
        catch()
        mcpPair p "modifiers" mods
        mcpPair p "wirecolor" (try ( n.wirecolor ) catch ( (color 0 0 0) ))
    )
    mcpObj p
)


/*------------------------------------------------------------------ builders*/
fn mcpCtxBuildScene =
(
    local p = #()
    mcpPair p "name" (try ( maxFileName ) catch ( "" ))
    mcpPair p "path" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "file" (try ( maxFilePath + maxFileName ) catch ( "" ))
    mcpPair p "modified" (try ( getSaveRequired() ) catch ( false ))
    mcpPair p "objectCount" (try ( objects.count ) catch ( 0 ))
    mcpPair p "selectionCount" (try ( selection.count ) catch ( 0 ))
    mcpPair p "layerCount" (try ( LayerManager.count ) catch ( 0 ))
    mcpPair p "currentLayer" (try ( LayerManager.current.name ) catch ( "" ))
    mcpPair p "renderer" (mcpCurrentRendererName())
    mcpPair p "systemUnits" (try ( (units.SystemType) as string ) catch ( "" ))
    -- Display units and the unit scale are two different numbers and tools
    -- routinely need both: SystemType is what geometry is stored in.
    mcpPair p "displayUnits" (try ( (units.DisplayType) as string ) catch ( "" ))
    mcpPair p "unitScale" (try ( units.SystemScale as float ) catch ( 0.0 ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "currentFrame" (try ( currentTime.frame as integer ) catch ( 0 ))
    mcpPair p "maxVersion" (mcpMaxYear())
    mcpPair p "openGroups" (try ( (for g in objects where (classof g) == GroupHead collect g.name) ) catch ( #() ))
    mcpObj p
)

fn mcpCtxBuildSelection detail:"brief" limit:50 =
(
    local nodes = #()
    try ( for i = 1 to selection.count do append nodes selection[i] ) catch()
    local shown = #()
    local n = 0
    for node in nodes do
    (
        n += 1
        if n <= limit do append shown (mcpCtxNodeRow node detail:detail)
    )
    local kinds = #()
    local kk = #()
    local totalFaces = 0
    local totalVerts = 0
    for node in nodes do
    (
        local k = mcpCtxSuperKind node
        local idx = 0
        for i = 1 to kk.count while idx == 0 do ( if kk[i] == k do idx = i )
        if idx == 0 then ( append kk k; append kinds #(k, 1) ) else ( kinds[idx][2] = kinds[idx][2] + 1 )
        try ( totalFaces += (getPolygonCount node)[1] ) catch()
        try ( totalVerts += (getPolygonCount node)[2] ) catch()
    )
    local p = #()
    mcpPair p "count" nodes.count
    mcpPair p "shown" shown.count
    mcpPair p "truncated" (nodes.count > shown.count)
    mcpPair p "kinds" kinds
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "objects" shown
    mcpObj p
)

fn mcpCtxBuildObjects =
(
    local counts = #(0, 0, 0, 0, 0, 0, 0, 0, 0)   -- geometry shape light camera helper spacewarp system bone other
    local hiddenCount = 0
    local frozenCount = 0
    local rootCount = 0
    local totalFaces = 0
    local totalVerts = 0
    local names = #()

    for o in objects do
    (
        local k = mcpCtxSuperKind o
        case k of
        (
            "geometry":   counts[1] += 1
            "shape":      counts[2] += 1
            "light":      counts[3] += 1
            "camera":     counts[4] += 1
            "helper":     counts[5] += 1
            "spacewarp":  counts[6] += 1
            "system":     counts[7] += 1
            "bone":       counts[8] += 1
            default:      counts[9] += 1
        )
        try ( if o.isHidden do hiddenCount += 1 ) catch()
        try ( if o.isFrozen do frozenCount += 1 ) catch()
        try ( if o.parent == undefined do rootCount += 1 ) catch()
        try ( local pc = getPolygonCount o; totalFaces += pc[1]; totalVerts += pc[2] ) catch()
    )

    local p = #()
    mcpPair p "total" (try ( objects.count ) catch ( 0 ))
    mcpPair p "geometry" counts[1]
    mcpPair p "shapes" counts[2]
    mcpPair p "lights" counts[3]
    mcpPair p "cameras" counts[4]
    mcpPair p "helpers" counts[5]
    mcpPair p "spacewarps" counts[6]
    mcpPair p "systems" counts[7]
    mcpPair p "bones" counts[8]
    mcpPair p "other" counts[9]
    mcpPair p "roots" rootCount
    mcpPair p "hidden" hiddenCount
    mcpPair p "frozen" frozenCount
    mcpPair p "totalFaces" totalFaces
    mcpPair p "totalVerts" totalVerts
    mcpPair p "classification" "superclassof normalised (see mcpCtxSuperKind)"
    mcpObj p
)

fn mcpCtxBuildMaterials limit:100 =
(
    local rows = #()
    local total = 0
    local withMaps = 0
    local withSubs = 0
    local list = #()
    try ( list = sceneMaterials ) catch ( list = #() )
    for m in list do
    (
        total += 1
        local mapCount = 0
        try
        (
            for prop in (getPropNames m) do
            (
                local v = getProperty m prop
                if isKindOf v TextureMap do mapCount += 1
            )
        )
        catch()
        local subCount = 0
        try ( subCount = (getSubMtls m).count ) catch ( subCount = 0 )
        if mapCount > 0 do withMaps += 1
        if subCount > 0 do withSubs += 1
        if rows.count < limit do
        (
            local p = #()
            mcpPair p "name" (try ( m.name ) catch ( "" ))
            mcpPair p "class" (try ( (classof m) as string ) catch ( "" ))
            mcpPair p "mapSlots" mapCount
            mcpPair p "subMaterials" subCount
            append rows (mcpObj p)
        )
    )
    local p = #()
    mcpPair p "count" total
    mcpPair p "withMaps" withMaps
    mcpPair p "withSubMaterials" withSubs
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (total > rows.count)
    mcpPair p "items" rows
    mcpObj p
)

fn mcpCtxBuildAssets limit:100 =
(
    local textures = #()
    try ( textures = mcpCollectBitmapTextures() ) catch ( textures = #() )
    local rows = #()
    local missingFiles = #()
    local seen = #()
    local dupes = 0
    local missing = 0
    local totalBytes = 0

    for t in textures do
    (
        local fname = ""
        try ( fname = t.filename ) catch ( fname = "" )
        local exists = false
        local size = 0
        if fname != "" do
        (
            try ( exists = doesFileExist fname ) catch ( exists = false )
            if exists do
            (
                -- FileInfo, not BitmapTexture.bitmap: reading the size of a
                -- bitmap from disk just to report bytes would load every map.
                try
                (
                    local fi = (dotNetClass "System.IO.FileInfo").new fname
                    size = fi.Length
                )
                catch ( size = 0 )
            )
        )
        if not exists do
        (
            if fname != "" do
            (
                missing += 1
                local known = false
                for f in missingFiles while not known do ( if (toLower f) == (toLower fname) do known = true )
                if not known do append missingFiles fname
            )
        )

        totalBytes += size

        if fname != "" do
        (
            local key = toLower fname
            local idx = 0
            for i = 1 to seen.count while idx == 0 do ( if seen[i][1] == key do idx = i )
            if idx == 0 then ( append seen #(key, 1) ) else (
                seen[idx][2] = seen[idx][2] + 1
                if seen[idx][2] == 2 do dupes += 1
            )
        )

        if rows.count < limit do
        (
            local p = #()
            mcpPair p "name" (try ( t.name ) catch ( "" ))
            mcpPair p "class" (try ( (classof t) as string ) catch ( "" ))
            mcpPair p "filename" fname
            mcpPair p "exists" exists
            mcpPair p "sizeBytes" size
            append rows (mcpObj p)
        )
    )

    local shared = #()
    for s in seen do ( if s[2] > 1 do append shared #(s[1], s[2]) )

    local p = #()
    mcpPair p "count" textures.count
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (textures.count > rows.count)
    mcpPair p "missing" missing
    mcpPair p "missingFiles" missingFiles
    mcpPair p "duplicateFiles" dupes
    mcpPair p "sharedFiles" shared
    mcpPair p "totalBytes" totalBytes
    mcpPair p "items" rows
    mcpObj p
)

fn mcpCtxBuildAnimation limit:100 =
(
    local keyed = 0
    local totalKeys = 0
    local rows = #()
    local controllers = #()

    for o in objects do
    (
        local pk = 0
        local rk = 0
        local sk = 0
        try ( pk = o.position.controller.keys.count ) catch ( pk = 0 )
        try ( rk = o.rotation.controller.keys.count ) catch ( rk = 0 )
        try ( sk = o.scale.controller.keys.count ) catch ( sk = 0 )
        local sum = pk + rk + sk
        if sum > 0 do
        (
            keyed += 1
            totalKeys += sum
            if rows.count < limit do
            (
                local p = #()
                mcpPair p "name" (try ( o.name ) catch ( "" ))
                mcpPair p "positionKeys" pk
                mcpPair p "rotationKeys" rk
                mcpPair p "scaleKeys" sk
                mcpPair p "total" sum
                append rows (mcpObj p)
            )
        )
        -- controller class inventory: catches constraints and scripted
        -- controllers that hold no keys but still define the motion.
        local ctrlClass = ""
        try ( ctrlClass = (classof o.position.controller) as string ) catch ( ctrlClass = "" )
        if ctrlClass != "" and (findString (toLower ctrlClass) "prs") == undefined do
        (
            local idx = 0
            for i = 1 to controllers.count while idx == 0 do
                ( if controllers[i][1] == ctrlClass do idx = i )
            if idx == 0 then ( append controllers #(ctrlClass, 1) ) else ( controllers[idx][2] = controllers[idx][2] + 1 )
        )
    )

    local p = #()
    mcpPair p "currentFrame" (try ( currentTime.frame as integer ) catch ( 0 ))
    mcpPair p "startFrame" (try ( animationRange.start.frame as integer ) catch ( 0 ))
    mcpPair p "endFrame" (try ( animationRange.end.frame as integer ) catch ( 0 ))
    mcpPair p "frameRate" (try ( frameRate as integer ) catch ( 0 ))
    mcpPair p "animatedObjects" keyed
    mcpPair p "totalKeys" totalKeys
    mcpPair p "shown" rows.count
    mcpPair p "truncated" (keyed > rows.count)
    mcpPair p "objects" rows
    mcpPair p "nonDefaultControllers" controllers
    mcpObj p
)

fn mcpCtxBuildRigging =
(
    local boneGeom = 0
    local biped = 0
    local cat = 0
    local dummyBones = 0
    local skinObjects = 0
    local skinnedBones = 0
    local otherHelpers = 0
    local systems = #()

    for o in objects do
    (
        local cls = ""
        try ( cls = (classof o) as string ) catch ( cls = "" )
        if cls == "BoneGeometry" then ( boneGeom += 1 ) else if cls == "Biped_Object" then ( biped += 1 ) else if cls == "CATBone" then ( cat += 1 ) else if cls == "Dummy" then ( dummyBones += 1 ) else if cls == "Point" then ( otherHelpers += 1 )

        local isSkin = false
        try
        (
            for m in o.modifiers do
                ( if (classof m) as string == "Skin" do isSkin = true )
        )
        catch()
        if isSkin do
        (
            skinObjects += 1
            try
            (
                for m in o.modifiers do
                (
                    if (classof m) as string == "Skin" do
                    (
                        local nb = 0
                        try ( nb = skinOps.getNumberBones m ) catch ( nb = 0 )
                        skinnedBones += nb
                    )
                )
            )
            catch()
        )
        -- System objects (Biped controller root, CAT rig, ...) are reported
        -- separately: they are not bones but they own the rig.
        if (mcpCtxSuperKind o) == "system" do
        (
            local idx = 0
            for i = 1 to systems.count while idx == 0 do ( if systems[i][1] == cls do idx = i )
            if idx == 0 then ( append systems #(cls, 1) ) else ( systems[idx][2] = systems[idx][2] + 1 )
        )
    )

    local totalBones = boneGeom + biped + cat
    local p = #()
    mcpPair p "bones" totalBones
    mcpPair p "boneGeometry" boneGeom
    mcpPair p "bipedBones" biped
    mcpPair p "catBones" cat
    mcpPair p "dummies" dummyBones
    mcpPair p "pointHelpers" otherHelpers
    mcpPair p "skinObjects" skinObjects
    mcpPair p "bonesInSkins" skinnedBones
    mcpPair p "systems" systems
    mcpPair p "supported" true
    mcpPair p "note" "counts by class; Biped and CAT are counted separately because they do not use BoneGeometry"
    mcpObj p
)

fn mcpCtxBuildRender =
(
    local p = #()
    mcpPair p "renderer" (mcpCurrentRendererName())
    mcpPair p "width" (try ( renderWidth as integer ) catch ( 0 ))
    mcpPair p "height" (try ( renderHeight as integer ) catch ( 0 ))
    mcpPair p "pixelAspect" (try ( renderPixelAspect as float ) catch ( 1.0 ))
    mcpPair p "outputPath" (try ( rendOutputFilename ) catch ( "" ))
    -- rendSaveFile already returns a Boolean; `as boolean` on it raises.
    mcpPair p "saveFile" (mcpToBool (try ( rendSaveFile ) catch ( undefined )) fallback:false)
    mcpPair p "timeType" (try ( rendTimeType as integer ) catch ( 0 ))
    mcpPair p "frameStart" (try ( renderStart as integer ) catch ( 0 ))
    mcpPair p "frameEnd" (try ( renderEnd as integer ) catch ( 0 ))
    mcpPair p "frames" (try ( rendPickupFrames as string ) catch ( "" ))

    local elements = 0
    local ok = true
    -- MAXScript cannot call a method on a call result
    -- (`maxOps.GetCurRenderElementMgr().NumRenderElements()` is a syntax
    -- error), so the manager is bound first.
    local mgr = undefined
    try ( mgr = maxOps.GetCurRenderElementMgr() ) catch ( mgr = undefined )
    if mgr != undefined do
    (
        try ( elements = mgr.NumRenderElements() )
        catch ( ok = false )
    )
    mcpPair p "renderElementCount" elements
    mcpPair p "renderElementsSupported" ok

    local expo = ""
    try ( expo = (classof SceneExposureControl.exposureControl) as string ) catch ( expo = "" )
    mcpPair p "exposureControl" expo

    -- Bracket state from #preRender / #postRender.  No progress percentage is
    -- reported because this release has no notification for it; saying "no
    -- progress available" is more useful than inventing a number.
    mcpPair p "rendering" (if mcpEvRendering == undefined then false else mcpEvRendering)
    mcpPair p "lastRenderMs" (if mcpEvLastRender == undefined then 0 else mcpEvLastRender)
    mcpPair p "progressAvailable" false
    mcpObj p
)

fn mcpCtxBuildProject =
(
    local projectFolder = ""
    try ( projectFolder = pathConfig.getCurrentProjectFolder() ) catch ( projectFolder = "" )

    local xrefCount = 0
    local xrefs = #()
    local xrefOk = true
    try
    (
        xrefCount = xrefs.getXRefFileCount()
        local lim = 50
        local n = 0
        for i = 1 to xrefCount do
        (
            n += 1
            if n <= lim do
            (
                local x = undefined
                try ( x = xrefs.getXRefFile i ) catch ( x = undefined )
                if x != undefined do
                (
                    local row = #()
                    mcpPair row "file" (try ( x.filename ) catch ( "" ))
                    mcpPair row "disabled" (try ( x.disabled ) catch ( false ))
                    append xrefs (mcpObj row)
                )
            )
        )
    )
    catch ( xrefOk = false )

    local p = #()
    mcpPair p "projectFolder" projectFolder
    mcpPair p "sceneFile" (try ( maxFilePath + maxFileName ) catch ( "" ))
    mcpPair p "sceneDir" (try ( maxFilePath ) catch ( "" ))
    mcpPair p "xrefCount" xrefCount
    mcpPair p "xrefs" xrefs
    mcpPair p "xrefSupported" xrefOk
    mcpPair p "saveRequired" (try ( getSaveRequired() ) catch ( false ))
    mcpObj p
)


/*----------------------------------------------------------------- assembly*/
fn mcpCtxBuild domain =
(
    local d = toLower (domain as string)
    local limit = 100
    case d of
    (
        "scene":     (mcpCtxBuildScene())
        "selection": (mcpCtxBuildSelection detail:"brief" limit:50)
        "objects":   (mcpCtxBuildObjects())
        "materials": (mcpCtxBuildMaterials limit:limit)
        "assets":    (mcpCtxBuildAssets limit:limit)
        "animation": (mcpCtxBuildAnimation limit:limit)
        "rigging":   (mcpCtxBuildRigging())
        "render":    (mcpCtxBuildRender())
        "project":   (mcpCtxBuildProject())
        default:     (mcpObj #(#("supported", false), #("error", "unknown context section: " + d)))
    )
)

/* Returns #(payload, wasCached).  One cache entry per domain; rebuilding is
   always a full rebuild of that domain (partial merges of nested records would
   be more code than they are worth at these sizes). */
/* Every section that leaves the bridge goes through this wrapper, including the
   uncached `detail:"full"` variants.  Skipping it once (as the first draft did
   for a full selection dump) produces a section with no revision, no source and
   no validity flag, which is exactly the "returned ok but unverifiable" case
   the project forbids. */
/* The cached wrapper for a domain, but only when it was built from the
   domain's current revision.  Returning an out-of-date copy is the failure
   mode this whole module exists to avoid, so a miss returns undefined and the
   caller rebuilds. */
fn mcpCtxCachedEntry domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then return undefined
    local rev = mcpCtxRev[i]
    local found = undefined
    for e in mcpCtxCache do
    (
        if e[1] == mcpCtxDomains[i] and e[2] == rev do found = e
    )
    found
)

/* The provenance block every section carries.  Four fields answer four
   different questions and must never be collapsed into one boolean:

     valid      - did THIS read produce data without raising?
     supported  - does this build offer the API this domain needs at all?
                  (a missing polyop sub-API is "unsupported", not "invalid")
     stale      - is this payload older than the domain's latest change?
                  a cache entry is dropped rather than served out of date, so
                  this is normally false and becomes true only when the domain
                  moved between the lookup and the wrap.
     updatedAt  - when the payload was generated (Max side clock string).

   `supported` defaults to whatever the collector itself declared in its
   payload, so a section that probed an API and found it missing reports
   supported:false without the wrapper having to know about that API. */
fn mcpCtxWrap domain rev payload ms err supported:true stale:false =
(
    local sup = supported
    if mcpIsObj payload and (mcpHas payload "supported") do
    (
        sup = mcpToBool (mcpGet payload "supported") fallback:supported
    )

    local pairs = #()
    mcpPair pairs "domain" domain
    mcpPair pairs "revision" rev
    mcpPair pairs "updatedAt" (if mcpEvClock == undefined then "" else mcpEvClock)
    mcpPair pairs "source" "maxscript"
    mcpPair pairs "valid" (err == "")
    mcpPair pairs "stale" stale
    mcpPair pairs "supported" sup
    mcpPair pairs "buildMs" ms
    if err != "" do mcpPair pairs "error" err
    -- `data` keeps the payload one level down so provenance can never collide
    -- with a field the collector happens to use.
    mcpPair pairs "data" payload
    mcpObj pairs
)

fn mcpCtxPayload domain =
(
    local i = mcpCtxDomainIndex domain
    if i == 0 then return #(mcpObj #(#("supported", false), #("error", "unknown domain")), false)

    local rev = mcpCtxRev[i]
    local entry = mcpCtxCachedEntry mcpCtxDomains[i]
    if entry != undefined then return #(entry[3], true)

    local t0 = (timeStamp())
    local payload = undefined
    local err = ""
    try ( payload = mcpCtxBuild mcpCtxDomains[i] )
    catch ( err = mcpErrText (getCurrentException()) )

    if payload == undefined do
    (
        mcpCtxLastError = err
        -- No `supported:false` here: the domain exists, this one build threw.
        -- Conflating the two would make a transient failure look permanent.
        payload = mcpObj #(
            #("valid", false),
            #("error", "context build failed: " + err)
        )
    )

    local ms = (timeStamp()) - t0
    if ms > mcpCtxSlowMs do mcpCtxSlowMs = ms
    mcpCtxBuilds += 1

    -- Wrap with the provenance every section must carry.
    local wrapped = mcpCtxWrap mcpCtxDomains[i] rev payload ms err stale:(mcpCtxRev[i] > rev)

    -- Replace the entry for this domain (keep at most one per domain).
    local kept = #()
    for e in mcpCtxCache do ( if e[1] != mcpCtxDomains[i] do append kept e )
    append kept #(mcpCtxDomains[i], rev, wrapped)
    mcpCtxCache = kept

    #(wrapped, false)
)


/*--------------------------------------------------------------- the tick*/
/* Runs on the existing bridge pump.  Budget: one clock string and three
   integer comparisons, eight times a second.  Anything heavier belongs in a
   builder, which only runs when a caller asks for that domain. */
fn mcpCtxTick =
(
    mcpCtxTickCount += 1
    if (mod mcpCtxTickCount 8) != 0 do return 0

    try ( mcpEvClockUpdate() ) catch()

    -- Identity check: catches what has no notification on this release
    -- (file > new, reset, merge, a script writing to the scene outside MCP).
    local now = #(0, 0, "")
    try ( now = #(objects.count, selection.count, (maxFilePath + maxFileName)) ) catch ( now = #(-1, -1, "") )

    local changed = #()
    if now[1] != mcpCtxIdentity[1] do ( append changed "objects"; append changed "scene" )
    if now[2] != mcpCtxIdentity[2] do append changed "selection"
    if now[3] != mcpCtxIdentity[3] do
    (
        append changed "scene"
        append changed "project"
        append changed "objects"
        append changed "selection"
        append changed "materials"
        append changed "assets"
    )
    mcpCtxIdentity = now

    if changed.count > 0 do
    (
        -- De-duplicate before bumping: "objects" can be listed twice above.
        local uniq = #()
        for d in changed do
        (
            local dup = false
            for u in uniq while not dup do ( if u == d do dup = true )
            if not dup do append uniq d
        )
        -- Bump first: mcpCtxMarkDirty stamps each domain with the current
        -- global revision, so the stamp has to be the new one.
        if mcpEvRevision != undefined do mcpEvRevision += 1
        mcpCtxMarkDirty uniq
    )
    changed.count
)


/*---------------------------------------------------------------- handlers*/
fn mcpContextSections =
(
    local out = #()
    for d in mcpCtxDomains do append out d
    out
)

fn mcpH_context_get params =
(
    local requested = mcpArr params "sections"
    local since = mcpInt params "since" default:0
    local detail = toLower (mcpStr params "detail" default:"brief")
    local t0 = (timeStamp())

    local wanted = #()
    if requested.count > 0 then
    (
        for s in requested do
        (
            local name = if isKindOf s String then s else (try (s as string) catch (""))
            local known = if name != "" then ((mcpCtxDomainIndex name) > 0) else false
            if known then ( append wanted (toLower name) ) else ( if name != "" do mcpFail "err.bad_value" a1:name )
        )
    ) else ( wanted = mcpContextSections() )

    local sections = #()
    local built = #()
    local cached = #()
    local skipped = #()

    for d in wanted do
    (
        local idx = mcpCtxDomainIndex d
        local rev = mcpCtxRev[idx]
        -- `since` is the incremental switch: a domain whose last change predates
        -- the caller's cursor is not rebuilt and not sent.  The comparison is
        -- against the global-revision stamp, never against the per-domain cache
        -- key (see mcpCtxMarkDirty).
        local stamp = mcpCtxStamp[idx]
        if since > 0 and mcpCtxSent[idx] >= 0 and stamp <= since then ( append skipped d ) else
        (
            -- detail:"full" re-runs the section with wider caps; the cached
            -- brief copy is not reused on purpose (it is smaller).  The full
            -- build is never cached, so a brief caller is not handed 200 rows.
            local payload = undefined
            if detail == "full" and d == "selection" then ( payload = mcpCtxPayloadFull d detail; append built d ) else
            (
                local res = mcpCtxPayload d
                payload = res[1]
                if res[2] then append cached d else append built d
            )
            append sections #(d, payload)
            -- Remember that the caller now holds this domain at `stamp`.
            mcpCtxSent[idx] = stamp
        )
    )

    local mapPairs = #()
    for s in sections do mcpPair mapPairs s[1] s[2]

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "since" since
    mcpPair p "detail" detail
    mcpPair p "requested" wanted
    mcpPair p "built" built
    mcpPair p "cached" cached
    mcpPair p "unchanged" skipped
    mcpPair p "sections" (mcpObj mapPairs)
    mcpPair p "timingMs" ((timeStamp()) - t0)
    mcpPair p "availableSections" (mcpContextSections())
    mcpObj p
)

/* Detail="full" needs a wider selection row set.  Kept separate so the brief
   path never pays for it.  The result is still wrapped and still carries the
   live revision, it is only kept out of the cache because a 200-row dump is not
   what the next brief caller wants back. */
fn mcpCtxPayloadFull domain detail =
(
    local d = toLower (domain as string)
    local t0 = (timeStamp())
    -- Captured before the build so staleness is measured, not assumed.
    local revAtStart = mcpCtxRevFor d
    local payload = undefined
    local err = ""
    try (
        -- Single line on purpose: MAXScript closes `if ... then <expr>` at the
        -- end of the line, so `else` must not start the next one.
        payload = if d == "selection" then ( mcpCtxBuildSelection detail:"full" limit:200 ) else ( (mcpCtxPayload d)[1] )
    )
    catch ( err = mcpErrText (getCurrentException()) )

    if payload == undefined do
    (
        mcpCtxLastError = err
        payload = mcpObj #( #("valid", false), #("error", "context build failed: " + err) )
    )

    local ms = (timeStamp()) - t0
    if ms > mcpCtxSlowMs do mcpCtxSlowMs = ms
    mcpCtxWrap d revAtStart payload ms err stale:(mcpCtxRevFor d > revAtStart)
)

fn mcpH_context_refresh params =
(
    local domains = mcpArr params "sections"
    local targets = #()
    if domains.count > 0 then
    (
        for s in domains do
        (
            local name = if isKindOf s String then s else (try (s as string) catch (""))
            if name != "" and (mcpCtxDomainIndex name) > 0 do append targets (toLower name)
        )
    ) else ( targets = mcpContextSections() )

    -- Force: bump every requested domain so its cache entry is stale, then
    -- rebuild immediately instead of waiting for the next context_get.
    mcpCtxMarkDirty targets
    local rebuilt = #()
    for d in targets do
    (
        local res = mcpCtxPayload d
        append rebuilt d
    )
    mcpCtxLastFullScan = (timeStamp())

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "rebuilt" rebuilt
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

fn mcpH_context_stats params =
(
    local stale = #()
    local revs = #()
    for i = 1 to mcpCtxDomains.count do
    (
        local entry = mcpCtxCachedEntry mcpCtxDomains[i]
        local cached = entry != undefined
        if not cached do append stale mcpCtxDomains[i]

        -- The UI reads this row directly, so it carries the same three-state
        -- provenance a section does instead of a single "cached" flag: an
        -- unbuilt domain is not the same thing as an invalid one.
        local valid = cached
        local supported = true
        local updatedAt = ""
        if cached do
        (
            local w = entry[3]
            valid = mcpToBool (mcpGet w "valid") fallback:cached
            supported = mcpToBool (mcpGet w "supported") fallback:true
            try ( updatedAt = (mcpGet w "updatedAt") as string ) catch ( updatedAt = "" )
        )

        local row = #()
        mcpPair row "domain" mcpCtxDomains[i]
        mcpPair row "revision" mcpCtxRev[i]
        -- The global revision at which this domain last changed.  `since` takes
        -- one of these values, not a per-domain cache key.
        mcpPair row "changedAt" mcpCtxStamp[i]
        mcpPair row "sentAt" mcpCtxSent[i]
        mcpPair row "cached" cached
        mcpPair row "valid" valid
        mcpPair row "supported" supported
        mcpPair row "stale" (not cached)
        mcpPair row "updatedAt" updatedAt
        append revs (mcpObj row)
    )

    local p = #()
    mcpPair p "revision" (if mcpEvRevision == undefined then 0 else mcpEvRevision)
    mcpPair p "events" (if mcpEvSeq == undefined then 0 else mcpEvSeq)
    mcpPair p "eventsRunning" (if mcpEvRunning == undefined then false else mcpEvRunning)
    mcpPair p "domains" revs
    mcpPair p "stale" stale
    mcpPair p "cachedSections" mcpCtxCache.count
    mcpPair p "builds" mcpCtxBuilds
    mcpPair p "slowestBuildMs" mcpCtxSlowMs
    mcpPair p "lastRefreshMs" mcpCtxLastFullScan
    mcpPair p "lastError" mcpCtxLastError
    mcpPair p "tickCount" mcpCtxTickCount
    mcpPair p "sinceContract" "pass the returned `revision` back as `since`; a section is skipped only when its changedAt <= since"
    mcpPair p "eventsCapabilities" (if mcpEventsCaps != undefined then (mcpEventsCaps()) else undefined)
    mcpObj p
)

fn mcpH_context_events params =
(
    mcpEventsLog limit:(mcpInt params "limit" default:50)
)

mcpRegister "context_get" mcpH_context_get undoable:false
mcpRegister "context_refresh" mcpH_context_refresh undoable:false
mcpRegister "context_stats" mcpH_context_stats undoable:false
mcpRegister "context_events" mcpH_context_events undoable:false
