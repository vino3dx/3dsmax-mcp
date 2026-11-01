"""MCP server: JSON-RPC dispatch, tool listing and tool execution.

The server is deliberately dependency free - stdlib only - so the installer can
ship a single self-contained Python runtime without resolving a package graph.
"""

from __future__ import annotations

import json
import base64
from pathlib import Path
import sys
import tempfile
import time
import traceback
import uuid
from typing import Any, Dict, List, Optional, Tuple

from . import errors, i18n, scene_state
from .batch import PER_OBJECT_TOOLS, RECONCILE_TOOLS, BatchExecutor
from .bridge import BridgeError, MaxBridge
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
    make_result,
    text_content,
)
from .runtime import SceneRuntime
from .workflow import STANDARD_WORKFLOWS, Workflow, WorkflowEngine, get_workflow, list_workflows
from .wire import ANSI as _ANSI
from .wire import from_wire, to_wire


# ---------------------------------------------------------------- image results
_IMAGE_MAX_BYTES = 8 * 1024 * 1024
#: Total base64 payload a single tool result may carry.  One render at 8 MiB is
#: legitimate; four of them would blow up a client's context window.
_IMAGE_TOTAL_BYTES = 12 * 1024 * 1024
_IMAGE_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
_IMAGE_MIMES = frozenset(_IMAGE_MIME.values())

#: How many recent scene snapshots stay addressable as a diff baseline.  An
#: agent only ever needs "the one I just took", so a small ring is enough and
#: keeps memory bounded on a scene with thousands of nodes.
MAX_SNAPSHOTS = 8
#: Nodes collected per ``list_objects`` page, and the hard cap for one snapshot.
SNAPSHOT_PAGE = 200
SNAPSHOT_MAX_NODES = 5000
SNAPSHOT_MAX_PAGES = 40

#: Magic prefixes.  A declared MIME type is a claim; these are the bytes.
_IMAGE_SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"RIFF", "image/webp"),          # further checked for the WEBP tag at offset 8
)


def _sniff_image_mime(raw: bytes) -> Optional[str]:
    """Return the MIME type the bytes actually are, or ``None`` if unknown."""
    for prefix, mime in _IMAGE_SIGNATURES:
        if raw.startswith(prefix):
            if mime == "image/webp" and raw[8:12] != b"WEBP":
                return None
            return mime
    return None


def _allowed_image_roots(configured: Optional[List[str]] = None) -> List[Path]:
    """Directories a screenshot path may point into.

    ``_images`` entries usually carry base64 pixels, but the path form exists so a
    producer can hand over a file the bridge already wrote.  Reading an arbitrary
    client-supplied path would turn the server into a local file reader, so paths
    are confined to the screenshot roots (temp dir + the MCP home by default).
    """
    roots: List[Path] = []
    for item in (configured or []):
        try:
            roots.append(Path(str(item)).expanduser().resolve())
        except (OSError, RuntimeError):
            continue
    if not roots:
        roots.append(Path(tempfile.gettempdir()).resolve())
    home = Path.home() / ".3dsmax-mcp"
    try:
        roots.append(home.resolve())
    except (OSError, RuntimeError):  # pragma: no cover - defensive
        pass
    return roots


def _is_within(path: Path, roots: List[Path]) -> bool:
    try:
        resolved = path.resolve()
    except (OSError, RuntimeError):
        return False
    for root in roots:
        try:
            resolved.relative_to(root)
        except ValueError:
            continue
        return True
    return False


def _validate_image_bytes(raw: bytes, declared: str) -> Tuple[Optional[str], Optional[str]]:
    """Check that ``raw`` really is an image of the declared family.

    Returns ``(mime, error)``.  A MIME mismatch is corrected from the bytes
    instead of trusted (clients cannot claim ``image/png`` over JPEG data); bytes
    that match no signature are rejected as corrupt.
    """
    if not raw:
        return None, "empty image payload"
    sniffed = _sniff_image_mime(raw)
    if sniffed is None:
        return None, "image data is not a recognized PNG/JPEG/WEBP stream"
    mime = declared if declared in _IMAGE_MIMES else sniffed
    if mime != sniffed:
        # The bytes are authoritative: send them with the type they really are,
        # never as the type the producer claimed.
        mime = sniffed
    return mime, None


