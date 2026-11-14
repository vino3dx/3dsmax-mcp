# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Scene context layer: the bridge now knows what is in the scene before a tool
  asks.** Until now every question about the scene cost its own round trip, and
  an agent that wanted "what is selected and what is it made of" had to stitch
  four tools together and still guess at the rest. Three new modules change
  that.

  `src/ms/mcp_events.ms` is the listener layer. Notifications are registered
  through `try` and then *reported*, never assumed: on the 2022 build measured
  here `callbacks.addScript` accepts 20 of the 55 documented notifications and
  rejects 35 (including `#nodeAdded`, `#nodeDeleted`, `#preSave`, `#postSave`,
  `#preOpen`, `#postOpen`, `#preReset`), `id:` must be a `Name` rather than an
  integer, `NodeEventCallback` requires exactly two parameters or it silently
  registers and never fires, and `SceneEventCallback` does not exist on this
  release at all. `context_stats.eventsCapabilities` therefore publishes what
  actually bound on the running build, and `mcpCtxTick`'s identity check
  (object count, selection count, file path — every 8th tick, O(1)) covers the
  changes that have no notification: file > new, reset, merge, and a script
  editing the scene outside MCP.

  `src/ms/mcp_context.ms` is the data layer: nine domains (scene, selection,
  objects, materials, assets, animation, rigging, render, project), each built
  on demand, cached once, and tagged with `domain / revision / updatedAt /
  source / valid / supported / stale / buildMs / error`. `valid`, `supported`
  and `stale` are deliberately separate: a read that threw is not an API that
  is missing, and neither is the same thing as data older than the domain's
  last change. Nothing is cached that was not read, and a failed collector
  reports `valid:false` instead of a zero. Object
  classification goes through `mcpCtxSuperKind`, which normalises
  `superclassof` — measured here it answers `GeometryClass` but `shape`,
  `light`, `camera`, `helper` in lower case, which is why the existing
  `scene_statistics` had been reporting every one of 65 objects as `other`.

  `src/ms/mcp_ui.ms` is the in-Max panel ("Vino 3dsMax MCP", seven read-only
  pages over a WinForms `TabControl`), opened through `client_ui` or the
  `Vino3dsMaxMCP` macroScript. Four of the pages are the ones the client
  contract names -- Connection, Context, Events, Diagnostics -- and they are
  counters only. Scene / Selection / Assets are detail views backed by the
  context cache: Refresh never rebuilds, a separate Rebuild button does, and a
  detail page that has no current snapshot shows the previous one under an
  explicit `STALE SNAPSHOT` banner rather than an empty pane.

  Six tools join the catalog (384 -> 390): `context_get`, `context_refresh`,
  `context_stats`, `context_events`, `client_ui`, `client_status`, plus the
  `context` category, and an MCP resource `max://scene/context` with a
  `max://scene/context/{domain}` template, since a resource is the natural
  shape for "read the scene" and does not consume a tool slot.

- **`since` is a global revision, and the two counters behind it are documented
  in the code that uses them.** The first draft compared the caller's `since`
  (a global revision) against each domain's cache key. Those are different
  counters, so a domain that had changed once — key `1` while the global
  revision was already `40` — was reported as unchanged and the update was
  lost. Each domain now keeps `mcpCtxStamp` (the global revision at its last
  change, which is what `since` compares against) and `mcpCtxSent` (the stamp
  last delivered, so a domain the caller has never received is never skipped).
  `context_get` was verified end-to-end against the running scene: a material
  creation rebuilds `scene` and `materials` and skips the other seven; a
  selection change rebuilds `scene`, `selection` and `objects`.

- **`context_get`'s per-tool invalidation table is derived from the tool name,
  not a blanket guess.** `mcpEvAfterWrite` originally marked `scene + objects +
  selection` for every write, which invalidated three domains on every call and
  made the incremental path useless for the domains that matter. The catalog
  names tools `<prefix>_<verb><noun>`, so `mcpEvDomainsForMethod` maps all 55
  mutating prefixes (`mat` -> materials, `mod`/`poly` -> objects+selection,
  `rig`/`constraint` -> rigging+objects, and so on) and keeps the broad
  conservative set only for `execute_maxscript`/`execute_python` and unknown
  prefixes. `scene` stays unconditional: it holds `objectCount`,
  `selectionCount`, `currentFrame` and `modified`, and costs 0-1 ms to rebuild.

- **`src/python/maxmcp/context.py` stitches the incremental replies back into a
  complete snapshot.** `context_get(since=...)` returns deltas by design, which
  leaves every full-picture caller — the resource endpoint, a panel, an agent
  that just reconnected — to do the bookkeeping. `SceneContextCache` does it
  once, server-side: it never fabricates a section it has not read
  (`complete`/`missing` say which), it reports the bridge's revision rather
  than a local counter, it drops a stored section when the bridge sends that
  domain unreadably instead of serving a value just declared out of date, and a
  revision that moves backwards (Max restarted, bridge reloaded, another scene
  opened) clears the whole cache instead of mixing two sessions. Covered by
  `test/static/context_cache_test.py`.

