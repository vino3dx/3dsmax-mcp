# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **False parameter promises and a boolean-outcome blind spot (Stage 6).** A
  catalog entry promises "this argument does something".  When the handler never
  reads it, the agent sends the flag, the call succeeds, and the setting is
  silently dropped.  A new static audit compares both sides for all 338
  statically readable tools.
  - **`scene_new.keepScene` now works.** It was advertised since the tool
    existed and never read: every call reset units, frame rate and render size
    along with the objects.  The handler now records those four settings before
    `resetMaxFile` and puts them back, returning `kept` so the caller can see
    what survived.
  - **`rig_skin_add_bone.rigid` now works.** The description promised a
    rigid/weighted start mode; the handler always passed `0`.  `skinOps.addBone`
    now receives the flag (kept as 0/1 for version tolerance).
  - **`light_set_sun.timeOfDay` was removed.** Nothing behind it: there is no
    portable time-of-day property across Daylight/Sunlight/IES_Sun systems, so
    the honest move was to stop advertising it and keep azimuth/altitude.
  - **`created: true` / `deleted: true` now decide.** Enumeration keys were read
    only in their list form, so `scene_new` and `delete_file` answered
    `missing_success` after doing exactly what they were asked.  Both forms are
    now read by value, the same way receipt fields already were.
  - **The other direction is now a report, not a guess.** The same audit prints the
    keys a handler reads that the catalog does not declare (8 today: two aliases,
    five shared-handler unions, one false positive), and `docs/PARAMETER_SURFACE.md`
    explains each one and when to declare or drop it. `bake_ao` / `bake_normals` /
    `bake_lighting` gained the `elements` and `template` arguments that
    `bake_texture` already had.
  - `test/static/param_contract_audit.py` (Static) fails when a declared
    parameter is never read, skipping the two handler shapes a static scan
    cannot follow (key lists in the primitive creators, `mcpPairs params`
    pass-through in the `mod_*` family) - a false positive there would push
    someone to delete a real parameter.
  - `test/static/i18n_audit.py` (Static) checks both message tables: a missing
    `i18n.t()` key or `mcpMsg` / `mcpFail` key is returned to the user as the key
    itself, so a typo leaks `msg.ok` into a message instead of failing a test.
    0 missing on both sides today (8 Python calls, 31 MAXScript call sites).
  - `object_state_test.py` covers `scene_new` with and without `keepScene`, and
    `outcome_declaration_test.py` pins both enumeration forms.

