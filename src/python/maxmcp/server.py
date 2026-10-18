"""MCP server: JSON-RPC dispatch, tool listing and tool execution.

The server is deliberately dependency free - stdlib only - so the installer can
ship a single self-contained Python runtime without resolving a package graph.
"""

from __future__ import annotations

import json
import platform
import sys
import time
import traceback
from typing import Any, Dict, List, Optional, Tuple

from . import i18n
from .bridge import BridgeCommandError, BridgeError, MaxBridge
from .catalog import build_catalog
from .catalog.schema import Catalog, Tool
from .config import APP_NAME, PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS, VERSION, Config
from .http_transport import McpHttpTransport
from .protocol import (
    INTERNAL_ERROR,
    INVALID_PARAMS,
    INVALID_REQUEST,
    METHOD_NOT_FOUND,
    NullTransport,
    RpcError,
    StdioTransport,
    clamp_text,
    image_content,
    json_content,
    make_result,
    text_content,
)
from .wire import ANSI as _ANSI
from .wire import from_wire, to_wire


# ---------------------------------------------------------------- image results
def _split_images(payload: Any) -> Tuple[List[Dict[str, Any]], Any]:
    """Pull base64 pixels out of a bridge result into MCP image blocks.

    The MAXScript side (``max/mcp_vision.ms``) can only send JSON text over the
    bridge, so it parks pictures in a top-level ``_images`` array:

        {"count": 2, "views": [...],
         "_images": [{"label": "front", "data": "<base64>", "mime": "image/jpeg"}]}

    Here that array becomes real ``image`` content blocks.  Everything else stays
    ordinary JSON, and a compact ``images`` description is left behind so the text
    block still says which picture is which - a client that cannot render images
    loses the pixels but not the metadata.

    Returns ``(blocks, rest)``.  ``rest`` always equals ``payload`` minus
    ``_images``; for results with no pictures it is ``payload`` untouched, so all
    375 existing text-only tools behave exactly as before.
    """
    if not isinstance(payload, dict):
        return [], payload

    raw = payload.get("_images")
    if not isinstance(raw, list) or not raw:
        return [], payload

    blocks: List[Dict[str, Any]] = []
    described: List[Dict[str, Any]] = []

    for item in raw:
        if not isinstance(item, dict):
            continue
        data = item.get("data")
        if not isinstance(data, str) or not data:
            continue
        mime = str(item.get("mime") or item.get("mimeType") or "image/png")
        if not mime.startswith("image/"):
            mime = "image/png"
        blocks.append(image_content(data, mime))
        described.append(
            {
                "label": item.get("label") or (len(described) + 1),
                "mimeType": mime,
                "base64Chars": len(data),
            }
        )

    rest = dict(payload)
    rest.pop("_images", None)
    if described:
        rest["images"] = described
    return blocks, rest