- **The panel can now start the bridge.** The Connection page gains a
  Start / Restart button that calls `mcpNetStart()` directly from inside Max,
  with the live address, client count and up/down state on a label beside it.
  It only ever starts or restarts — there is deliberately no Stop, because the
  listener is the only channel a client has into Max. `bridge_restart`'s
  description now says the same thing instead of implying it can rescue a
  stopped bridge.

### Fixed

- **`bridge_stop` was a one-way door.** `mcpNetStop()` stops the 25 ms pump
  timer, closes the listener and sets `mcpRunning = false`; the pump is the
  only code that ever runs in Max, so once it is gone nothing can bring the
  listener back. The `bridge_restart` tool exists and `server.py` even treats
  its failure as expected, but the command has to travel over the socket that
  was just closed, so it can never arrive — measured here, every call after a
  stop returned `protocol_error` indefinitely and recovery required typing
  `mcpNetStart()` into the MAXScript Listener by hand. The panel button above
  is the in-product way back. Covered by `test/static/bridge_recovery_test.py`.
  The client half is covered separately by
  `test/static/bridge_reconnect_test.py`, which kills and restarts a fake peer
  on the same port and asserts the *same* `MaxBridge` object works again after
  exactly one new connection — the earlier attempt to test recovery by stopping
  the pump measured a one-way door, not a reconnect.
- **The naming-convention audit could not pass on its own new category.**
  Phase B's `context_get / context_refresh / context_stats / context_events /
  client_ui / client_status` were filed under category `context`, which
  `CATEGORY_DOMAIN_PREFIXES` did not declare, so
  `test/static/catalog_contract_test.py` reported six A1 violations. The
  category is now declared with both prefixes; violations 6 -> 0.
- **`rig_list_bones` could not see a Biped or a CAT rig.** The handler filtered
  on `(classof o) == BoneGeometry`, but a Biped adds 31 nodes of class
  `Biped_Object` and no `BoneGeometry` at all, so a fully rigged character
  returned `count: 0` without an error. Classification is now a shared
  `mcpBoneKind` that matches the class *name* (a class symbol raises on a build
  where the plugin is not loaded), rows gained `boneKind`, and the response
  carries a `kinds` breakdown. Live on 2022: 3 -> 34 bones after adding a Biped
  (3 bone + 31 biped), back to 3 after deleting it.
- **`doctor.py` reported every healthy install as "broken autoloader".** It
  parsed `local bridgeFile = @"..."` while `install.py` writes
  `mcpLoaderBridgeFile = @"..."`, so the target never matched.
  `parse_autoloader_target` now matches the shape and prefers a bridge-named
  variable; `test/static/doctor_loader_test.py` round-trips the installer
  template through it.
- **Every call invalidated the scene domain.** `mcpEvDomainsForMethod` seeded
  its list with `#("scene")`, so a pure read such as `context_stats` marked the
  scene domain dirty and bumped the revision a client uses for `since`. Reads
  now map to no domain at all and `mcpEvAfterWrite` records nothing for them;
  `execute_maxscript` still marks every domain, because a script can change
  anything and a conservative rebuild is cheaper than serving stale data.
- **The panel's Events page printed `undefined` in every cell.** `mcpEventsLog`
  returns an object (`count/total/revision/events`), not a bare array.
- **The Diagnostics page listed 18 probe rejections as failures.** A probe this
  build rejects is the probe working; wanted/notification failures, node
  callback failures and rejected probes are now reported separately.
- **`(mcpMaxYear())` in a string concatenation threw.** It returns an integer,
  so the Diagnostics page died half way through Environment on every refresh.
- **Exception text was unbounded.** `getCurrentException()` on a missing
  `polyop` member dumps the whole struct — about 6 KB — into the JSON response,
  the panel page and every context section. All four paths now go through
  `mcpErrText`, which flattens newlines and caps at 400 characters with the
  dropped length appended, so a truncated message cannot be mistaken for a
  complete one.
- **`as boolean` raised on a Boolean.** MAXScript cannot coerce `true` to
  `boolean`, so `(mcpGet w "valid") as boolean` threw and every "read a flag
  back" silently became `false`: `context_stats` reported `valid:false` for all
  nine domains right after a successful `context_get`. Reading booleans now
  goes through `mcpToBool`, and the same latent cast in the render domain
  (`rendSaveFile`) is fixed.
- **`scene_statistics` reported every object as `other`.** It compared
  `(superclassof o) as string` against `"Geometry"`, `"Shape"`, `"Light"` and
  friends, but the running build answers `GeometryClass` and `shape`, `light`,
  `camera`, `helper` in lower case — so not one comparison ever matched, and on
  a 65-object scene the tool returned `other: 65`. Classification now goes
  through `mcpSceneSuperKind`, which prefers the shared `mcpCtxSuperKind` from
  `mcp_context.ms` and keeps the same rules inline as a degraded path (falling
  back to `other` would just restore the bug). Same scene now reports
  geometry 43, shapes 4, lights 7, cameras 2, helpers 6, bones 3, other 0 —
  which agrees with `context_get`'s `objects` section field for field. Two
  related miscounts went with it: `systems` was fed from the bone counter (and
  so was always 0), and bones were counted as systems. `bones`, `particles`
  and `classification` are now reported separately.

