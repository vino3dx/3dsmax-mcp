---
name: 3dsmax-mcp-dev
description: >
  Develop, extend, debug and install the 3dsmax-mcp plugin — the Model Context Protocol
  server that lets AI agents drive Autodesk 3ds Max (2020+) for modelling, shading,
  rigging, animation, rendering, baking and engine export. Use this skill whenever you
  are working inside the 3dsmax-mcp repository, adding a new MCP tool, changing the
  MAXScript bridge, editing the tool catalog, running verify.py / doctor.py /
  test_e2e.py, or helping a user install the plugin into 3ds Max. Triggers on:
  "3dsmax-mcp", "add an MCP tool", "MAXScript bridge", "mcpRegister", "bridge_selftest",
  "tool catalog", "tool profile", "3ds Max MCP plugin".
---

# Developing the 3dsmax-mcp plugin

This repository is a two-part system. Almost every mistake made here comes from
editing one half and forgetting the other, or from writing MAXScript that cannot
be validated without a live Max session. Read this before touching anything.

## The one rule that matters most

**Every tool exists twice and the two halves must agree.**

| Half | File | What it declares |
| --- | --- | --- |
| Bridge handler | `src/ms/mcp_*.ms` | `mcpRegister "<name>" <handler> undoable:<bool> label:"..."` |
| MCP tool | `src/python/maxmcp/catalog/<category>.py` | `tool("<name>", ..., params=[...], description_zh=..., description_en=...)` |

The names must match **exactly**. `python scripts/verify.py` enforces this in both
directions and reports orphans. Run it after every change — it takes a second and
catches the most common failure.

## Architecture you must respect

```
AI client ──stdio / streamable-HTTP / legacy-SSE──▶ Python server (stdlib only)
                         src/python/maxmcp/      ──TCP 127.0.0.1:8765──▶ MAXScript bridge
                         catalogue, i18n, wire codec                    src/ms/*.ms
                         http_transport.py                              TcpListener + WinForms Timer pump
```

- **Three transports, one dispatcher.** `stdio` (default), Streamable HTTP
  (`POST /mcp`) and legacy HTTP+SSE (`GET /sse` + `POST /messages`) all funnel
  through `MaxMcpServer.dispatch(message) -> dict | None`. Never fork tool logic
  per transport — add it in `dispatch` and every transport inherits it.
  `http_transport.py` owns sessions, keep-alive, CORS, Bearer/`?token=` auth and
  `GET /health`; it binds to `127.0.0.1` by default and refuses non-loopback binds
  without `--http-token`.
- **The Python side never touches the scene.** It only serialises and forwards.
- **The bridge runs on the main thread.** MAXScript and the scene graph are
  main-thread only. The bridge uses `TcpListener` plus a `WinForms Timer` that
  pumps the socket on the UI thread — do **not** "optimise" this into a background
  thread; it will crash Max.
- **The wire is ASCII-only.** Non-ASCII text is escaped as `\u00XX` ANSI code-page
  bytes and round-tripped by `src/python/maxmcp/wire.py`. Never widen this to raw UTF-8;
  the Max side decodes single-byte and will corrupt multibyte characters.

## Banned MAXScript constructs

This machine cannot reliably run MAXScript headlessly (`3dsmaxbatch.exe` exits
without executing the script here), so verification happens through static analysis
plus an in-Max self-test. To keep that possible, the following are **forbidden** and
enforced by `verify.py`:

| Banned | Why | Use instead |
| --- | --- | --- |
| `struct` | Cannot be validated statically | Plain `#(key, value)` arrays + the `#mcpobj` Name marker |
| lambdas / closures | Same | Named `fn` functions |
| `fn = (...)` assignment | Parses differently than expected | `fn name args = (...)` |
| Trailing `\` line continuation | Not valid MAXScript | Break the expression differently |
| `.NET` generic collections | Version-dependent syntax | Plain MAXScript arrays |
| Manual `theHold` | Would double-wrap with the dispatcher | Declare `undoable:true` and let the dispatcher handle it |

`mcp_core.ms` is the single exception — it owns the `theHold` wrapper for the whole
bridge (`HOLD_ALLOWED` in `verify.py`).

## Adding a new tool

1. **Bridge handler** in the module that owns the domain (`mcp_poly.ms`,
   `mcp_shading.ms`, …):

   ```maxscript
   fn mcpH_my_thing params =
   (
       local node = mcpResolveNode (mcpStr params "name")
       ...
       mcpObj #(#("ok", true), #("value", someValue))
   )

   mcpRegister "my_thing" mcpH_my_thing undoable:true label:"My thing"
   ```

   - Read parameters with `mcpStr` / `mcpNum` / `mcpInt` / `mcpBool` / `mcpArr` / `mcpGet`.
   - Return a value with `mcpObj #(#(key, value), ...)` — the `#mcpobj` marker is
     appended automatically.
   - Fail with `mcpFail "err.some_key"` and add the message pair to `mcpMessages`
     in `mcp_core.ms` as `#(中文, English)`.
   - Set `undoable:true` for anything that mutates the scene.