def _image_bytes(item: Dict[str, Any],
                 roots: Optional[List[Path]] = None) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """Return ``(base64_data, mime, error)`` for one ``_images`` entry."""
    allowed = roots if roots is not None else _allowed_image_roots()
    data = item.get("data")
    declared = str(item.get("mime") or item.get("mimeType") or "")

    if isinstance(data, str) and data:
        try:
            raw = base64.b64decode(data, validate=True)
        except (ValueError, TypeError):
            return None, None, "image data is not valid base64"
        if len(raw) > _IMAGE_MAX_BYTES:
            return None, None, "image exceeds 8 MiB limit"
        mime, failure = _validate_image_bytes(raw, declared)
        if failure:
            return None, None, failure
        # Re-encode so the block carries canonical base64 (no stray whitespace).
        return base64.b64encode(raw).decode("ascii"), mime, None

    raw_path = item.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        return None, None, "missing image data or path"
    path = Path(raw_path)
    if not _is_within(path, allowed):
        return None, None, "image path is outside the allowed screenshot roots"
    hint = declared or _IMAGE_MIME.get(path.suffix.lower(), "")
    if hint not in _IMAGE_MIMES and not hint:
        return None, None, "unsupported image type"
    try:
        size = path.stat().st_size
        if size > _IMAGE_MAX_BYTES:
            return None, None, "image exceeds 8 MiB limit"
        with path.open("rb") as stream:
            raw = stream.read(_IMAGE_MAX_BYTES + 1)
    except OSError as exc:
        return None, None, "image file unavailable: %s" % exc
    if len(raw) > _IMAGE_MAX_BYTES:
        return None, None, "image exceeds 8 MiB limit"
    mime, failure = _validate_image_bytes(raw, hint)
    if failure:
        return None, None, failure
    return base64.b64encode(raw).decode("ascii"), mime, None


def _collect_images(payload: Any) -> Any:
    """Find the top-level ``_images`` array, including one nested in ``data``.

    Runtime-wrapped results keep the bridge payload under ``data``; without this
    lookup a mutating tool that returns pixels would answer with metadata only.
    """
    if not isinstance(payload, dict):
        return None
    raw = payload.get("_images")
    if isinstance(raw, list):
        return payload
    for key in ("data", "result"):
        nested = payload.get(key)
        if isinstance(nested, dict) and isinstance(nested.get("_images"), list):
            inner = dict(nested)
            blocks_source = inner.pop("_images")
            replacement = dict(payload)
            replacement[key] = inner
            replacement["_images"] = blocks_source
            return replacement
    return None


def _split_images(payload: Any, operation_id: str = "",
                  roots: Optional[List[Path]] = None) -> Tuple[List[Dict[str, Any]], Any]:
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
    text-only tools behave exactly as before.
    """
    source = _collect_images(payload)
    if source is None:
        return [], payload

    blocks: List[Dict[str, Any]] = []
    described: List[Dict[str, Any]] = []
    budget = _IMAGE_TOTAL_BYTES

    for item in source.get("_images") or []:
        if not isinstance(item, dict):
            continue
        data, mime, image_error = _image_bytes(item, roots)
        if image_error:
            described.append({"label": item.get("label") or (len(described) + 1),
                              "error": image_error})
            continue
        assert data is not None and mime is not None
        if len(data) > budget:
            described.append({"label": item.get("label") or (len(described) + 1),
                              "error": "image exceeds the per-response image budget"})
            continue
        budget -= len(data)
        blocks.append(image_content(data, mime))
        described.append(
            {
                "label": item.get("label") or (len(described) + 1),
                "mimeType": mime,
                "base64Chars": len(data),
            }
        )

    rest = dict(source)
    rest.pop("_images", None)
    if described:
        rest["images"] = described
        errors_list = [item for item in described if item.get("error")]
        if errors_list:
            rest["image_errors"] = errors_list
        if operation_id:
            rest["operation_id"] = operation_id
            for item in described:
                item["operation_id"] = operation_id
    return blocks, rest


def _failure_from_payload(payload: Any) -> Optional[Dict[str, Any]]:
    """First machine-readable failure entry inside a tool payload, if any."""
    if not isinstance(payload, dict):
        return None
    for key in ("failures", "error"):
        value = payload.get(key)
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict) and (item.get("kind") or item.get("code")):
                    return item
        elif isinstance(value, dict) and (value.get("kind") or value.get("code")):
            return value
    return None


def _workflow_is_error(record: Dict[str, Any]) -> bool:
    """Whether a finished workflow is reported to the client as an error.

    ``success`` answers "did the whole objective succeed", so a partial run
    keeps ``success: false``.  ``is_error`` answers the narrower question "is
    this scene state something the agent must not build on".  Unproven steps
    and a missing picture degrade a run to ``partial`` without making it an
    error - the scene work did happen - whereas a hard failure, an interrupt, a
    contradicted verification or an unmet declared goal do not get that pardon.
    """
    status = record.get("status")
    if status in ("failed", "interrupted"):
        return True
    summary = record.get("summary") or {}
    if summary.get("verification_failed"):
        return True
    expectation = record.get("expectation") or {}
    if expectation.get("performed") and expectation.get("passed") is False:
        return True
    return False


# ----------------------------------------------------------------- snapshots
#: Version of the on-disk baseline format.  Bump it when the stored document
#: shape changes; a reader that meets an unknown version must refuse rather than
#: diff apples against oranges.
SNAPSHOT_FILE_VERSION = 1


class SnapshotFileProblem(Exception):
    """A baseline file that cannot be used, with a machine-readable reason."""

    def __init__(self, reason: str, message: str, **detail: Any) -> None:
        super().__init__(message)
        self.reason = reason
        self.message = message
        self.detail = detail


def _snapshot_path(value: Any, field: str) -> Path:
    """Validate a baseline path; refuse anything that could overwrite real work."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("{0} must be a non-empty path".format(field))
    path = Path(value.strip())
    if not path.is_absolute():
        raise ValueError("{0} must be an absolute path: {1}".format(field, value))
    if path.suffix.lower() != ".json":
        # Refusing anything else is what keeps a typo from landing on a .max file.
        raise ValueError("{0} must end in .json: {1}".format(field, value))
    return path