- **The panel rendered as one wrapped paragraph.** MAXScript builds strings
  with `"\n"`, and a WinForms `TextBox` does not break lines on a lone LF — the
  page held character 10 between every row and still displayed as a single
  line. `mcpUiCrlf` normalises to CRLF on the way into the control. Found by
  screenshotting the open panel, not by reading the return value.

- **`execute_python` did not invalidate the context.** Both escape hatches are
  registered non-undoable and are the only read-only-path commands that can
  change anything; the dispatcher hooked `execute_maxscript` only, so Python
  code that edited the scene left clients serving a stale snapshot.

- **`mcp_events.ms` used backslash line continuations** in a log-message
  expression, which `scripts/verify.py` forbids. Rewritten as plain statements.

- **`mcp_ui.ms` carried a `…` character.** MAXScript reads `.ms` as ANSI, so a
  non-ASCII ellipsis in a truncation marker was a decoding risk; replaced with
  three dots.

- **Seventh static gate: `test/offline_lint_helper.py`.** No gate owned the
  Python source outside the catalog's import graph (`scripts/` and `test/`
  are never imported by the server), so a syntax error, a stray encoding or
  a name typo there only surfaced when someone happened to run that exact
  file. The new helper closes that gap offline -- no 3ds Max, no port, no
  registry: it parses every `.py` in the repo (syntax, strict UTF-8, no BOM,
  undefined names via AST with scope-insensitive bindings, unused imports as
  warnings), flags author-machine paths and `%ENV%` literals in code
  (comments and docstrings are masked with `tokenize` first, so documented
  example paths stay legal; standard install locations such as
  `C:\Program Files` are the platform contract and stay allowed), applies the
  Autodesk `.ms` encoding rule plus bracket/string balance to every
  MAXScript file (reusing the `ms_check.py` lexer, never reimplemented), and
  audits every catalog tool definition: bilingual descriptions present and
  not placeholders, parameter `type` spelled as one of the six JSON schema
  types, `default`/`enum` values matching the declared type (bool is not an
  integer), numeric-only `minimum`/`maximum`, known categories, no
  cross-module duplicate names. The first run caught one real pre-existing
  violation: `examples/maxscript/listener_cheatsheet.ms` carried Chinese
  examples as UTF-8 **without** BOM, which `fileIn` would mis-decode; it now
  ships with a BOM like the eight Chinese-bearing bridge modules.
  `scripts/verify.py` prints a new per-module distribution table (tools /
  mutating / read-only / dangerous per catalog module: 384 tools, 298
  mutating, 19 dangerous -- the same token set as the contract test's gate
  table) and runs the helper in-process, folding its violations and warnings
  into the global integrity result. The mandatory-check list is now seven
  no-Max gates (README, CHANGELOG, docs/BRIDGE_CONVENTIONS.md, dev skill,
  repo memory); the rules and rationale live in
  `docs/OFFLINE_LINT_GUIDE.md`.

- **Sixth static gate: `test/catalog_contract_test.py`.** The live regression
  script talks straight to the bridge, so the Python MCP layer (required
  validation, preset merging, type coercion, the `collapse_stack` alias) had no
  coverage. The new test drives the real `maxmcp` server over stdio against a
  MockBridge (port 8796, never 8765) and checks: (A) a per-tool static contract
  over all 384 tools — unique names, category prefix convention with a
  documented whitelist, bilingual descriptions, schema legality, preset keys
  limited to bridge-recognised keys, bridge methods registered in MAXScript
  (parsing reused from `registration_sync_test.py`), mutating-flag heuristic;
  (B) an output-only dangerous-tool gate table (19 mutating delete/remove/
  clear/collapse/reset/cleanup/optimize tools with confirm and undo status);
  (C) MockBridge payload assertions — minimal legal arguments per tool,
  required-parameter rejection without a bridge call, type coercion, and key
  regressions around the collapse gate and payload shapes. `--list` prints the
  case inventory without starting any service, `--json` emits a pure machine
  report, scratch files live in `.tmp-contract/` and are removed unless
  `--keep-tmp`. Result: 384 tools checked, 0 violations, 580/580 payload cases
  passed. The "mandatory checks" list is now six gates (README, CHANGELOG,
  docs/BRIDGE_CONVENTIONS.md, repo memory).

### Changed

- **`render_batch` no longer lies about missing cameras.** A job whose `camera`
  name does not resolve used to fall back to rendering the active viewport and
  report `written:true`. It now returns `written:false` with
  `reason:"camera not found"`, is counted in the new top-level `failures` array,
  and the rest of the batch keeps running. A render that throws or produces no
  file likewise carries a `reason` instead of a silent `written:false`. An
  omitted `camera` still renders the active viewport. Catalog description
  updated.
