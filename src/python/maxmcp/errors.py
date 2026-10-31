"""Stable error taxonomy for every layer of the 3ds Max MCP chain.

Three layers used to report failure differently:

    MAXScript handler  -> {"ok":false,"error":{"kind":"err.node_not_found", ...}}
    bridge (Python)    -> BridgeCommandError(kind="command_error", code=...)
    MCP tool result    -> {"error": {"code": ..., "kind": ...}}

The ``kind`` MAXScript declares is the only place that knows *why* a command
failed ("object was not found" is not the same failure as "the socket timed
out"), but it used to be dropped by :meth:`maxmcp.bridge.MaxBridge._parse`.  This
module restores that information and gives every failure one canonical code, so
an agent can branch on ``kind`` instead of matching localized prose.

Rules encoded here:

* A code is stable and documented (``docs/ERROR_CODES.md``); message text is
  diagnostic only and may be localized.
* Transport problems (``bridge_*``) are retryable, business problems are not.
* Unknown codes are preserved rather than flattened into ``command_error``:
  losing the original reason is worse than an undocumented one.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional

# --------------------------------------------------------------------- catalogue


@dataclass(frozen=True)
class ErrorSpec:
    """Documented meaning of one stable error code."""

    code: str
    stage: str            # transport | max | runtime | media
    summary: str
    retryable: bool = False


def _spec(code: str, stage: str, summary: str, retryable: bool = False) -> ErrorSpec:
    return ErrorSpec(code=code, stage=stage, summary=summary, retryable=retryable)


ERROR_SPECS: Dict[str, ErrorSpec] = {
    # ---- transport: the Python side never reached 3ds Max -------------------
    "bridge_not_running": _spec(
        "bridge_not_running", "transport",
        "The TCP bridge is not listening; 3ds Max is closed or mcp_bridge.ms is not running.",
        retryable=True),
    "bridge_timeout": _spec(
        "bridge_timeout", "transport",
        "The bridge accepted the request but no reply arrived before the deadline; "
        "the command may still be executing inside Max.",
        retryable=True),
    "bridge_protocol_error": _spec(
        "bridge_protocol_error", "transport",
        "The bridge sent bytes that are not a valid response envelope (bad JSON, empty reply).",
        retryable=True),
    "bridge_disconnected": _spec(
        "bridge_disconnected", "transport",
        "The connection closed mid-request, usually because Max quit or the bridge was reloaded.",
        retryable=True),
    "bridge_error": _spec(
        "bridge_error", "transport",
        "Unclassified bridge/transport failure."),
    # ---- MAXScript business failures ---------------------------------------
    "object_not_found": _spec(
        "object_not_found", "max",
        "No scene object matched the requested name or reference."),
    "ambiguous_object": _spec(
        "ambiguous_object", "max",
        "More than one scene object matched the reference; the operation was refused "
        "instead of guessing."),
    "stale_object_reference": _spec(
        "stale_object_reference", "max",
        "The referenced object no longer exists (deleted or renamed since the reference "
        "was created)."),
    "invalid_object_reference": _spec(
        "invalid_object_reference", "max",
        "The object reference is malformed (empty, wrong type, or missing a name)."),
    "invalid_arguments": _spec(
        "invalid_arguments", "max",
        "A parameter is missing or outside its declared range."),
    "empty_selection": _spec(
        "empty_selection", "max",
        "The command needed a selection but nothing was selected."),
    "unsupported_class": _spec(
        "unsupported_class", "max",
        "The requested 3ds Max class/plugin is not available in this installation."),
    "wrong_object_type": _spec(
        "wrong_object_type", "max",
        "The object exists but is the wrong type for this operation (for example not "
        "an Editable Poly)."),
    "file_not_found": _spec(
        "file_not_found", "max",
        "The requested file does not exist."),
    "confirmation_required": _spec(
        "confirmation_required", "max",
        "The command would overwrite or irreversibly modify data and requires an explicit "
        "confirm=true."),
    "unknown_method": _spec(
        "unknown_method", "max",
        "The running bridge does not implement this command (version mismatch)."),
    "item_not_found": _spec(
        "item_not_found", "max",
        "The requested sub-item (material, modifier, layer, ...) was not found."),
    "render_engine_unavailable": _spec(
        "render_engine_unavailable", "max",
        "The renderer could not be switched to the requested engine."),
    "unsupported_feature": _spec(
        "unsupported_feature", "max",
        "The running 3ds Max version lacks the API this tool needs."),
    "max_runtime_error": _spec(
        "max_runtime_error", "max",
        "MAXScript raised an unclassified exception while running the command."),
    "max_command_failed": _spec(
        "max_command_failed", "max",
        "The bridge reported failure without a more specific kind."),
    # ---- runtime / result-shape failures -----------------------------------
    "empty_result": _spec(
        "empty_result", "runtime",
        "The bridge answered ok but returned no payload, so nothing about the "
        "operation can be verified."),
    "duplicate_object_in_request": _spec(
        "duplicate_object_in_request", "runtime",
        "The same object appeared more than once in one request; it was executed once."),
    "selection_scope": _spec(
        "selection_scope", "runtime",
        "No object list was given, so the command acted on the current selection and "
        "no per-object result exists."),
    "missing_success": _spec(
        "missing_success", "runtime",
        "The bridge payload never declared success/ok, so it cannot be treated as success."),
    "operation_failed": _spec(
        "operation_failed", "runtime",
        "The bridge executed the command and reported failure."),
    "partial_success": _spec(
        "partial_success", "runtime",
        "Some objects/items succeeded and some failed; the overall result is not success."),
    "batch_failed": _spec(
        "batch_failed", "runtime",
        "Every object/item in the batch failed."),
    "item_failed": _spec(
        "item_failed", "runtime",
        "One batch item failed without a more specific kind."),
    "not_applied": _spec(
        "not_applied", "runtime",
        "Max answered the batch but did not list this object as applied; per-object work "
        "was silently skipped inside Max."),
    "not_deleted": _spec(
        "not_deleted", "runtime",
        "The delete command returned, but the object still exists when read back."),
    "no_effect": _spec(
        "no_effect", "runtime",
        "Read-back verification showed no change where the request implied one."),
    "verification_failed": _spec(
        "verification_failed", "runtime",
        "Scene read-back contradicted the claimed result."),
    "verification_error": _spec(
        "verification_error", "runtime",
        "Verification itself raised; the operation result is therefore unverified."),
    "aborted": _spec(
        "aborted", "runtime",
        "Execution stopped after a transport/bridge failure; this item was not attempted."),
    "not_attempted": _spec(
        "not_attempted", "runtime",
        "The item was queued but never attempted."),
    # ---- media / visual feedback -------------------------------------------
    "image_unavailable": _spec(
        "image_unavailable", "media",
        "The image could not be read from disk for the MCP image content block."),
    "unsupported_image_type": _spec(
        "unsupported_image_type", "media",
        "The image MIME type is not in the supported set (png/jpeg/webp)."),
    "image_too_large": _spec(
        "image_too_large", "media",
        "The image exceeds the size budget for one MCP response."),
    "corrupt_image": _spec(
        "corrupt_image", "media",
        "The bytes are not decodable as the declared image type (bad base64 or bad header)."),
    "image_path_not_allowed": _spec(
        "image_path_not_allowed", "media",
        "The image path is outside the allowed screenshot roots."),
}


#: MAXScript ``mcpFail`` key -> canonical code.  Keys are the stable identifiers
#: in ``src/ms/mcp_core.ms`` (``mcpMessages``), not the localized text.
MAX_ERROR_MAP: Dict[str, str] = {
    "err.missing_param": "invalid_arguments",
    "err.bad_value": "invalid_arguments",
    "err.invalid_argument": "invalid_arguments",
    "err.invalid_subobject_level": "invalid_arguments",
    "err.node_not_found": "object_not_found",
    "err.no_selection": "empty_selection",
    "err.class_missing": "unsupported_class",
    "err.poly_required": "wrong_object_type",
    "err.file_missing": "file_not_found",
    "err.confirm_required": "confirmation_required",
    "err.unknown_method": "unknown_method",
    "err.not_found_in_list": "item_not_found",
    "err.render_engine": "render_engine_unavailable",
    "err.element_api_missing": "unsupported_feature",
    # kinds emitted by mcp_net.ms itself (not via mcpFail)
    "runtime_error": "max_runtime_error",
    "error": "max_command_failed",
}

#: ``BridgeError.kind`` -> canonical code.  These are the transport categories
#: the Python client assigns; they must not leak as ambiguous words like
#: "timeout" (is that Max's timeout or the socket's?).
BRIDGE_KIND_MAP: Dict[str, str] = {
    "not_running": "bridge_not_running",
    "timeout": "bridge_timeout",
    "protocol_error": "bridge_protocol_error",
    "disconnected": "bridge_disconnected",
    "command_error": "max_command_failed",
    "bridge_error": "bridge_error",
}

#: Codes that mean "the request never reached Max in a usable way".  A batch that
#: hits one of these must stop instead of burning through the remaining objects.
TRANSPORT_CODES = frozenset({
    "bridge_not_running",
    "bridge_timeout",
    "bridge_protocol_error",
    "bridge_disconnected",
    "bridge_error",
})


# ----------------------------------------------------------------------- helpers
def classify(raw: Optional[str]) -> str:
    """Map a MAXScript/bridge kind onto a canonical code.

    Unknown values are passed through lower-cased: keeping an undocumented reason
    is strictly more useful than replacing it with ``command_error``.
    """
    if not raw:
        return "max_command_failed"
    text = str(raw).strip()
    if not text:
        return "max_command_failed"
    if text in ERROR_SPECS:
        return text
    mapped = MAX_ERROR_MAP.get(text)
    if mapped:
        return mapped
    # tolerate "Err.Node_Not_Found" and other casing drift from the wire
    lowered = text.lower()
    if lowered in MAX_ERROR_MAP:
        return MAX_ERROR_MAP[lowered]
    if lowered in BRIDGE_KIND_MAP:
        return BRIDGE_KIND_MAP[lowered]
    if lowered in ERROR_SPECS:
        return lowered
    return lowered


def spec_for(code: str) -> Optional[ErrorSpec]:
    return ERROR_SPECS.get(code)


def retryable(code: str) -> bool:
    spec = ERROR_SPECS.get(code)
    return bool(spec.retryable) if spec else False


def is_transport_failure(code: str) -> bool:
    return code in TRANSPORT_CODES


def error(code: str, message: str = "", **extra: Any) -> Dict[str, Any]:
    """One machine-readable failure entry.

    ``kind`` is the stable code (kept for backwards compatibility with the
    existing runtime envelope); ``code`` mirrors it for clients that use the
    ``error.code`` naming the server already emits.
    """
    canonical = classify(code)
    entry: Dict[str, Any] = {
        "kind": canonical,
        "code": canonical,
        "message": message or (spec_for(canonical).summary if spec_for(canonical) else "Operation failed"),
    }
    if retryable(canonical):
        entry["retryable"] = True
    for key, value in extra.items():
        if value is not None:
            entry[key] = value
    return entry


def from_exception(exc: BaseException, stage: str = "") -> Dict[str, Any]:
    """Turn a bridge/transport exception into a stable failure entry.

    ``BridgeError.code`` already carries the classified MAXScript kind (see
    ``MaxBridge._parse``); ``BridgeError.kind`` is the transport category and is
    only used when no code is present.
    """
    raw = getattr(exc, "code", None) or getattr(exc, "kind", None) or "bridge_error"
    canonical = classify(raw)
    entry = error(canonical, str(exc), stage=stage or None)
    detail = getattr(exc, "detail", None)
    if isinstance(detail, dict) and detail:
        # The raw error dict is useful for debugging but may contain localized
        # text; keep it nested so the stable fields stay on top.
        entry["detail"] = detail
    return entry