2. **Catalog entry** in the matching `src/python/maxmcp/catalog/*.py`:

   ```python
   tool(
       "my_thing",
       s("name", "对象名 | Object name", required=True),
       n("amount", "数量 | Amount", default=1.0),
       b("flag", "开关 | Toggle", default=False),
       description_zh="对对象做某件事。",
       description_en="Do something to an object.",
   )
   ```

   Both descriptions are mandatory — `--selftest-python` fails on a missing one.

3. **Verify**: `python scripts/verify.py`

4. **Prove it end to end**: add a case to `scripts/test_e2e.py` if the tool changes
   the shape of a request or response.

## Localisation

- Python: `description_zh` + `description_en` on the tool; parameter descriptions
  inline `中文 | English`. Nothing else is translated — the agent reads these.
- Bridge: every user-visible string goes through `mcpMsg "key.name"` with a
  `#(中文, English)` entry in `mcpMessages`. Never hardcode a Chinese literal in a
  `format` call.
- **Language is `auto` by default and follows the running Max UI.** The bridge
  derives the code from the Max user-config directory name (`ENU`→`en`,
  `CHS`/`CHT`→`zh`, anything else→`en`) in `mcpMaxLanguageCode()` /
  `mcpDetectLanguage()`; `getLanguage()` is only the fallback. When the server is
  `auto`, it syncs from the bridge at `initialize` and after the first successful
  tool call. `set_language "zh"|"en"` **pins** the language (persisted, wins over
  auto); `set_language "auto"` hands control back to the bridge. `bridge_restart`
  clears the "already synced" latch so auto re-detects. Never persist a runtime
  `--port`/`--profile` — only `set_language` writes config, via
  `Config.save(keys=("language",))`.

## Verification commands

```bash
python scripts/verify.py                            # static integrity — run always
PYTHONPATH=src/python python -m maxmcp --selftest-python   # catalog + wire codec, no Max needed
PYTHONPATH=src/python python scripts/test_e2e.py           # full MCP round trip via MockBridge
python test/ms_check.py src/ms                      # encoding / brackets / method-chain / symbols
python test/registration_sync_test.py               # catalog <-> registry <-> deployed trees
python scripts/doctor.py                            # end-to-end install + live handshake
python scripts/install.py --list                    # detection only, installs nothing
```

`doctor.py` is the only check that needs a real 3ds Max. Everything else is green
without one, which is why the static harnesses exist.

Inside Max, `mcpSelfTest()` (or the `bridge_selftest` tool) runs 13 live checks
including a Chinese round trip and a UI-language probe (`mcpMaxLanguageCode()` +
`mcpDetectLanguage()`) — use it to confirm encoding and auto-language after any
change to `mcp_json.ms`, `wire.py` or the language helpers.

## Packaging and install

- `src/ms/` ships to `<Max user scripts>\3dsmax-mcp\` plus an autoloader in
  `<Max user scripts>\startup\3dsmax-mcp-bridge.ms`. Both `ENU` and `CHS` (or any
  other locale) user-config trees are installed to.
- `src/python/maxmcp/` ships to `%LOCALAPPDATA%\3dsmax-mcp\maxmcp`.
- Deployment is **byte-exact**: `install.py` copies files verbatim, so the
  deployed trees must equal the repo trees. `test/registration_sync_test.py`
  fails when they drift. Never hand-edit an installed `.ms` — edit `src/ms/`
  and re-run the installer.
- Client configs are **merged**, never overwritten — see `merge_json_config`. The
  installer knows 7 clients (`install.py --list`): `workbuddy`, `cursor`,
  `claude` (Desktop), `claude-code`, `windsurf`, `cline`, `roo-cline`. When adding
  a client, extend the single `CLIENTS` table — `doctor.py` reuses it, so the two
  never drift.
- `--http-port` writes `start-http.bat` alongside the stdio entry; run it for
  cloud MCP marketplaces (BigModel etc.) that register a URL instead of spawning a
  process. Loopback-only by default; add `--http-token` before exposing it.
- The autoloader only runs at Max start-up. After installing, Max must be
  restarted, or the bridge `fileIn`-ed manually. This is the single most common
  "it doesn't work" report.

## Encoding gotchas that have bitten before

- `wire.py` docstrings must be raw (`r"""..."""`) — the file contains literal
  `\uXXXX` sequences that a normal docstring turns into a `unicodeescape` error.
- `install.py` templates must also be raw strings, or `\n` inside a MAXScript
  string literal becomes a real newline and breaks the file across lines.
- `install.py` copies bridge and server files **byte for byte** — the repo is
  the canonical field-tested source and normalising anything on deploy would
  break the repo == deployed invariant. `.gitattributes` keeps git from
  rewriting line endings either (`*.ms -text`).
- `undo` is reserved by the transport and cannot be an exposed parameter name. Use
  `asOneUndo` instead.