- **`cam_get` reports focal length honestly.** `focal_length` only exists on
  Physical cameras; every other camera class used to get the catch default
  `0.0`, pretending the read had succeeded. Non-Physical cameras now return
  `focalLengthSupported:false`, `focalLength:null` and an explanatory `note`
  (new `msg.focal_physical_only`). Catalog description updated.
- **One guarded collapse path (D4).** `collapse_stack` is now a controlled
  alias of `mod_collapse`: the catalog entry bridges to `mod_collapse` and
  requires `confirm=true`, so the previously unguarded collapse path is gone.
  The duplicate `mcpH_collapse_stack` handler and its `mcpRegister` were
  removed from `mcp_poly.ms` (MAXScript registered commands 354 → 353).
  `mod_collapse` stays the main entry; its behaviour is unchanged.

### Fixed

- **The MCP pump replayed the request it was already running
  (`EXCEPTION_STACK_OVERFLOW` in every slow tool).** `mcpProcessBuffer`
  published the remaining connection buffer only *after* dispatching a line.
  Commands that pump the Windows message queue -- `exportFile`, render, bake,
  `completeRedraw` -- let the WinForms pump timer fire while that line was still
  in `cn[3]`, so the nested tick re-read it, ran the same command again and
  recursed until the thread ran out of stack. Every exporter appeared broken
  ("stack overflow AFTER the file was written", which is what the
  file-exists recovery workaround was papering over), Max sometimes died
  outright, and the extra responses poisoned the stream ("out-of-order reply").
  Two independent fixes: the remaining buffer is now published *before* the
  dispatch, and `mcpNetPump` is a thin re-entrancy guard around
  `mcpNetPumpInner` (`mcpPumpBusy`, cleared on every path and reset by
  `bridge_restart`/`bridge_stop`). Measured after the fix: fbx / obj / stl /
  abc / 3ds all return `written:true` with no `recovered` flag, no log error,
  Max alive.
- **`import_*` reported "0 imported" when objects were already in the scene.**
  The added-object diff compared *names*, but on a name collision the FBX
  importer keeps the imported name and renames the node that was already there
  (`sw_box` -> `sw_box001`) -- so the two name sets overlapped completely while
  21 objects had in fact arrived. The diff now runs on node handles
  (`getHandleByAnim`), and an import that adds nothing but does not throw
  reports `updatedInPlace:true` with its own message instead of a bare `0`.
- **`mat_set_map_slot` / `mat_get_map_slot` wrote the map into the colour.**
  `"diffuse"` was passed straight to `setProperty`, which on a Standard material
  resolves to the Diffuse *colour*, and Max answered "unable to convert Checker
  to Point3". Legacy materials keep their maps in numbered sub-texmap channels,
  not in `diffuseMap` properties, so resolution is now: real map property ->
  `slot + "Map"` / `slot + "_map"` -> per-class alias (`base_color_map`, ...) ->
  sub-texmap channel table (diffuse 2, bump 9, opacity 7, ...). Both handlers now
  report where the map landed (`"channel 2"` in the result), and an unknown slot
  fails with the class name instead of a conversion error.
- **`rig_skin_*` used skinOps entry points that do not exist on 2022.**
  `getBoneName` wants three arguments (skin, index, useXref) and the two-argument
  call was swallowed by a `catch()`, so every vertex in `rig_skin_weight_table`
  had an empty bone name; `getVertexWeightBone` does not exist at all (the real
  name is `GetVertexWeightBoneID`); `autoWeight` does not exist either, so
  `rig_skin_auto_weight` was a silent no-op; `setWeight` takes two arguments and
  works on the panel selection, so `rig_skin_set_weight` never set anything.
  Auto weights are now computed from the distance of each vertex to every bone
  segment (`GetStartPoint`/`GetEndPoint`, nearest two bones, inverse square) and
  applied with `ReplaceVertexWeights`; single weights read-modify-write the same
  call and treat the requested value as authoritative (1.0 really does clear the
  other bones). `rig_skin_add_bone` accepts `bone` or `bones`, reports
  `notFound`, and no longer dies with "unknown property: name in undefined".
- **`render_preview` called `makePreview`, which 3ds Max 2022 removed.** It now
  calls `createPreview` (2020/2021 keep using `makePreview`), and because
  `createPreview` has no output-path argument and always writes
  `<getDir #preview>\<scene>_preview.avi`, the file that appears in the preview
  folder is detected and copied to the requested path. Result carries
  `entry: "createPreview"`.
- **`viewport_stats` reported 0x0 for every viewport.** `getView <n>` does not
  exist in 2022, so every size read was swallowed. Sizes now come from
  `viewport.getViewportDib index:n` (falling back to `getViewSize()` for the
  active view), plus the per-view `active` flag.