def _write_snapshot_file(path: Path, document: Dict[str, Any], tolerance: float) -> int:
    body = {
        "schemaVersion": SNAPSHOT_FILE_VERSION,
        "tool": "scene_snapshot",
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "tolerance": tolerance,
        "nodeCount": document.get("node_count"),
        "document": document,
    }
    text = json.dumps(body, ensure_ascii=False, indent=2, default=str)
    if path.parent and not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return len(text.encode("utf-8"))


def _read_snapshot_file(path: Path) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """Load a baseline document; raise :class:`SnapshotFileProblem` when unusable."""
    if not path.is_file():
        raise SnapshotFileProblem(
            "baseline_file_missing",
            "No baseline file at {0}; take a snapshot with saveBaseline first".format(path),
            path=str(path),
        )
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SnapshotFileProblem(
            "baseline_file_corrupt",
            "Baseline file is not readable JSON: {0}".format(exc),
            path=str(path),
        )
    if not isinstance(body, dict):
        raise SnapshotFileProblem(
            "baseline_file_corrupt",
            "Baseline file does not hold a snapshot object",
            path=str(path),
        )
    version = body.get("schemaVersion")
    if version != SNAPSHOT_FILE_VERSION:
        raise SnapshotFileProblem(
            "unsupported_snapshot_version",
            "Baseline file has schemaVersion {0}, this build writes {1}".format(
                version, SNAPSHOT_FILE_VERSION),
            path=str(path), found=version, expected=SNAPSHOT_FILE_VERSION,
        )
    document = body.get("document")
    if not isinstance(document, dict) or not isinstance(document.get("nodes"), dict):
        raise SnapshotFileProblem(
            "baseline_file_corrupt",
            "Baseline file has no nodes object",
            path=str(path),
        )
    meta = {
        "path": str(path),
        "schema_version": version,
        "created_at": body.get("createdAt"),
        "node_count": body.get("nodeCount"),
    }
    return document, meta