- **Honest answers from per-object state operations (Stage 5).** The biggest
  remaining lie in `src/ms` was structural: a handler wrapped the real call in
  `try (...) catch()`, returned `{message: "OK"}`, and a batch where every object
  refused looked exactly like one where every object worked.  This stage
  replaces that pattern with read-back, in 59 tools.
  - **Visibility and freeze report the scene, not the request.**
    `hide_objects` / `unhide_objects` / `unhide_all` / `freeze_objects` /
    `unfreeze_all` now read `isHidden` / `isFrozen` back through
    `mcpSplitByFlag`, so `hidden` means "the scene agrees this is hidden" and
    `failures` names the ones that still disagree.  The `*_all` variants record
    the state *before* the call, so `thawed` is not a dump of the whole scene.
  - **Transforms run per object.** `mirror_object`, `set_pivot`,
    `reset_transform`, `snap_objects_to_grid`, `unparent_objects` and
    `spline_set_points` apply one object at a time and report `applied` /
    `failures`: a locked node can no longer abort the rest, and it can no longer
    hide inside "Done.".
  - **Group heads say whether they opened.** `open_group` / `close_group` name
    the objects that refused instead of swallowing `setGroupOpen`.
  - **Material setters name what landed.** `mat_set_pbr` and `mat_set_emission`
    return `applied` / `skipped` per property and fail when nothing landed;
    `mat_delete` reads back whether the material is still referenced by any
    object or slot; `mat_set_slot`, `mat_set_property`, `mat_set_specular`,
    `mat_set_opacity`, `mat_set_sub_material`, `mat_rename`, `mat_duplicate`,
    `mat_set_map_slot`, `map_set_bitmap_path` and `mat_library_*` declare
    `success` after their own `mcpFail` guards.
  - **`mcpMapInfo` declares success once** instead of nine map creators each
    returning an unreadable `{class, filename}`.
  - **Render settings read themselves back.** `render_set_resolution`,
    `render_set_output` and `render_set_frame_range` echo the state the renderer
    will actually use (`renderWidth`, `rendOutputFilename`, `rendTimeType`), so a
    clamped size or an ignored path is reported now, not at frame 1.
  - **Timeline and render elements too.** `anim_goto_frame` reads
    `currentTime.frame` back (the timeline clamps at the scene range), and
    `render_element_remove` / `render_element_set_output` / `viewport_set_layout`
    declare `success` after their own guards.
  - **Lights and cameras report per-property.** `light_set` / `cam_set` return
    `applied` / `skipped` (light classes disagree about `multiplier` vs
    `intensity`, cameras about `f_stop`), and fail when nothing landed.
  - **`set_units` reads the scale back**, because a clamped scale silently
    makes every later dimension wrong, and rejects an unknown `displayType`
    instead of ignoring it.
  - Coverage: readable outcomes went 219 → **282 of 293** mutating tools; the
    remaining 11 are listed by `test/static/outcome_audit.py` and are either
    escape hatches (`execute_python`), playback (`anim_play`), wire/IK relations,
    or viewport state with no portable read-back.
  - Tests: `test/static/object_state_test.py` (Offline, 10 scenarios) drives
    hide/freeze/unhide-all/reset/snap/group operations through the real TCP
    stub with a `reject_ops` hook, so partial success and "empty receipt is not
    success" are proven, not assumed.

- **Workflow habits and evidence gaps (Stage 4).** Stage 3 built the machinery;
  this stage makes it the default and closes the two rows of the capability
  matrix that had no offline evidence.
  - **Receipt-shaped outcomes (`runtime.declared_outcome`).** Reliability mode
    already read `{applied, failures}`; it now also reads the receipts the
    handlers were already emitting: `saved` / `opened` / `merged` (non-empty
    path), `written` / `reset` / `copied` / `renamed` (boolean), `group` /
    `layer` (non-empty name), `moved` / `ungrouped` / `children` (non-empty
    list), and `results` joins the enumeration keys. Values are read, not
    presence: `{saved: ""}` and `{written: false}` are failures. `message` is
    never evidence — every handler returns one, including the ones that did
    nothing. This fixes `scene_save`, `scene_save_as`, `scene_open`,
    `create_layer`, `group_objects` and `export_*` being reported as
    `missing_success` in the core profile even though they worked.
  - **Honest handler verdicts (`src/ms`).** `execute_maxscript` now says
    `success: true` when the script finished (it throws on error, so a reply
    means it ran); `mat_set_diffuse` and `light_create` do the same after their
    own `mcpFail` guards; `rename_object` reports `renamed: n.name == newName`
    because Max silently keeps the old name on a collision; `ungroup_objects`
    collects `ungrouped` / `failures` instead of swallowing every error and
    answering "ok".
  - **Verification strength named honestly.** New verifier `payload_field`
    compares a value the tool reported (`saved`, `written`, `path`, `moved`)
    against the request. It is weaker than a read-back and is documented that
    way — for outputs that cannot be re-read without live Max it is the honest
    option, and it still catches "wrote to the wrong directory".
  - **`scene_snapshot` baselines across sessions.** `saveBaseline` writes a
    versioned JSON file (`schemaVersion: 1`, `createdAt`, `document`);
    `baselineFile` reads it back and diffs. A missing, corrupt or wrong-version
    file fails loudly instead of silently starting a new baseline, and the path
    must be absolute with a `.json` suffix so a typo cannot land on a `.max`.
  - **Recovery says why.** `recovery.diagnosis` is one of `scene_readable` /
    `bridge_unreachable` / `scene_unreadable`, with `read_error` and
    `suggest_actions`; a dead bridge and an unreadable scene no longer look the
    same (both used to be a null object count).
  - **MCP `instructions` now lead with the habit** (zh/en): snapshot a baseline
    before changing anything, run three or more dependent steps through
    `workflow_run` with `verification`, and report unverified results as
    unverified. The `execute_maxscript` fallback is narrowed to "only when no
    tool covers the job, and say why".
  - **Audit instead of hope.** `test/static/outcome_audit.py` reads every
    `mcpH_*` handler (following `mcpRegister` and helper calls), reports how
    many mutating tools declare a readable outcome (282/293), and fails if a
    tool used by a standard workflow cannot be read. `outcome_declaration_test.py`
    pins the reading rules, including "message is never evidence".
  - Tests: `workflow_scene_test.py` grew to 22 scenarios (organisation, ungroup
    receipts, save/export, overwrite guard, unknown verifier, baseline file
    round-trip), `workflow_engine_test.py` to 18 (recovery diagnosis).

