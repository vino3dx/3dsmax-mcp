"""MCP server: JSON-RPC dispatch, tool listing and tool execution.

The server is deliberately dependency free - stdlib only - so the installer can
ship a single self-contained Python runtime without resolving a package graph.
"""

from __future__ import annotations

import json
import base64
import difflib
from pathlib import Path
import platform
import sys
import time
import traceback
import uuid
from typing import Any, Dict, List, Optional, Tuple

from . import i18n
from .bridge import BridgeCommandError, BridgeError, MaxBridge
from .catalog import build_catalog
from .catalog.schema import Catalog, Tool
from .config import (
    APP_NAME,
    CONTEXT_RESOURCE_URI,
    PROTOCOL_VERSION,
    SUPPORTED_PROTOCOL_VERSIONS,
    VERSION,
    Config,
)
from .context import SceneContextCache
from .http_transport import McpHttpTransport, UnsafeExposureError
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
from .runtime import SceneRuntime
from .wire import ANSI as _ANSI
from .wire import from_wire, to_wire


# ---------------------------------------------------------------- image results
_IMAGE_MAX_BYTES = 8 * 1024 * 1024
_IMAGE_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}


def _image_bytes(item: Dict[str, Any]) -> Tuple[Optional[str], Optional[str]]:
    data = item.get("data")
    if isinstance(data, str) and data:
        return data, None
    raw_path = item.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        return None, "missing image data or path"
    path = Path(raw_path)
    mime = str(item.get("mime") or item.get("mimeType") or _IMAGE_MIME.get(path.suffix.lower(), ""))
    if mime not in _IMAGE_MIME.values():
        return None, "unsupported image type"
    try:
        size = path.stat().st_size
        if size > _IMAGE_MAX_BYTES:
            return None, "image exceeds 8 MiB limit"
        with path.open("rb") as stream:
            return base64.b64encode(stream.read(_IMAGE_MAX_BYTES + 1)).decode("ascii"), None
    except OSError as exc:
        return None, "image file unavailable: %s" % exc


def _available_sections(payload: Any) -> List[str]:
    """The domain list a context_get reply advertises.

    Used as the "expected" set when rebuilding the cached snapshot: without it a
    cache that had only ever seen one domain would claim to be complete.
    """
    if isinstance(payload, dict):
        names = payload.get("availableSections")
        if isinstance(names, list) and names:
            return [name for name in names if isinstance(name, str)]
        sections = payload.get("sections")
        if isinstance(sections, dict) and sections:
            return sorted(sections)
    return []


def _split_images(payload: Any, operation_id: str = "") -> Tuple[List[Dict[str, Any]], Any]:
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
        data, image_error = _image_bytes(item)
        if image_error:
            described.append({"label": item.get("label") or (len(described) + 1),
                              "error": image_error})
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
        errors = [item for item in described if item.get("error")]
        if errors:
            rest["image_errors"] = errors
        if operation_id:
            rest["operation_id"] = operation_id
            for item in described:
                item["operation_id"] = operation_id
    return blocks, rest