- **`export_3ds` rejected a working exporter.** The `.3ds` writer is built into
  Max and its plugin class name is not resolvable from MAXScript
  (`Max3dsExporter` / `ThreeDSExporter` both report "does not exist" while
  `exportFile` writes the file), so the class probe is gone; `exportFile` by
  extension is the only truthful test.
- **`list_max_classes` enumerated almost nothing.** `geometry.classes` and
  friends raise "unknown property" (the lowercase listener names are node
  collections); only superclass *class values* carry `.classes`. Buckets are now
  `GeometryClass / Shape / Light / Camera / Helper / System / SpacewarpObject /
  Material / TextureMap / Modifier / Filter / Atmospheric / ReferenceTarget`
  (measured 1230 classes, a search for "Box" now returns `Box`), and
  `mcpClassBuckets` is called instead of being iterated as a value.
- **`rig_create_bone_chain` created `count - 1` bones.** `"count": 3` produced a
  two-bone chain; the chain is now cut into `count` segments.
- **Bake paths carried a double separator.** A folder passed with a trailing
  slash produced `C:/out/\name.png`; `mcpBakeJoinPath` trims before joining.
- **Unknown parameters were dropped silently.** A caller that spelled `names`
  for `objects` got a cheerful `ok` and nothing selected, and the *next* tool
  failed with "nothing is selected". `_resolve_argument_names` now maps the
  caller's spelling onto the declared parameter (exact, case-insensitive, an
  alias group `objects/names/objs/items`, then a close match) without changing
  the value's shape, and every correction or ignored key is reported in the
  result as `parameterNotes`.
- **`bridge_restart` / `bridge_stop` reported a failure.** Both close the socket
  the reply would travel on, so the client saw "connection dropped". They now
  return `ok:true` with an explanatory note and the next call reconnects.

- **3ds Max 2022 (2020+) compatibility sweep, live-verified.** A full pass over
  a real 3ds Max 2022 install turned up a class of failures that all shared one
  shape: an API that no longer exists, plus a `catch()` that hid it. Fixed, each
  confirmed on the live bridge:

  - **Bake (`bake_texture`/`bake_ao`/`bake_normals`/`bake_lighting`) was
    silently doing nothing.** It wrote `node.RenderToTexture.*`, a property that
    does not exist, so every field assignment no-op'd and `rktBatchRender` never
    produced a file -- while the tool still answered "烘焙完成" with
    `written: []`. Rewritten with two back ends: the Bake To Texture interface
    (`BakeToTexture.addMap` / `.bake()`, 3ds Max 2021+, `route: "btt"`) and the
    classic `iNodeBakeProperties` + `render rendertype:#bakeSelected` path for
    2020 and older (`route: "legacy"`). The bake now switches to the Scanline
    renderer for the duration and restores the previous one afterwards, because
    the standard bake elements are Scanline-only: attaching them while Arnold is
    active throws in a loop that spawns modal MAXScript error dialogs and wedges
    the UI thread. Objects without a UV channel get a box-projected UVW Map
    first (`BakeToTexture.addMap` refuses to run otherwise). Bake maps are always
    released afterwards -- a stale registration pointing at a deleted node
    crashes Max on the next `bake()`. Zero written files is now an error
    (`err.bake_no_output`) that names the route, the folder and the first
    failure, instead of a success with an empty list.

  - **`import_fbx` could permanently kill the bridge.** The FBX importer ignores
    `#noPrompt` when no import mode is configured and opens up to three
    interactive dialogs; they block the main thread the bridge runs on, so every
    later call hung until Max was killed by hand. The handler now pre-sets the
    importer options (`FBXImporterSetParam` for Mode/ImportContent/ShowWarnings/
    FillTimeline/Cameras/Lights/Skin/Shape/Animation, each best-effort because
    the names differ per release) which makes it import silently. Imports also
    report what actually arrived (`imported`/`count`) instead of a bare "done",
    and a throw that added nothing is a real error again.

  - **Modal-dialog watchdog (`maxmcp.dialogs`).** Any modal box -- MAXScript
    error, FBX prompt, render report, the WinForms "unhandled exception" box --
    blocks the thread the bridge answers on, so one bad call used to end the
    session. The client now dismisses known blockers when a request times out,
    gives the pending command a grace window, and reports which dialogs it
    closed (`bridge.dialogs_dismissed`). Crash dialogs (`Application Error`) are
    deliberately left alone: the process is already gone and closing the box
    would hide it. Windows-only, no-op elsewhere; `python -m maxmcp.dialogs
    --list` shows what is currently open.

  - **`proboolean` never worked, and `boolean_operation` ran the wrong
    operation.** The old code called `proBoolean.SetOperation(...)` etc., but
    the `proboolean` global is not that interface in 2022 -- the real entry point
    is the PolyBoolean interface on the class:
    `ProBoolean.createBooleanObjects <A> #(<B...>) op addMethod matMethod`, where
    op is 0=union 1=intersection **2=subtraction** 3=merge. The old mapping used
    1 for subtract and 2 for intersect, so "subtract" silently intersected. Both
    tools now share one implementation, report `engine: proboolean|boolean2`, and
    fall back to `boolean2` explicitly; the old code wrapped each `boolean2` call
    in an empty `catch()`, so a failed boolean still reported success.