- **Agent scene workflows — `workflow_run` + `scene_snapshot` (Stage 3).** The
  capability gap was never "more tools": it was that a 15-step scene build had no
  way to say *what was supposed to happen*, *what actually happened*, or *what is
  safe to do next*. Two Python-side tools (`local=true`, no new MAXScript
  commands, 384 -> 386 tools) close it:
  - **`workflow_run`** executes an ordered list of tool calls (`workflow` for a
    built-in one, or explicit `steps`). Every step may declare `verification`
    (read-back only), `depends_on`, `on_failure` (abort/continue), `optional` and
    `retry` (never/transport). The reply carries a per-step record — `execution`
    (`execution_success` / `execution_failed` / `execution_skipped` /
    `execution_interrupted`), `verification`
    (`verification_passed` / `verification_failed` / `verification_unavailable`),
    `status` (`success` / `verification_failed` / `failed` / `skipped` /
    `interrupted`), retry log, `retry_blocked`, `recovery` — plus the whole-run
    `status` (`success` / `partial` / `failed` / `interrupted`), the before/after
    `diff` and an `expectation` block. `partial` keeps `success:false`; it is not
    reported as a tool error unless a verification contradicted the scene or a
    declared goal failed.
  - **`scene_snapshot`** documents one real scene read (`nodes`, `selection`,
    `complete`/`truncated`/`partial_nodes`/`missing_fields`/`handles_unique`) and
    diffs it against a cached baseline (`added` / `removed` / `modified` /
    `renamed` / `identity_uncertain` / `unknown` / `selection`).
  - Built-in workflows: `basic_scene` (10 steps), `model_processing` (10),
    `material_look` (7) — `success` with every step verified on the stub bridge.
  - **Operation verification (`maxmcp/verify.py`).** 12 read-back verifiers
    (`read_ok`, `exists`, `absent`, `count`, `transform`, `material`, `modifier`,
    `class`, `face_count`, `selection`, `payload_number`, `image`; Stage 4 added
    the receipt-level `payload_field`, which is documented as weaker than a
    read-back). Execution
    success and goal attainment are separate claims: `verification_unavailable`
    is never folded into `passed`, and an unknown verification kind is refused
    instead of silently ignored.
  - **No automatic retry for anything that is not idempotent.** Only a transport
    failure on a read-only/idempotent step may be replayed once
    (`IDEMPOTENT_MUTATIONS`); clone/delete/create/relative transforms answer
    `retry_blocked: non_idempotent_operation`, `execute_maxscript` /
    `execute_python` are never retried under any declaration. Every failed step
    re-reads the scene (`recovery.automatic_retry: false`) and leaves the retry
    decision to the caller.
  - Tests: `test/static/workflow_engine_test.py` (Static, 17 scenarios) and
    `test/static/workflow_scene_test.py` (Offline, real TCP stub + fake scene,
    16 scenarios). Docs: `docs/AGENT_WORKFLOW_CAPABILITY.md`,
    `docs/WORKFLOW_EXECUTION_MODEL.md`, `docs/SCENE_SNAPSHOT_DIFF.md`,
    `docs/WORKFLOW_ACCEPTANCE.md`.