# ------------------------------------------------------------------- the server
class MaxMcpServer:
    def __init__(self, config: Optional[Config] = None, transport: Optional[StdioTransport] = None) -> None:
        self.config = config or Config.load()
        self.transport = transport or StdioTransport()
        self.catalog: Catalog = build_catalog()
        self.bridge = MaxBridge(self.config)
        self.runtime = SceneRuntime(self.bridge.call)
        # Stitches the incremental context_get replies into a complete snapshot
        # so the resource endpoint never has to re-read every domain.
        self.context_cache = SceneContextCache()
        self._initialized = False
        # Argument corrections produced while preparing the current call.
        self._param_notes: List[str] = []

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
                "resources/read": self.on_resources_read,
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
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {
                    "subscribe": False,
                    "listChanged": False,
                },
            },
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
                "To understand the scene before acting, read the max://scene/context resource "
                "(same data as context_get) instead of issuing several list_* calls. "
                "Tool categories: {0}.".format(categories)
            )
        return (
            "本服务直接驱动 Autodesk 3ds Max（2020 及以上）。"
            "先调用 bridge_status 确认连接，再用 bridge_capabilities 查看当前 Max 版本支持哪些命令；"
            "工具异常失败时用 bridge_selftest 自检。"
            "用 set_language 可在中文和英文之间整体切换。"
            "优先使用专用建模工具，其余情况用 execute_maxscript 兜底。"
            "动手前若需要了解场景，直接读 max://scene/context 资源（与 context_get 同源），"
            "不要用多次 list_* 调用拼凑。"
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
        return {"resources": self._resource_definitions()}

    def on_resources_templates_list(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"resourceTemplates": [
            {
                "uriTemplate": "max://scene/context/{domain}",
                "name": "scene-context-domain",
                "description": (
                    "One scene-context domain: scene, selection, objects, materials, assets, "
                    "animation, rigging, render or project."
                    if self.config.language == "en" else
                    "单个场景上下文域：scene、selection、objects、materials、assets、"
                    "animation、rigging、render 或 project。"
                ),
                "mimeType": "application/json",
            }
        ]}

    def _resource_definitions(self) -> List[Dict[str, Any]]:
        if self.catalog.get("context_get") is None:
            # The resource is a view onto context_get; without the tool there is
            # nothing to read, and advertising an unreadable URI is worse than
            # advertising none.
            return []
        return [{
            "uri": CONTEXT_RESOURCE_URI,
            "name": "scene-context",
            "title": "3ds Max scene context",
            "description": (
                "Live snapshot of the whole scene: summary, selection, object counts, "
                "materials, assets, animation, rigging, render setup and project."
                if self.config.language == "en" else
                "整个场景的实时快照：概要、选择、对象统计、材质、资源、动画、"
                "骨骼、渲染设置与工程信息。"
            ),
            "mimeType": "application/json",
        }]

    def on_resources_read(self, params: Dict[str, Any]) -> Dict[str, Any]:
        uri = params.get("uri")
        if not isinstance(uri, str) or not uri:
            raise RpcError(INVALID_PARAMS, "resources/read requires a uri")
        if self.catalog.get("context_get") is None:
            raise RpcError(METHOD_NOT_FOUND, "context_get is not enabled in this profile")

        domain = ""
        if uri.startswith(CONTEXT_RESOURCE_URI + "/"):
            domain = uri[len(CONTEXT_RESOURCE_URI) + 1:]
            if not domain:
                raise RpcError(INVALID_PARAMS, "Unknown resource: {0}".format(uri))
        elif uri != CONTEXT_RESOURCE_URI:
            raise RpcError(INVALID_PARAMS, "Unknown resource: {0}".format(uri))

        entry = self.catalog.get("context_get")
        arguments: Dict[str, Any] = {}
        if domain:
            arguments["sections"] = [domain]
        cursor = self.context_cache.cursor()
        if cursor > 0:
            arguments["since"] = cursor

        try:
            payload = self._build_payload(entry, arguments)
            raw = from_wire(self.bridge.call(entry.bridge_method, payload))
        except (BridgeError, ValueError) as exc:
            # Report the failure inside the resource body instead of raising: an
            # MCP resource read that fails should say why, not just error out.
            return {
                "contents": [{
                    "uri": uri,
                    "mimeType": "application/json",
                    "text": json.dumps(
                        {
                            "error": str(exc),
                            "kind": getattr(exc, "kind", "validation_error"),
                            "uri": uri,
                            "note": "the bridge did not answer; nothing was cached",
                        },
                        ensure_ascii=False, indent=2,
                    ),
                }]
            }

        report = self.context_cache.merge(raw if isinstance(raw, dict) else {})
        expected = [domain] if domain else _available_sections(raw)
        body = self.context_cache.snapshot(expected)
        body["merge"] = report
        return {
            "contents": [{
                "uri": uri,
                "mimeType": "application/json",
                "text": json.dumps(body, ensure_ascii=False, indent=2, default=str),
            }]
        }

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
                [text_content(self._error_text(
                    code="invalid_arguments",
                    kind="validation_error",
                    tool=name,
                    message=i18n.t("tool.bad_arguments", self.config.language, detail=str(exc)),
                    suggestion="Provide all required parameters with the declared types.",
                ))],
                is_error=True,
            )

        runtime_failure = False
        try:
            runtime_enabled = self.config.runtime_verify or self.config.tool_profile == "core"
            if runtime_enabled and entry.mutating:
                result = self.runtime.execute(
                    entry.name,
                    entry.bridge_method,
                    payload,
                    mutating=True,
                ).as_dict()
                runtime_failure = result.get("success") is False
            else:
                result = self.bridge.call(entry.bridge_method, payload)
        except BridgeError as exc:
            if entry.name == "bridge_restart":
                # Rebinding the listener drops every open socket, including the
                # one this reply would travel on, so a failure here is the
                # expected outcome rather than an error. Report it as success
                # and drop the stale connection; the next call reconnects.
                # (`bridge_stop` is not a tool at all -- see catalog/core.py.)
                self.bridge.close()
                result = {
                    "ok": True,
                    "command": entry.name,
                    "note": i18n.t("bridge.restarted", self.config.language, tool=entry.name),
                }
            else:
                recovered = self._recover_written_file(entry, arguments)
                if recovered is None:
                    return make_result(
                        [text_content(self._error_text(
                            code=getattr(exc, "code", None) or exc.kind,
                            kind=exc.kind,
                            tool=name,
                            message=str(exc),
                            detail=getattr(exc, "detail", None),
                            suggestion=self._error_suggestion(exc),
                        ))],
                        is_error=True,
                    )
                result = recovered

        result = from_wire(result)
        self._apply_side_effects(entry, arguments, result)

        # Surface argument corrections in the payload itself: a renamed or
        # ignored parameter is invisible in the tool result otherwise, and the
        # failure it causes shows up one call later.
        notes = getattr(self, "_param_notes", [])
        if notes and isinstance(result, dict):
            result["parameterNotes"] = notes

        # Auto-language: now that a call has definitely reached Max, mirror its
        # language. This is what makes an English Max user get English tools
        # without touching any config.
        self.sync_language_from_bridge()

        operation_id = "op-" + uuid.uuid4().hex[:12]
        if isinstance(result, dict) and result.get("operation_id"):
            operation_id = str(result["operation_id"])
        images, summary = _split_images(result, operation_id)

        text = json.dumps(summary, ensure_ascii=False, indent=2, default=str)
        text = clamp_text(text, self.config.max_response_chars)

        content: List[Dict[str, Any]] = [text_content(text)]
        content.extend(images)
        image_failure = isinstance(summary, dict) and bool(summary.get("image_errors"))
        return make_result(content, is_error=runtime_failure or image_failure)

    def _error_text(self, *, code: str, kind: str, tool: str,
                    message: str, suggestion: str = "",
                    detail: Any = None) -> str:
        """Return a human-readable message with machine-readable error fields."""
        envelope: Dict[str, Any] = {
            "error": {
                "code": code,
                "kind": kind,
                "tool": tool,
                "message": message,
                "suggestion": suggestion or "Inspect the error and retry after correcting the input.",
            }
        }
        if detail:
            envelope["error"]["detail"] = detail
        return json.dumps(envelope, ensure_ascii=False, indent=2, default=str)

    @staticmethod
    def _error_suggestion(exc: BridgeError) -> str:
        if exc.kind == "not_running":
            return "Start 3ds Max, load the bridge, and confirm the configured port."
        if exc.kind == "timeout":
            return "Retry after checking Max; increase MAXMCP_TIMEOUT for long operations."
        if exc.kind == "protocol_error":
            return "Check bridge/server version alignment and reload the bridge module."
        return "Correct the reported Max-side problem, then retry; verify scene state before continuing."

    def _recover_written_file(self, entry: Tool, arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Treat "file is on disk" as success when Max threw after writing it.

        The ObjExp / FBX exporters can raise a MAXScript *system* exception
        (EXCEPTION_STACK_OVERFLOW) after they have already flushed the file.
        MAXScript cannot catch system exceptions, so the bridge reports a
        failure even though the export is complete and valid -- and callers were
        left thinking nothing had been written. The contract of these tools is
        "the file exists and is not empty", so check exactly that.

        Only file-producing tools are considered, and only for a path the caller
        actually asked for.
        """
        if not entry.name.startswith(("export_", "render_still", "viewport_capture", "save_")):
            return None
        target = arguments.get("path")
        if not isinstance(target, str) or not target.strip():
            return None
        try:
            path = Path(target).expanduser()
            if not path.is_file() or path.stat().st_size <= 0:
                return None
        except OSError:
            return None
        return {
            "path": str(path),
            "written": True,
            "recovered": True,
            "sizeBytes": path.stat().st_size,
            "message": i18n.t("tool.recovered_after_error", self.config.language, path=str(path)),
        }

    def _build_payload(self, entry: Tool, arguments: Dict[str, Any]) -> Dict[str, Any]:
        schema = entry.schema
        properties: Dict[str, Any] = schema.get("properties", {})
        required: List[str] = schema.get("required", [])

        payload: Dict[str, Any] = dict(entry.preset)
        resolved, renames = _resolve_argument_names(arguments, properties)

        notes: List[str] = []
        for source, target in renames:
            notes.append(i18n.t("tool.param_renamed", self.config.language,
                                source=source, target=target))
        for key, value in resolved.items():
            if key not in properties:
                # Tolerate unknown keys instead of failing: model output drifts.
                # Silently dropping them was worse though: a caller that spelled
                # `names` for `objects` got a cheerful "ok" and nothing selected,
                # and the *next* tool failed with "nothing is selected".
                notes.append(i18n.t(
                    "tool.param_ignored",
                    self.config.language,
                    name=key,
                    valid=", ".join(sorted(properties)) or "-",
                ))
                continue
            payload[key] = value
        self._param_notes = notes

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
        elif entry.name == "context_get":
            self._merge_context_reply(result)

    def _merge_context_reply(self, payload: Any) -> None:
        """Fold a `context_get` tool reply into the snapshot the resource serves.

        The tool and `max://scene/context` used to be two independent views: the
        tool went straight to the bridge, the resource read from this cache, and
        the cache was only ever written by a resource read.  So a client could
        call the tool, see the new selection, then read the resource and get the
        previous one -- two answers to the same question (Phase B F1).

        A `detail:"full"` reply is skipped on purpose: it carries a 200-row
        selection dump and the brief snapshot should not keep it.
        """
        if not isinstance(payload, dict):
            return
        if payload.get("detail") == "full":
            return
        try:
            self.context_cache.merge(payload)
        except Exception as exc:  # pragma: no cover - defensive
            self.transport.log("context cache merge failed: {0}".format(exc))


# Argument spellings that mean the same thing across the catalog. Tool schemas
# are not uniform (`objects` on most, `names` on some), and a caller that picks
# the other one used to get a silent no-op.
_ALIAS_GROUPS = (
    ("objects", "names", "objs", "items", "selection", "objectnames", "object"),
    ("material", "mat", "materials", "materialname"),
    ("light", "lights", "lightname"),
    ("camera", "cameras", "cam", "cameraname"),
    ("path", "filepath", "file", "filename", "output", "outputpath"),
)


def _value_fits(spec: Dict[str, Any], value: Any) -> bool:
    """True when value has the shape the target parameter declares."""
    type_name = spec.get("type")
    if type_name in ("string", "number", "integer", "boolean"):
        return not isinstance(value, (list, dict))
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "object":
        return isinstance(value, dict)
    return True


def _resolve_argument_names(
    arguments: Dict[str, Any], properties: Dict[str, Any]
) -> Tuple[Dict[str, Any], List[Tuple[str, str]]]:
    """Map caller spellings onto the declared parameter names.

    Returns the usable arguments plus the (source, target) renames that were
    applied.  Resolution order: exact, case-insensitive, alias group, then a
    close spelling match.  Anything still unknown is passed through so the
    caller can be told exactly what was ignored.
    """
    if not arguments:
        return {}, []

    by_lower = {name.lower(): name for name in properties}
    resolved: Dict[str, Any] = {}
    renames: List[Tuple[str, str]] = []

    for key, value in arguments.items():
        if key in properties:
            resolved[key] = value
            continue

        target = by_lower.get(key.lower())
        if target is None:
            group = next(
                (g for g in _ALIAS_GROUPS if key.lower() in g),
                None,
            )
            if group is not None:
                target = next(
                    (name for name in properties if name.lower() in group), None
                )
        if target is None and len(key) > 2:
            matches = difflib.get_close_matches(key, list(properties), n=1, cutoff=0.75)
            target = matches[0] if matches else None

        if target is None:
            resolved[key] = value
            continue
        # A rename must not change the shape of the value: `bones: [...]` is not
        # a valid `bone: "..."`, and silently passing the list on produced a
        # confusing "unknown property in undefined" inside 3ds Max.
        if not _value_fits(properties.get(target, {}), value):
            resolved[key] = value
            continue
        # Never let a corrected spelling overwrite an explicitly passed value.
        if target in resolved or target in arguments:
            resolved[key] = value
            continue
        resolved[target] = value
        if target != key:
            renames.append((key, target))

    return resolved, renames


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
    except UnsafeExposureError as exc:
        print("REFUSED to start the MCP HTTP endpoint: {0}".format(exc), file=sys.stderr)
        return None
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