- **Crash timeline wording in docs (D8 follow-up).** "18 crashes since
  2026-10-15" corrected to "18 within the event-log window (first
  2026-10-17 10:54:44; 14 on 2026-10-18 00:00–01:29)": the retrieval window
  started 10-15 but every crash is from 10-17 onward. Added the qualifier that
  the 10:54 first crash happened while the user's previous instance was still
  running (suspected single-instance duplicate launch) and that crash-free-
  instance-free continuous failures began 10-17 23:42 (D5 root cause open).

### Added

- **Live regression suite for the recent fixes** — `test/modeling_ext_test.py`
  gained six groups (17 cases) covering the light class-name fix, all 8 spline
  creators, `create_teapot smooth=true`, `create_pyramid depth=50`, the collapse
  confirm gate on the shared `mod_collapse` path plus a static check of the
  `collapse_stack` alias wiring, and unchanged `mod_collapse` behaviour. Every
  case builds and deletes only its own `__mcp_reg_*` objects, the run aborts
  with exit code 3 when the scene is not empty, and `--list` prints the case
  list without connecting to Max (CI / static self-check).

### Fixed

- **Spline creation tools were dead on arrival (D3).** `create_rectangle`,
  `create_circle`, `create_ellipse`, `create_ngon`, `create_donut`,
  `create_arc`, `create_helix` and `create_text` never sent the `class` the
  shared `mcpH_create_spline` handler requires (no `preset={"class": ...}`,
  unlike the primitive wrappers), so every call failed with
  `err.missing_param: class`. Each tool now carries its class preset.
- **`smooth=true` could not enable smoothing (D3).** The generic primitive
  creator coerced every dimension param with `mcpNum`; a JSON `true` is not a
  Number in MAXScript, so it degraded to `0.0` (false). Boolean props now go
  through `mcpBool`.
- **`create_pyramid` ignored its documented `depth` parameter (D3).** `depth`
  was missing from `_prim_props` and from the handler's dimension list; added
  to both.
- **Penumbra arithmetic leaked sentinel defaults (D2).** `light_create` /
  `light_set` computed `falloff` from the `-1.0` / `0.0` "not supplied"
  defaults when only `penumbra` was given, producing `penumbra - 1` /
  `penumbra` instead of `hotspot + penumbra`. The base now falls back to the
  light's current hotspot.
- **`Target_Spot` / `Target_Directional` are not 3ds Max class names (D2).**
  `light_create` with `type=spot|directional|target_directional` failed with
  `class_missing` on every call (live-tested 2026-10-17 before the local Max
  environment broke). The real MAXScript classes are `Targetspot` and
  `Targetdirectionallight` (MAXScript class names are case-insensitive but
  never contain underscores); both constructors and their `mcpEnsureClass`
  guards now use them.

## [1.2.0] - 2026-10-18

Vision feedback, a modeling/poly extension round, automatic UI language, and a
repository consolidation into `src/python` + `src/ms`.

### Added

- **Vision tools that return the picture itself** — `vision_capture`,
  `vision_views` and `vision_preview` (`mcp_vision.ms`, 499 lines). The
  MAXScript side parks base64 frames in the result's `_images` array and
  `server._split_images` turns them into real MCP image content blocks
  (`protocol.image_content`). A JSON reply can say `{"ok": true}` while the box
  is inside out; a screenshot cannot lie. Long edge downscaled to 800px by
  default; `vision_views` sweeps standard views as separate images (a mosaic
  would be downscaled as a whole and lose per-cell detail).
- **Modeling extension module** `mcp_modeling_ext.ms` (575 lines):
  `mod_toggle`, `mod_collapse` (requires `confirm=true`), `poly_get_selection`,
  `poly_select`, `poly_get_elements` — plus the `mod_chamfer` preset wrapping
  `mod_add`. Catalog 378 → **384** tools (modeling 77 → 83, pipeline 51 → 54).
- **Automatic UI language.** The bridge derives its message language from the
  Max user-config folder name (`ENU` → en, `CHS`/`CHT` → zh) via
  `mcpMaxLanguageCode()` / `mcpDetectLanguage()`; `language=auto` is the
  installer default and the server re-syncs at `initialize` and after the
  first successful tool call. `set_language "zh"|"en"` pins the choice.
- **Static test harnesses** (`test/`): `ms_check.py` (encoding/BOM, bracket
  balance, `obj.Method().Member` compile-error pattern, undefined mcp*
  symbols), `registration_sync_test.py` (catalog ↔ `mcpRegister` ↔ deployed
  ENU/CHS trees), `modeling_ext_test.py` (repeatable live test, starts from
  `scene_new`).

### Changed

- **Repository consolidation.** The project now lives at
  `D:\Workspace\MCP\3dsmax-mcp` with a `src/python/maxmcp` (server) +
  `src/ms` (bridge) layout; the previous iteration's tree is archived under
  `backup/20261018_project_merge_before/` (git history included).