- **Per-object batch results (`maxmcp/batch.py`).** `transform_object`,
  `clone_objects` and `delete_objects` can now run one object at a time with a
  real read-back (`find_objects` / `get_object_info`), and
  `select_objects` / `mat_assign` / `mod_add` reconcile Max's own
  `applied` / selection reply into one row per requested object.  A batch where
  one object fails now answers `success:false` with an exact
  `summary{total,succeeded,failed,skipped,verified}` instead of a single
  localized "Done." message.  Enabled for the per-object path in the core
  profile / `MAXMCP_RUNTIME_VERIFY`.
- **Object identity guard.** Names are resolved against a real scene read before
  anything executes; duplicate names answer `ambiguous_object` instead of
  editing an arbitrary node, and an object that disappears between resolution
  and execution answers `stale_object_reference`.  Numeric handles are refused
  as references (`invalid_object_reference`) until they can be proven durable.
- **Stable error taxonomy (`maxmcp/errors.py`, `docs/ERROR_CODES.md`).** The
  MAXScript `err.*` kind that `MaxBridge._parse` used to discard now becomes a
  documented code (`object_not_found`, `empty_selection`, `file_not_found`, ...).
  Transport failures get `bridge_*` codes plus `retryable`, and a mid-request
  socket close is reported as `bridge_disconnected` instead of "not running".
- **Scene state snapshots (`maxmcp/scene_state.py`).** Node snapshots and
  before/after diffs (`added`/`removed`/`modified`/`unknown`) with float and
  euler-wrap tolerances; a field that was not read is reported as missing, never
  as "unchanged".
- **Offline acceptance suite.** `test/static/offline_acceptance_test.py` drives
  the real `dispatch -> server -> MaxBridge -> socket` path against a scripted
  TCP stub (timeout, invalid JSON, empty reply, MAXScript error, disconnect) and
  checks MCP image blocks end to end.  Additional focused tests:
  `batch_reliability_test.py`, `object_reference_test.py`, `scene_state_test.py`,
  `error_protocol_test.py`, `core_tool_validation_test.py`.
- **Image validation.** `_images` bytes are now checked (strict base64, PNG /
  JPEG / WEBP header sniffing, declared MIME corrected from the payload, 8 MiB
  per image and 12 MiB per response budgets) and `path` entries are confined to
  the configured screenshot roots.  Images nested in a runtime envelope
  (`data._images`) are no longer silently dropped.

### Changed

- Argument validation now enforces `enum`, `minimum` / `maximum` and
  `minItems` / `maxItems` before sending anything to 3ds Max, so an out-of-range
  value answers `invalid_arguments` instead of being clamped inside Max.
- `scene_save` is marked mutating (it writes to disk and was advertised as
  read-only).  `scene_save_as` requires `confirm:true` to overwrite an existing
  `.max` file and now honours `keepPath` (Real-Max verification pending).
- `from_wire` treats strings outside the latin-1 range as already decoded, so
  localized MAXScript diagnostics are no longer turned into mojibake when a
  result envelope mixes decoded text with raw bridge payloads.

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

- **Reliability mode reported successful tool calls as `missing_success`
  (found during Stage 3, pre-existing).** `runtime.normalize_payload` only
  accepted a reply as conclusive when it carried `success` or `ok`, so every
  tool that answers with `{applied, failures}` (`poly_*`, `mod_*`, `mat_assign`)
  or `{class, name, assignedTo}` (`mat_create_*`) was wrapped as a failure under
  the core profile / `MAXMCP_RUNTIME_VERIFY` even though Max had done the work.
  The check now also accepts a declared outcome (`applied` / `deleted` /
  `created` / `objects`), and `mcpAssignCreatedMat` reports its own `success`.
  A payload that declares nothing still answers `missing_success`. This blocked
  every modelling / material step of a workflow, which is why it was fixed here
  rather than deferred.

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