# ------------------------------------------------------------------- the server
class MaxMcpServer:
    def __init__(self, config: Optional[Config] = None, transport: Optional[StdioTransport] = None) -> None:
        self.config = config or Config.load()
        self.transport = transport or StdioTransport()
        self.catalog: Catalog = build_catalog()
        self.bridge = MaxBridge(self.config)
        self.runtime = SceneRuntime(self.bridge.call)
        self.batch = BatchExecutor(self.bridge.call)
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
        """What the client reads once, before choosing any tool.

        Kept short on purpose: it is prepended to every conversation, so it only
        states what changes tool choice - connection order, the escape hatch,
        and the snapshot/workflow habit that makes scene work checkable.
        """
        categories = ", ".join(
            "{0}({1})".format(k, v) for k, v in sorted(self.catalog.categories().items())
        )
        if self.config.language == "en":
            return (
                "This server drives Autodesk 3ds Max (2020 and later) directly. "
                "Call bridge_status first to confirm the connection, then bridge_capabilities to see "
                "what the running Max build supports. Use bridge_selftest when something fails oddly. "
                "Use set_language to switch the whole bridge between English and Simplified Chinese. "
                "Prefer the specific tools; use execute_maxscript only when no tool covers the job, "
                "and say why. "
                "For scene work, take a scene_snapshot baseline before changing anything and diff it "
                "afterwards; run three or more dependent steps through workflow_run and declare "
                "verification on the steps that matter. A step that executed is not a goal that was "
                "met - when nothing verified the result, report it as unverified instead of done. "
                "Tool categories: {0}.".format(categories)
            )
        return (
            "本服务直接驱动 Autodesk 3ds Max（2020 及以上）。"
            "先调用 bridge_status 确认连接，再用 bridge_capabilities 查看当前 Max 版本支持哪些命令；"
            "工具异常失败时用 bridge_selftest 自检。"
            "用 set_language 可在中文和英文之间整体切换。"
            "优先使用专用工具；只有现有工具确实做不到时才用 execute_maxscript，并说明原因。"
            "处理场景时：改动前先 scene_snapshot 留一份基线，改完用它对比；"
            "三步以上且有依赖的任务用 workflow_run，并给关键步骤声明 verification。"
            "步骤“执行成功”不等于“目标达成”——没有验证过就如实说未验证，不要当成已完成。"
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

        if self.catalog.get(name) is None:
            return make_result(
                [text_content(i18n.t("tool.unknown", self.config.language, name=name))], is_error=True
            )

        run = self._execute_tool(name, arguments)

        if run.get("validation_error"):
            return make_result(
                [text_content(self._error_text(
                    code="invalid_arguments",
                    kind="validation_error",
                    tool=name,
                    message=i18n.t("tool.bad_arguments", self.config.language,
                                   detail=run["validation_error"]),
                    suggestion="Provide all required parameters with the declared types.",
                ))],
                is_error=True,
            )

        bridge_error = run.get("bridge_error")
        if bridge_error is not None:
            return make_result(
                [text_content(self._error_text(
                    code=errors.classify(getattr(bridge_error, "code", None) or bridge_error.kind),
                    kind=getattr(bridge_error, "kind", "bridge_error"),
                    tool=name,
                    message=str(bridge_error),
                    detail=getattr(bridge_error, "detail", None),
                    suggestion=self._error_suggestion(bridge_error),
                    retryable=errors.retryable(errors.classify(
                        getattr(bridge_error, "code", None) or getattr(bridge_error, "kind", ""))),
                ))],
                is_error=True,
            )

        text = json.dumps(run.get("payload"), ensure_ascii=False, indent=2, default=str)
        text = clamp_text(text, self.config.max_response_chars)
        content: List[Dict[str, Any]] = [text_content(text)]
        content.extend(run.get("blocks") or [])
        image_failure = bool(run.get("image_errors"))
        return make_result(content, is_error=(not run.get("ok", False)) or image_failure)

    # ------------------------------------------------------- one tool execution
    def _execute_tool(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Run one tool and return everything the callers need to report it.

        This is the single execution path: ``tools/call`` formats the result for
        the client, and :class:`maxmcp.workflow.WorkflowEngine` reuses it for
        every workflow step.  Keeping one path is what makes "the workflow ran
        create_box" and "the agent called create_box" the same claim.

        The returned mapping never raises for tool-level problems:

            ok                whether the call succeeded
            payload           JSON-able result (images already split out)
            blocks            MCP image content blocks
            images            image descriptors (label/mime/base64Chars)
            image_errors      images that could not be turned into a block
            validation_error  set when the arguments were rejected in Python
            bridge_error      the transport exception, for the error envelope
            operation_id      stable id, also embedded in image descriptors
        """
        run: Dict[str, Any] = {"ok": False, "payload": None, "blocks": [],
                               "images": [], "image_errors": [], "operation_id": ""}
        entry = self.catalog.get(name)
        if entry is None:
            run["validation_error"] = "unknown tool: {0}".format(name)
            return run

        if entry.local:
            # Local tools validate their arguments exactly like bridged ones, but
            # the payload stays as Python values (there is no ANSI wire to encode).
            try:
                params = self._coerce_arguments(entry, arguments)
            except ValueError as exc:
                run["validation_error"] = str(exc)
                return run
            try:
                return self._run_local_tool(entry, params, run)
            except BridgeError as exc:
                run["bridge_error"] = exc
                return run

        try:
            payload = self._build_payload(entry, arguments)
        except ValueError as exc:
            run["validation_error"] = str(exc)
            return run

        runtime_failure = False
        try:
            runtime_enabled = self.config.runtime_verify or self.config.tool_profile == "core"
            objects = payload.get("objects")
            has_objects = isinstance(objects, list) and bool(objects)
            if entry.name in RECONCILE_TOOLS and has_objects:
                # One bridge call, one undo entry - but the reply is reconciled
                # into one row per object, so a silently skipped object can no
                # longer masquerade as success.
                result = self.batch.run(entry.name, entry.bridge_method, payload)
                runtime_failure = result.get("success") is False
            elif runtime_enabled and entry.name in PER_OBJECT_TOOLS and has_objects:
                # Per-object execution needs real read-back, which only the
                # reliability mode (core profile / MAXMCP_RUNTIME_VERIFY) pays for.
                result = self.batch.run(entry.name, entry.bridge_method, payload)
                runtime_failure = result.get("success") is False
            elif runtime_enabled and entry.mutating:
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
            run["bridge_error"] = exc
            return run

        result = from_wire(result)
        self._apply_side_effects(entry, arguments, result)

        # Auto-language: now that a call has definitely reached Max, mirror its
        # language. This is what makes an English Max user get English tools
        # without touching any config.
        self.sync_language_from_bridge()

        operation_id = "op-" + uuid.uuid4().hex[:12]
        if isinstance(result, dict) and result.get("operation_id"):
            operation_id = str(result["operation_id"])
        images, summary = _split_images(
            result, operation_id, _allowed_image_roots(self.config.image_roots))

        run.update({
            "ok": not runtime_failure,
            "payload": summary,
            "blocks": images,
            "images": (summary.get("images") if isinstance(summary, dict) else None) or [],
            "image_errors": (summary.get("image_errors") if isinstance(summary, dict) else None) or [],
            "operation_id": operation_id,
        })
        return run

    # --------------------------------------------------- python-side tools
    def _run_local_tool(self, entry: Tool, arguments: Dict[str, Any],
                        run: Dict[str, Any]) -> Dict[str, Any]:
        """Tools implemented in Python over other tools (no bridge command).

        They still obey the same contract: validation problems become
        ``validation_error`` and scene failures become ``ok: false`` with a
        machine-readable code inside the payload.
        """
        handler = self._local_tools().get(entry.name)
        if handler is None:
            run["validation_error"] = "no local handler for {0}".format(entry.name)
            return run
        try:
            payload = handler(arguments)
        except ValueError as exc:
            run["validation_error"] = str(exc)
            return run
        ok = True
        if isinstance(payload, dict):
            # ``success`` is the tool's own verdict on its objective; ``is_error``
            # is the narrower question "does this reply represent a failure the
            # caller must not build on".  They differ for a workflow that built
            # the scene but could not prove it: not a complete success, yet not
            # an error either.  A local tool that knows the difference declares
            # ``is_error`` and wins.
            if payload.get("success") is False:
                ok = False
            declared = payload.get("is_error")
            if isinstance(declared, bool):
                ok = not declared
        run.update({"ok": ok, "payload": payload, "operation_id": "local-" + uuid.uuid4().hex[:8]})
        return run

    def _local_tools(self) -> Dict[str, Any]:
        return {
            "scene_snapshot": self._tool_scene_snapshot,
            "workflow_run": self._tool_workflow_run,
        }

    # ------------------------------------------------------------ snapshots
    def _read_nodes(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Page through ``list_objects`` until the reported count is covered."""
        wanted = arguments.get("limit")
        max_nodes = SNAPSHOT_MAX_NODES
        if isinstance(wanted, int) and wanted > 0:
            max_nodes = min(wanted, SNAPSHOT_MAX_NODES)
        filters = {key: arguments[key] for key in ("superClass", "class", "layer", "namePattern")
                   if arguments.get(key)}
        nodes: List[Any] = []
        reported = None
        offset = 0
        for _ in range(SNAPSHOT_MAX_PAGES):
            params = dict(filters)
            params["limit"] = SNAPSHOT_PAGE
            params["offset"] = offset
            result = self._execute_tool("list_objects", params)
            if result.get("bridge_error") is not None:
                raise result["bridge_error"]
            if result.get("validation_error"):
                raise ValueError(result["validation_error"])
            payload = result.get("payload")
            if not isinstance(payload, dict):
                raise ValueError("list_objects returned no object list")
            page = payload.get("objects")
            if not isinstance(page, list):
                raise ValueError("list_objects reply has no objects array")
            count = payload.get("count")
            if isinstance(count, int):
                reported = count
            nodes.extend(page)
            offset += len(page)
            if not page or (isinstance(reported, int) and offset >= reported):
                break
            if len(nodes) >= max_nodes:
                break
        truncated = False
        if len(nodes) > max_nodes:
            nodes = nodes[:max_nodes]
            truncated = True
        if isinstance(reported, int) and len(nodes) < reported:
            truncated = True
        return {"nodes": nodes, "reported": reported, "truncated": truncated}

    def _read_selection(self) -> Optional[List[str]]:
        """Names of the current selection, or ``None`` when it cannot be read."""
        result = self._execute_tool("get_selection", {})
        if result.get("bridge_error") is not None or result.get("validation_error"):
            return None
        payload = result.get("payload")
        if not isinstance(payload, dict) or not isinstance(payload.get("objects"), list):
            return None
        names: List[str] = []
        for entry in payload["objects"]:
            if isinstance(entry, dict) and isinstance(entry.get("name"), str):
                names.append(entry["name"])
        return names

    def _capture_snapshot(self, arguments: Optional[Dict[str, Any]] = None,
                          snapshot_id: str = "") -> Dict[str, Any]:
        """Read the scene once and return a snapshot document (raises on failure)."""
        read = self._read_nodes(arguments or {})
        selection = self._read_selection()
        document = scene_state.build_snapshot(
            read["nodes"],
            selection=selection,
            reported_count=read["reported"],
            truncated=read["truncated"],
        )
        document["snapshot_id"] = snapshot_id
        if selection is None:
            document["complete"] = False
        return document

    def _store_snapshot(self, document: Dict[str, Any]) -> str:
        counter = getattr(self, "_snapshot_counter", 0) + 1
        self._snapshot_counter = counter
        snapshot_id = "snap-{0:04d}".format(counter)
        document["snapshot_id"] = snapshot_id
        cache = getattr(self, "_snapshots", None)
        if cache is None:
            cache = {}
            self._snapshots = cache
        cache[snapshot_id] = document
        while len(cache) > MAX_SNAPSHOTS:
            oldest = next(iter(cache))
            cache.pop(oldest, None)
        return snapshot_id

    def _tool_scene_snapshot(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        baseline_id = arguments.get("baseline")
        tolerance = arguments.get("tolerance")
        tolerance = float(tolerance) if isinstance(tolerance, (int, float)) else scene_state.DEFAULT_TOLERANCE

        try:
            save_path = _snapshot_path(arguments.get("saveBaseline"), "saveBaseline") \
                if arguments.get("saveBaseline") else None
            load_path = _snapshot_path(arguments.get("baselineFile"), "baselineFile") \
                if arguments.get("baselineFile") else None
        except ValueError as exc:
            return {
                "success": False,
                "failures": [errors.error("invalid_arguments", str(exc))],
            }

        document = self._capture_snapshot(arguments)
        snapshot_id = self._store_snapshot(document)

        payload: Dict[str, Any] = {
            "success": True,
            "snapshot_id": snapshot_id,
            "nodes": {
                name: {key: value for key, value in snap.items()
                       if key not in ("missing", "complete")}
                for name, snap in document["nodes"].items()
            },
            "node_count": document["node_count"],
            "reported_count": document["reported_count"],
            "selection": document["selection"],
            "selection_read": document["selection_read"],
            "summary": document["summary"],
            "complete": document["complete"],
            "truncated": document["truncated"],
            "partial_nodes": document["partial_nodes"][:20],
            "missing_fields": document["missing_fields"],
            "handles_unique": document["handles_unique"],
            "warnings": [],
        }
        if document["truncated"]:
            payload["warnings"].append(errors.error(
                "snapshot_truncated",
                "The snapshot stopped before every object was read; a diff over it is partial",
                collected=document["node_count"],
                reported=document["reported_count"],
            ))
        if document["missing_fields"]:
            payload["warnings"].append(errors.error(
                "snapshot_unavailable",
                "Some snapshot fields were not reported by this Max build",
                fields=document["missing_fields"],
            ))
        if save_path is not None:
            try:
                written = _write_snapshot_file(save_path, document, tolerance)
            except OSError as exc:
                return {
                    "success": False,
                    "failures": [errors.error(
                        "snapshot_unavailable",
                        "Could not write the baseline file: {0}".format(exc),
                        path=str(save_path), reason="write_failed")],
                    "snapshot_id": snapshot_id,
                }
            payload["saved_baseline"] = {
                "path": str(save_path),
                "schema_version": SNAPSHOT_FILE_VERSION,
                "node_count": document["node_count"],
                "bytes": written,
            }

        baseline = None
        if load_path is not None:
            try:
                baseline, meta = _read_snapshot_file(load_path)
            except SnapshotFileProblem as exc:
                detail = dict(exc.detail)
                detail.setdefault("path", str(load_path))
                detail["reason"] = exc.reason
                return {
                    "success": False,
                    "failures": [errors.error(
                        "snapshot_unavailable", exc.message, **detail)],
                    "snapshot_id": snapshot_id,
                }
            payload["baseline_file"] = meta
        elif baseline_id:
            cache = getattr(self, "_snapshots", {})
            baseline = cache.get(str(baseline_id))
            if baseline is None:
                return {
                    "success": False,
                    "failures": [errors.error(
                        "invalid_arguments",
                        "Unknown baseline snapshot id: {0}".format(baseline_id),
                        known=sorted(cache),
                    )],
                    "snapshot_id": snapshot_id,
                }
            payload["baseline"] = str(baseline_id)

        if baseline is not None:
            payload["diff"] = scene_state.diff_documents(baseline, document, tolerance)
        return payload

    # ------------------------------------------------------------- workflows
    def _workflow_invoke(self, operation: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Adapter that lets the workflow engine reuse the tool execution path."""
        run = self._execute_tool(operation, arguments or {})
        if run.get("bridge_error") is not None:
            return {"ok": False, "error": errors.from_exception(run["bridge_error"], "workflow")}
        if run.get("validation_error"):
            return {"ok": False, "error": errors.error(
                "invalid_arguments", run["validation_error"], tool=operation)}
        payload = run.get("payload")
        error = None
        if not run.get("ok"):
            error = _failure_from_payload(payload) or errors.error(
                "operation_failed", "Tool reported failure", tool=operation)
        return {
            "ok": bool(run.get("ok")),
            "payload": payload,
            "error": error,
            "images": run.get("images") or [],
            "image_errors": run.get("image_errors") or [],
        }

    def _tool_workflow_run(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        name = arguments.get("workflow")
        steps = arguments.get("steps")
        if isinstance(name, str) and name and isinstance(steps, list) and steps:
            raise ValueError("pass either 'workflow' or 'steps', not both")
        if not name and not steps:
            return {
                "success": True,
                "workflows": list_workflows(),
                "hint": "Call workflow_run with {'workflow': <name>} to execute one, "
                        "or pass an explicit 'steps' array.",
            }
        if name:
            spec = get_workflow(str(name))
            if spec is None:
                return {
                    "success": False,
                    "failures": [errors.error(
                        "workflow_unknown",
                        "No built-in workflow named {0}".format(name),
                        available=sorted(STANDARD_WORKFLOWS),
                    )],
                }
        else:
            raw = {"name": "custom", "steps": steps, "expect": arguments.get("expect") or {},
                   "capture": arguments.get("capture", True)}
            try:
                spec = Workflow.from_dict(raw)
            except ValueError as exc:
                raise ValueError(str(exc))

        engine = WorkflowEngine(
            self._workflow_invoke,
            capture=(lambda: self._capture_snapshot()) if spec.capture else None,
            tolerance=float(arguments["tolerance"]) if isinstance(arguments.get("tolerance"), (int, float))
            else scene_state.DEFAULT_TOLERANCE,
        )
        if arguments.get("dry_run"):
            from .workflow import validate
            problems = validate(spec, set(self.catalog.names()))
            return {
                "success": not problems,
                "dry_run": True,
                "workflow": spec.name,
                "steps": [{"id": step.id, "operation": step.operation,
                           "verification": (step.verify or {}).get("kind"),
                           "depends_on": list(step.depends_on),
                           "optional": step.optional} for step in spec.steps],
                "problems": problems,
            }
        record = engine.run(spec, known_operations=set(self.catalog.names()))
        record["success"] = record.get("status") == "success"
        record["is_error"] = _workflow_is_error(record)
        return record

    def _error_text(self, *, code: str, kind: str, tool: str,
                    message: str, suggestion: str = "",
                    detail: Any = None, retryable: bool = False) -> str:
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
        if retryable:
            envelope["error"]["retryable"] = True
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

    def _coerce_arguments(self, entry: Tool, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Merge the preset and enforce the declared schema, in Python values."""
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

        return payload

    def _build_payload(self, entry: Tool, arguments: Dict[str, Any]) -> Dict[str, Any]:
        return to_wire(self._coerce_arguments(entry, arguments))

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
    """Coerce to the declared type and enforce the declared constraints.

    The MAXScript side is tolerant, which used to mean a value outside the
    documented range travelled all the way into Max and failed there (or, worse,
    was clamped silently).  Rejecting it here produces a stable
    ``invalid_arguments`` answer that names the offending parameter.
    """
    type_name = spec.get("type")
    if value is None:
        return None
    if type_name == "integer":
        try:
            number = int(value)
        except (TypeError, ValueError):
            raise ValueError("{0} must be an integer".format(key))
        return _check_bounds(number, spec, key, integer=True)
    if type_name == "number":
        try:
            number = float(value)
        except (TypeError, ValueError):
            raise ValueError("{0} must be a number".format(key))
        return _check_bounds(number, spec, key, integer=False)
    if type_name == "boolean":
        if isinstance(value, bool):
            return value
        text = str(value).strip().lower()
        if text in ("1", "true", "yes", "on", "y"):
            return True
        if text in ("0", "false", "no", "off", "n"):
            return False
        raise ValueError("{0} must be a boolean".format(key))
    if type_name == "string":
        if isinstance(value, str):
            text = value
        elif isinstance(value, (dict, list)):
            text = json.dumps(value, ensure_ascii=False)
        else:
            text = str(value)
        return _check_enum(text, spec, key)
    if type_name == "array":
        items = _coerce_array(value, key)
        minimum = spec.get("minItems")
        maximum = spec.get("maxItems")
        if isinstance(minimum, int) and len(items) < minimum:
            raise ValueError("{0} needs at least {1} item(s)".format(key, minimum))
        if isinstance(maximum, int) and len(items) > maximum:
            raise ValueError("{0} accepts at most {1} item(s)".format(key, maximum))
        return items
    return value


def _coerce_array(value: Any, key: str) -> List[Any]:
    if isinstance(value, (list, tuple)):
        return list(value)
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("["):
            try:
                parsed = json.loads(text)
            except ValueError:
                parsed = None
            if isinstance(parsed, list):
                return parsed
            raise ValueError("{0} looks like JSON but is not a valid array".format(key))
        if not text:
            return []
        return [part.strip() for part in text.split(",") if part.strip()]
    if isinstance(value, (int, float, bool)):
        return [value]
    return [value]


def _check_bounds(number: Any, spec: Dict[str, Any], key: str, integer: bool) -> Any:
    minimum = spec.get("minimum")
    maximum = spec.get("maximum")
    if isinstance(minimum, (int, float)) and number < minimum:
        raise ValueError("{0} must be >= {1}".format(key, minimum))
    if isinstance(maximum, (int, float)) and number > maximum:
        raise ValueError("{0} must be <= {1}".format(key, maximum))
    return number


def _check_enum(text: str, spec: Dict[str, Any], key: str) -> str:
    allowed = spec.get("enum")
    if not isinstance(allowed, list) or not allowed:
        return text
    if text in allowed:
        return text
    # Models often send the right word in the wrong case; normalise instead of
    # failing, but never invent a value that is not in the enum.
    lookup = {str(item).lower(): item for item in allowed}
    canonical = lookup.get(text.strip().lower())
    if canonical is not None:
        return str(canonical)
    raise ValueError("{0} must be one of: {1}".format(key, ", ".join(str(item) for item in allowed)))


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
