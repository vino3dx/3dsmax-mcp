# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **One guarded collapse path (D4).** `collapse_stack` is now a controlled
  alias of `mod_collapse`: the catalog entry bridges to `mod_collapse` and
  requires `confirm=true`, so the previously unguarded collapse path is gone.
  The duplicate `mcpH_collapse_stack` handler and its `mcpRegister` were
  removed from `mcp_poly.ms` (MAXScript registered commands 354 → 353).
  `mod_collapse` stays the main entry; its behaviour is unchanged.

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
  `D:\Workspace\Dev\3dsmax-mcp` with a `src/python/maxmcp` (server) +
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