# ------------------------------------------------------------------- the server
class MaxMcpServer:
    def __init__(self, config: Optional[Config] = None, transport: Optional[StdioTransport] = None) -> None:
        self.config = config or Config.load()
        self.transport = transport or StdioTransport()
        self.catalog: Catalog = build_catalog()
        self.bridge = MaxBridge(self.config)
        self._initialized = False

        # Language handling. "auto" means: mirror the UI language of the running
        # 3ds Max, so a Chinese Max gets Chinese descriptions and an English one
        # gets English, with no configuration. An explicit zh/en pins it and
        # auto-following stops for good.
        self._language_preference = i18n.parse_preference(self.config.language)
        self._language_synced = False
        if self._language_preference == i18n.AUTO:
            # Provisional until we can ask Max. Chinese is the safer default:
            # our messages are bilingual anyway, but the audience is mostly
            # Chinese-speaking, and an English Max user switching to English is
            # a smaller surprise than the reverse.
            self.config.language = "zh"

    # -------------------------------------------------------------- language
    @property
    def language_is_auto(self) -> bool:
        return self._language_preference == i18n.AUTO

    def sync_language_from_bridge(self, force: bool = False) -> Optional[str]:
        """Adopt the bridge's language when running in auto mode.

        Called on initialize and after every successful tool call. The heavy
        lifting is in the bridge, which derives its language from the Max UI
        language; this only mirrors it. Returns the newly adopted language, or
        None when nothing changed.
        """
        if not self.language_is_auto:
            return None
        if self._language_synced and not force:
            return None

        status = self.bridge.status()
        if not status.get("connected"):
            # Max is not up yet. Stay unresolved so a later call retries.
            return None

        info = status.get("info") or {}
        reported = i18n.normalize(info.get("language"))
        self._language_synced = True
        if not reported or reported == self.config.language:
            return None

        previous = self.config.language
        self.config.language = reported
        self.transport.log(i18n.t(
            "language.auto_detected",
            reported,
            code=info.get("maxLanguage") or "?",
            name=i18n.LANGUAGE_NAMES.get(reported, reported),
        ))
        return reported if previous != reported else None

    def _pin_language(self, language: str) -> None:
        self._language_preference = language
        self._language_synced = True

    # ------------------------------------------------------------- main loop
    def serve_forever(self) -> int:
        while True:
            try:
                message = self.transport.read_message()
            except KeyboardInterrupt:
                return 0
            if message is None:
                return 0
            response = self.dispatch(message)
            if response is not None:
                self.transport.send(response)

    # --------------------------------------------------------------- dispatch
    def dispatch(self, message: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Handle one JSON-RPC message and return the reply, or None.

        Returning the reply instead of writing it lets the same server logic
        back stdio, Streamable HTTP and legacy SSE without knowing which one is
        in use. Error shaping lives here so every transport reports failures
        identically.
        """
        try:
            if isinstance(message, list):
                raise RpcError(INVALID_REQUEST, "Invalid request: batches are expanded by the transport")
            if not isinstance(message, dict):
                raise RpcError(INVALID_REQUEST, "Invalid request: expected a JSON object")

            method = message.get("method")
            request_id = message.get("id")
            params = message.get("params") or {}

            if request_id is None:
                # Notification - no response is allowed.
                self.handle_notification(method, params)
                return None

            if not isinstance(method, str):
                raise RpcError(INVALID_REQUEST, "Invalid request: missing method")

            handler = {
                "initialize": self.on_initialize,
                "ping": self.on_ping,
                "tools/list": self.on_tools_list,
                "tools/call": self.on_tools_call,
                "resources/list": self.on_resources_list,
                "resources/templates/list": self.on_resources_templates_list,
                "prompts/list": self.on_prompts_list,
                "logging/setLevel": self.on_logging_set_level,
                "completion/complete": self.on_completion_complete,
            }.get(method)

            if handler is None:
                raise RpcError(METHOD_NOT_FOUND, "Method not found: {0}".format(method))

            return {"jsonrpc": "2.0", "id": request_id, "result": handler(params)}

        except RpcError as exc:
            return {"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None,
                    "error": exc.to_dict()}
        except Exception:  # pragma: no cover - defensive
            self.transport.log(traceback.format_exc())
            return {
                "jsonrpc": "2.0",
                "id": message.get("id") if isinstance(message, dict) else None,
                "error": {"code": INTERNAL_ERROR, "message": "Internal error",
                          "data": traceback.format_exc(limit=3)},
            }

    def handle_message(self, message: Dict[str, Any]) -> None:
        """Backwards-compatible single-message entry point."""
        response = self.dispatch(message)
        if response is not None:
            self.transport.send(response)

    def handle_notification(self, method: Optional[str], params: Dict[str, Any]) -> None:
        if method == "notifications/initialized":
            self._initialized = True
        elif method == "notifications/cancelled":
            pass
        # Notifications never produce output.

    # -------------------------------------------------------------- handlers
    def on_initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        requested = params.get("protocolVersion")
        negotiated = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else PROTOCOL_VERSION
        client = (params.get("clientInfo") or {}).get("name", "unknown")

        # In auto mode, try to match the running Max before we describe
        # ourselves, so the client's first tools/list is already in the right
        # language. Cheap when Max is down (connection refused on loopback).
        self.sync_language_from_bridge()

        self.transport.log(
            "client={0} protocol={1} tools={2} language={3}{4}".format(
                client, negotiated, len(self.catalog), self.config.language,
                " (auto)" if self.language_is_auto else "",
            )
        )
        return {
            "protocolVersion": negotiated,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": APP_NAME, "version": VERSION},
            "instructions": self._instructions(),
        }

    def _instructions(self) -> str:
        categories = ", ".join(
            "{0}({1})".format(k, v) for k, v in sorted(self.catalog.categories().items())
        )
        if self.config.language == "en":
            return (
                "This server drives Autodesk 3ds Max (2020 and later) directly. "
                "Call bridge_status first to confirm the connection, then bridge_capabilities to see "
                "what the running Max build supports. Use bridge_selftest when something fails oddly. "
                "Use set_language to switch the whole bridge between English and Simplified Chinese. "
                "Prefer the specific modelling tools; fall back to execute_maxscript for anything else. "
                "Tool categories: {0}.".format(categories)
            )
        return (
            "本服务直接驱动 Autodesk 3ds Max（2020 及以上）。"
            "先调用 bridge_status 确认连接，再用 bridge_capabilities 查看当前 Max 版本支持哪些命令；"
            "工具异常失败时用 bridge_selftest 自检。"
            "用 set_language 可在中文和英文之间整体切换。"
            "优先使用专用建模工具，其余情况用 execute_maxscript 兜底。"
            "工具分类：{0}。".format(categories)
        )

    def on_ping(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {}

    def on_tools_list(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "tools": self.catalog.to_mcp(
                self.config.language,
                self.config.bilingual,
                self.config.tool_profile,
                self.config.disabled_categories,
            )
        }

    def on_resources_list(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"resources": []}

    def on_resources_templates_list(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"resourceTemplates": []}

    def on_prompts_list(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"prompts": []}

    def on_logging_set_level(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {}

    def on_completion_complete(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"completion": {"values": [], "hasMore": False}}

    # -------------------------------------------------------------- tool call
    def on_tools_call(self, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not isinstance(name, str) or not name:
            raise RpcError(INVALID_PARAMS, "tools/call requires a tool name")
        if not isinstance(arguments, dict):
            raise RpcError(INVALID_PARAMS, "tools/call arguments must be an object")

        entry = self.catalog.get(name)
        if entry is None:
            return make_result(
                [text_content(i18n.t("tool.unknown", self.config.language, name=name))], is_error=True
            )

        try:
            payload = self._build_payload(entry, arguments)
        except ValueError as exc:
            return make_result(
                [text_content(i18n.t("tool.bad_arguments", self.config.language, detail=str(exc)))],
                is_error=True,
            )

        try:
            result = self.bridge.call(entry.bridge_method, payload)
        except BridgeError as exc:
            return make_result([text_content(str(exc))], is_error=True)

        result = from_wire(result)
        self._apply_side_effects(entry, arguments, result)

        # Auto-language: now that a call has definitely reached Max, mirror its
        # language. This is what makes an English Max user get English tools
        # without touching any config.
        self.sync_language_from_bridge()

        images, summary = _split_images(result)

        text = json.dumps(summary, ensure_ascii=False, indent=2, default=str)
        text = clamp_text(text, self.config.max_response_chars)

        content: List[Dict[str, Any]] = [text_content(text)]
        content.extend(images)
        return make_result(content)

    def _build_payload(self, entry: Tool, arguments: Dict[str, Any]) -> Dict[str, Any]:
        schema = entry.schema
        properties: Dict[str, Any] = schema.get("properties", {})
        required: List[str] = schema.get("required", [])

        payload: Dict[str, Any] = dict(entry.preset)
        for key, value in arguments.items():
            if key not in properties:
                # Tolerate unknown keys instead of failing: model output drifts.
                continue
            payload[key] = value

        missing = [r for r in required if payload.get(r) is None]
        if missing:
            raise ValueError("missing required parameter(s): {0}".format(", ".join(missing)))

        for key, spec in properties.items():
            if key not in payload:
                continue
            payload[key] = _coerce(payload[key], spec, key)

        return to_wire(payload)

    def _apply_side_effects(self, entry: Tool, arguments: Dict[str, Any], result: Any) -> None:
        """Keep server state in sync with commands that change it."""
        if entry.name == "set_language":
            requested = i18n.parse_preference(arguments.get("language"))
            if requested == i18n.AUTO:
                # Hand control back to the bridge, then mirror whatever it says.
                self._language_preference = i18n.AUTO
                self._language_synced = False
                self.sync_language_from_bridge(force=True)
                return
            if requested and requested != self.config.language:
                self.config.language = requested
                self._pin_language(requested)
                try:
                    # Only the language is a durable preference. Persisting the
                    # whole config would bake run-scoped --port/--profile values
                    # into the user's file.
                    self.config.save(keys=("language",))
                except OSError as exc:  # pragma: no cover - non fatal
                    self.transport.log("could not persist language: {0}".format(exc))
            elif requested:
                # Same language, but the caller clearly meant to pin it.
                self._pin_language(requested)
        elif entry.name == "bridge_restart":
            self.bridge.close()
            # A restarted bridge may come back in a different Max language.
            self._language_synced = False


def _coerce(value: Any, spec: Dict[str, Any], key: str) -> Any:
    """Best effort coercion; the MAXScript side is tolerant but typed values help."""
    type_name = spec.get("type")
    if value is None:
        return None
    if type_name == "integer":
        try:
            return int(value)
        except (TypeError, ValueError):
            raise ValueError("{0} must be an integer".format(key))
    if type_name == "number":
        try:
            return float(value)
        except (TypeError, ValueError):
            raise ValueError("{0} must be a number".format(key))
    if type_name == "boolean":
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in ("1", "true", "yes", "on")
    if type_name == "string":
        if isinstance(value, str):
            return value
        return json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else str(value)
    if type_name == "array":
        if isinstance(value, (list, tuple)):
            return list(value)
        if isinstance(value, str):
            text = value.strip()
            if text.startswith("["):
                try:
                    parsed = json.loads(text)
                    if isinstance(parsed, list):
                        return parsed
                except ValueError:
                    pass
            if not text:
                return []
            return [part.strip() for part in text.split(",") if part.strip()]
        return [value]
    return value


USAGE = """{app} {ver} - MCP server for Autodesk 3ds Max (2020 and later)

Speaks the Model Context Protocol so AI clients can drive 3ds Max. The default
mode is stdio: the client launches this process and talks over stdin/stdout.

Usage:
  python -m maxmcp [options]

Transport:
  --transport <stdio|http|both>
                           stdio  - launched by the client (default)
                           http   - Streamable HTTP on /mcp, plus the legacy
                                    HTTP+SSE pair /sse and /messages
                           both   - stdio and http in one process
  --http-host <addr>       bind address for http mode (default 127.0.0.1)
  --http-port <n>          port for http mode (default 8770)
  --http-token <token>     require Authorization: Bearer <token> on http
  --http-path <path>       Streamable HTTP endpoint path (default /mcp)

Language:
  -l, --language <auto|zh|en>
                           auto follows the running 3ds Max UI language
                           (default auto), otherwise pin zh or en

Tools:
  --port <n>               bridge TCP port (default 8765)
  -p, --profile <name>     tool profile: core | modeling | lookdev |
                           animation | pipeline | full   (default full)

Diagnostics:
  --list-tools             print every tool the current profile exposes
  --list-profiles          print the size of each profile
  --selftest-python        validate the catalog + wire codec (no Max needed)
  --no-stdio               do not print the ready banner to stderr
  --version                print the version and exit
  -h, --help               print this help and exit

Environment:
  MAXMCP_PORT, MAXMCP_LANGUAGE, MAXMCP_PROFILE, MAXMCP_BILINGUAL,
  MAXMCP_TIMEOUT, MAXMCP_HOST, MAXMCP_HOME, MAXMCP_TRANSPORT,
  MAXMCP_HTTP_HOST, MAXMCP_HTTP_PORT, MAXMCP_HTTP_TOKEN
""".format(app=APP_NAME, ver=VERSION)


def _flag_value(argv: List[str], names: List[str], default: Optional[str] = None) -> Optional[str]:
    """Read ``--flag value`` or ``--flag=value`` for the first matching name."""
    for name in names:
        for index, token in enumerate(argv):
            if token == name and index + 1 < len(argv):
                return argv[index + 1]
            if token.startswith(name + "="):
                return token.split("=", 1)[1]
    return default


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    if "--version" in argv:
        print("{0} {1}".format(APP_NAME, VERSION))
        return 0

    if "--help" in argv or "-h" in argv:
        print(USAGE, end="")
        return 0

    config = Config.load()

    # Run-scoped overrides. None of these are written back to the config file.
    picked_language = _flag_value(argv, ["--language", "-l"])
    if picked_language is not None:
        preference = i18n.parse_preference(picked_language)
        if preference:
            config.language = preference

    port = _flag_value(argv, ["--port"])
    if port is not None:
        try:
            config.port = int(port)
        except ValueError:
            pass

    profile = _flag_value(argv, ["--profile", "-p"])
    if profile is not None:
        config.tool_profile = profile.strip().lower()

    transport = (_flag_value(argv, ["--transport"]) or config.transport or "stdio").strip().lower()
    config.transport = transport
    for flag, attribute in (("--http-host", "http_host"), ("--http-token", "http_token"),
                            ("--http-path", "http_path")):
        value = _flag_value(argv, [flag])
        if value is not None:
            setattr(config, attribute, value)
    http_port = _flag_value(argv, ["--http-port"])
    if http_port is not None:
        try:
            config.http_port = int(http_port)
        except ValueError:
            pass

    if "--list-profiles" in argv:
        catalog = build_catalog()
        print("total: {0} tools\n".format(len(catalog)))
        for name in ("core", "modeling", "lookdev", "animation", "pipeline", "full"):
            stats = catalog.profile_summary(name)
            print("{0:<10} {1:>4} tools   {2}".format(
                name,
                sum(stats.values()),
                ", ".join("{0}={1}".format(k, v) for k, v in sorted(stats.items())) or "(all)",
            ))
        return 0

    if "--list-tools" in argv:
        catalog = build_catalog()
        for entry in catalog.to_mcp(
            config.effective_language, config.bilingual, config.tool_profile, config.disabled_categories
        ):
            print("{0:<32} [{1}]".format(entry["name"], _category_of(catalog, entry["name"])))
        stats = catalog.profile_summary(config.tool_profile)
        print("\nprofile '{0}': {1} tools in {2} categories.".format(
            config.tool_profile, sum(stats.values()), len(stats)
        ))
        return 0

    if "--selftest-python" in argv:
        return _selftest_python(config)

    if transport not in ("stdio", "http", "both"):
        print("unknown --transport {0!r}: expected stdio, http or both".format(transport), file=sys.stderr)
        return 2

    # In plain http mode nothing reads stdin, so replies must never be written
    # to stdout; the transport only serves for logging.
    if transport == "http":
        server = MaxMcpServer(config, transport=NullTransport())
    else:
        server = MaxMcpServer(config)
    server.config.transport = transport

    if "--no-stdio" not in argv:
        server.transport.log(
            "{0} {1} ready - {2} tools, transport={3}, language={4}{5}".format(
                APP_NAME, VERSION, len(server.catalog), transport, config.language,
                " (auto)" if config.language_is_auto else "",
            )
        )

    if transport in ("http", "both"):
        http = _start_http(server, config)
        if http is None:
            return 2
        if transport == "http":
            return _wait_forever()

    return server.serve_forever()


def _start_http(server: "MaxMcpServer", config: Config) -> Optional["McpHttpTransport"]:
    """Bring up the HTTP listener and report where clients should connect."""
    transport = McpHttpTransport(
        server.dispatch,
        host=config.http_host,
        port=config.http_port,
        token=config.http_token or None,
        log=server.transport.log,
        endpoint_path=config.http_path or "/mcp",
    )
    try:
        transport.start()
    except OSError as exc:
        print("could not start the MCP HTTP listener on {0}:{1}: {2}".format(
            config.http_host, config.http_port, exc), file=sys.stderr)
        return None

    warning = transport.warn_if_exposed()
    if warning:
        print(warning, file=sys.stderr, flush=True)

    server.transport.log("MCP HTTP endpoint: {0}".format(transport.url))
    server.transport.log("legacy SSE clients: http://{0}:{1}/sse".format(
        "127.0.0.1" if config.http_host in ("0.0.0.0", "::") else config.http_host, transport.port))
    server.transport.log("health probe:      http://127.0.0.1:{0}/health".format(transport.port))
    return transport


def _wait_forever() -> int:
    """Block while HTTP worker threads do the work, until Ctrl-C."""
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


def _category_of(catalog: Catalog, name: str) -> str:
    entry = catalog.get(name)
    return entry.category if entry else "?"


def _selftest_python(config: Config) -> int:
    """Validate catalog + encoding without needing 3ds Max running."""
    catalog = build_catalog()
    problems: List[str] = []

    if len(catalog) == 0:
        problems.append("catalog is empty")

    seen = set()
    for entry in catalog:
        if entry.name in seen:
            problems.append("duplicate tool name: {0}".format(entry.name))
        seen.add(entry.name)
        if not entry.description_zh or not entry.description_en:
            problems.append("{0}: missing a bilingual description".format(entry.name))
        schema = entry.schema
        if schema.get("type") != "object":
            problems.append("{0}: schema is not an object".format(entry.name))
        for prop, spec in (schema.get("properties") or {}).items():
            if "type" not in spec:
                problems.append("{0}.{1}: property without a type".format(entry.name, prop))

    # wire encoding round trip, including Chinese
    samples = ["模型", "Cube_001", "材质/Metal_Rough", "a\"b\\c\nd", "日本語", ""]
    for sample in samples:
        restored = from_wire(to_wire(sample))
        if restored != sample:
            problems.append("wire round trip failed for {0!r}: {1!r}".format(sample, restored))

    print("catalog: {0} tools in {1} categories".format(len(catalog), len(catalog.categories())))
    for category, count in sorted(catalog.categories().items()):
        print("  {0:<14} {1}".format(category, count))
    print("encoding codec: {0}".format(_ANSI))
    if problems:
        print("\n{0} problem(s):".format(len(problems)))
        for problem in problems:
            print("  - {0}".format(problem))
        return 1
    print("\nall checks passed")
    return 0