- **Deployment is byte-exact.** `install.py` copies files verbatim instead of
  normalising line endings: the repo holds exactly the bytes that run in the
  field (the `.ms` tree is deliberately mixed CRLF/LF, both shapes proven), and
  `registration_sync_test.py` fails when the deployed trees drift from the
  repo. `.gitattributes` pins `*.ms -text` so git never rewrites them either.
- **Logging autoloader.** The generated `startup\3dsmax-mcp-bridge.ms` now
  appends to `<temp>\3dsmax-mcp\loader.log` (userScripts fallback), so "did
  the autoloader even run?" is answerable without the Listener.
- Bridge `.ini` (`port` / `language` / `autostart`) is rewritten on every
  install so the port can never go stale against the server config.

### Fixed

- `mcp_vision.ms` temp paths no longer use `System.Guid` printed via
  `as string` (it yields the literal `dotNetObject:System.Guid`, whose colon
  is not a legal path character) — now a formatted timestamp plus a random
  tail, digits only.
- `set_language` persists language only; runtime `--port` / `--profile`
  overrides never write back to `~/.3dsmax-mcp/config.json`.

## [1.1.0] - 2026-09-19

Compatibility with the wider MCP client ecosystem — in particular Chinese AI
clients and cloud-side agent platforms — plus automatic language selection.

### Added

- **Streamable HTTP transport** (`POST /mcp`, spec 2025-03-26+), so clients that
  cannot launch a local process can reach the server by URL. Cloud agent
  platforms (智谱 BigModel, 阿里云百炼, web consoles) register MCP servers this way
  and previously had no way in.
- **Legacy HTTP + SSE transport** (`GET /sse` + `POST /messages`), the
  2024-11-05 shape still spoken by older Cline builds and several Chinese
  platforms. Both are served from one process; `--transport http` enables them
  and `--transport both` runs them alongside stdio.
- `--http-host` / `--http-port` / `--http-token` / `--http-path`, and the matching
  `MAXMCP_HTTP_*` environment variables plus config.json keys.
- Bearer-token gate for the HTTP endpoint, CORS headers for browser-based
  clients, `GET /health` probe, and batch (JSON-RPC array) request support.
- **Automatic language detection.** The bridge reads the 3ds Max UI language from
  the localisation folder (`ENU` / `CHS` / `CHT` / `JPN` …) and mirrors it, so a
  Chinese Max gets Chinese and an English Max gets English from a single install.
  `set_language` now accepts `auto` in addition to `zh` / `en`; `auto` is the new
  installer default. An explicit `set_language("zh"|"en")` pins the choice.
- `bridge_status` / `get_language` now report `maxLanguage` and `languagePinned`;
  `set_language` reports the mode it ended up in.
- `mcpSelfTest()` gained a UI-language check (13 checks now).
- Installer registers **WorkBuddy, Claude Code, Windsurf, Cline and Roo Code** in
  addition to Cursor and Claude Desktop, all driven from one client table that
  `doctor.py` reuses so the two cannot drift. Client configs are now backed up to
  `.bak` before every write.
- `install.py --http-port <n>` registers URL-based client configs and writes
  `%LOCALAPPDATA%\3dsmax-mcp\start-http.bat` to keep the endpoint alive.
- `install.py --list` now shows the state of every known client config.
- The bridge `.ini` is rewritten on every install instead of only when missing,
  so the port and language can no longer go stale, and `install.py` writes the
  matching `port` / `language` / `tool_profile` into `~/.3dsmax-mcp/config.json`.

### Fixed

- **`set_language` persisted run-scoped CLI overrides.** Saving the config wrote
  the whole object, so a debug run with `--port 8791` baked that port into
  `~/.3dsmax-mcp/config.json`; the next launch then hunted for the bridge on the
  wrong port and every call failed. `Config.save()` now takes an optional key
  filter and `set_language` persists only `language`. Covered by a regression
  test in `scripts/test_e2e.py`.
- `doctor.py` was unusable: an editing slip had merged `try:` into the
  `load_manifest()` signature (SyntaxError on every run).
- `python -m maxmcp --help` used to start the stdio loop instead of printing
  usage.
- Doctor no longer warns about clients that are simply not installed, and the
  "register them with…" hint it printed was not a runnable command.

### Changed

- `MaxMcpServer.handle_message` was split into a transport-independent
  `dispatch()` that returns the response, which is what let stdio, Streamable
  HTTP and SSE share one code path (and one error-shaping path).
- `scripts/verify.py` now also checks that every bridge symbol referenced by
  `examples/maxscript/listener_cheatsheet.ms` still exists, so renaming a bridge
  function cannot silently rot the documentation.
- `scripts/test_e2e.py` covers the HTTP transport (session id, batch,
  notification 202, legacy SSE, token gate) and auto-language behaviour, and runs
  every server subprocess with an isolated `MAXMCP_HOME` so a test can never
  read or rewrite the developer's real config.

## [1.0.0] - 2026-09-19

Initial release.

### Added

**Architecture**

- Pure **MAXScript bridge** — no `pymxs`, no dependency on the Python embedded
  in 3ds Max. Works on 2020 (Python 2.7) and every later release alike.
- Bridge listens on a local TCP socket via `TcpListener` and pumps it with a
  `WinForms Timer` **on the main thread**, so scene access is never cross-thread.
- Python MCP server is **stdlib only** (`>=3.8`), so the installer ships a single
  self-contained folder and never touches the user's Python environment.
- **ASCII-only wire protocol**: newline-delimited JSON with non-ASCII characters
  escaped as `\u00XX` ANSI code-page bytes, round-tripped by `wire.py` on the
  Python side. Verified end to end with Chinese, Japanese and control characters.

**Tools — 375 across 8 categories**

- `system` (33): bridge control, handshake, capability discovery, MAXScript/Python
  escape hatches, undo transactions, units and time configuration, reflection.
- `scene` (17): new/open/save/save-as/merge, layers, asset listing, missing-asset
  detection and relinking.
- `files` (8): text read/write, directory listing, copy/delete/make-dir, file info.
- `objects` (61): primitives, splines, transform/align/mirror/pivot, hierarchy and
  parenting, groups, selection, hide/freeze, clone, array, boolean and ProBoolean.
- `modeling` (77): the editable-poly surface suite (vertex/edge/face), modifier
  stack management plus 30+ modifier wrappers, loft/sweep/path-deform.
- `shading` (69): material read/write/assign, PBR / Arnold / V-Ray / Corona /
  **FStorm** materials, map nodes, material libraries, UVW map and Unwrap,
  lights, cameras, environment and exposure.
- `animation` (59): keyframes and curves, controllers and expressions, constraints,
  bones and IK chains, Skin weights, Morpher.
- `pipeline` (51): render engine and settings, still / frame-range / batch renders,
  render elements, viewport capture, baking (AO / normals / lighting / maps),
  import and export (FBX / OBJ / glTF / USD / ABC / STL / 3DS) with engine presets.

**Bilingual, hot-swappable**

- Every tool carries `description_zh` and `description_en`; parameter descriptions
  are inlined as `中文 | English`.
- `set_language` is an ordinary tool call, so an agent can flip language at runtime
  without a restart — `tools/list` reflects the change immediately.
- Bridge-side messages (banner, errors) are bilingual too, driven by
  `3dsmax-mcp.ini`.

**Undo safety**

- Every tool declares `undoable` in the bridge registry; the dispatcher wraps those
  calls in `theHold` automatically, so agent actions are individually undoable.
- Explicit `begin_undo` / `end_undo` / `cancel_undo` let an agent collapse a whole
  modelling sequence into a single user-visible undo step.

**Tool profiles**

- `core` (119), `modeling` (196), `lookdev` (188), `animation` (178),
  `pipeline` (170), `full` (375) — trim the advertised tool set to fit a context
  budget without changing what the bridge can do.

**Installer and tooling**

- `scripts/install.py` — discovers every 3ds Max user-script directory across 11
  localisations, installs the bridge plus a `scripts/startup` autoloader, installs
  the server to `%LOCALAPPDATA%\3dsmax-mcp`, and registers MCP clients
  (Cursor, Claude Desktop) with a merge-not-overwrite JSON edit. Supports
  `--list`, `--uninstall`, `--port`, `--language`, `--profile`, `--client`, `--yes`.
- `scripts/doctor.py` — checks the whole chain (Python → server package → bridge
  files → autoloader → Max running → port → live handshake → client config) and
  prints an actionable verdict.
- `scripts/verify.py` — static integrity harness: bracket balance, banned MAXScript
  constructs, tool ↔ handler one-to-one matching, and bridge module load list.
- `scripts/test_e2e.py` — drives the real MCP server against a `MockBridge`, covering
  `initialize`, `tools/list`, `tools/call`, Chinese round trip, error propagation
  and language switching.

**Max-side self-test**

- `mcp_selftest.ms` runs 13 checks inside 3ds Max: JSON round trip, Chinese round
  trip, UI-language detection, object creation, `theHold` behaviour, TCP listener
  state, and more. Callable from the Listener via `mcpSelfTest()` or from an agent
  via `bridge_selftest`.

### Known limitations

- Windows only.
- Live verification requires 3ds Max to be restarted (or the bridge manually
  `fileIn`-ed) after installation, because `scripts/startup` is only scanned at
  launch.
- The bridge pump is a UI timer. A single long blocking operation (for example a
  large batch render) will stall other tool calls until it returns; raise
  `MAXMCP_TIMEOUT` accordingly.
- `struct`, lambdas and closures are deliberately avoided in the MAXScript sources
  because they cannot be validated without a live Max session. `verify.py` enforces
  this.

[1.0.0]: https://github.com/your-org/3dsmax-mcp/releases/tag/v1.0.0
