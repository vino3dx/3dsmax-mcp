"""Small, transport-independent Scene Runtime primitives.

The runtime deliberately knows nothing about MAXScript.  It receives a bridge
callable and turns an operation into an auditable record: optional before/after
snapshots, the raw operation result, and a verification result.  This is the
first layer above the adapter where recovery and read-back policy can be added
without duplicating it in every catalog handler.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import itertools
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import errors


BridgeCall = Callable[[str, Dict[str, Any]], Any]
Verify = Callable[[Any, Any, Any], Any]
Recover = Callable[[str], Any]
_OPERATION_IDS = itertools.count(1)

#: Keys a MAXScript handler uses to enumerate what it actually did.  When one of
#: them is a list, the handler has declared an outcome even without a
#: ``success`` flag - ``{applied: [...], failures: []}`` is the dominant shape in
#: ``src/ms`` (``mcp_poly.ms``, ``mcp_modifiers.ms``, ``mcp_shading.ms``).
#:
#: ``results`` is the per-item variant used by the selection and modifier
#: handlers: an empty list means nothing was processed, which is not success.
_OUTCOME_KEYS = ("applied", "deleted", "created", "objects", "results")

#: Receipt fields: the handler named the artefact it produced - a written path, a
#: created group, the objects it moved.  The *name* is the claim and the *value*
#: is the evidence, so the same key reads correctly as a bool (``written: true``),
#: a path (``saved: "C:/a.max"``) or a list (``moved: ["Box001"]``).
#:
#: ``message`` is deliberately absent.  Every handler returns one, including the
#: ones that did nothing, so treating it as a conclusion would turn "no evidence"
#: into "success" - the exact mistake this function exists to prevent.
_RECEIPT_KEYS = (
    "saved", "written", "opened", "merged", "copied", "reset",
    "group", "layer", "moved", "aligned", "attached", "detached",
    "children", "linked", "bones", "goals", "renamed", "ungrouped",
)


def _receipt_verdict(value: Any) -> Optional[bool]:
    """Read one receipt value; ``None`` means it cannot decide anything."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (list, tuple)):
        return len(value) > 0
    if isinstance(value, int):
        return value > 0
    return None


def declared_outcome(source: Dict[str, Any]) -> Optional[Tuple[bool, str]]:
    """Read the outcome a MAXScript handler declared, in the shape it used.

    Returns ``(success, source)`` or ``None`` when the payload says nothing about
    its own outcome.

    Why this exists: the runtime used to accept only ``success``/``ok``, so in
    reliability mode (``--profile core``) every tool whose handler answers
    ``{applied, failures, message}`` was reported as ``missing_success`` - the
    operation ran and worked, but the envelope claimed failure.  Reading the
    handler's own enumeration keeps the strict rule ("no evidence is not
    success") *and* stops it from mislabelling the whole poly/modifier/material
    surface.

    It does not invent success: a non-empty ``failures`` list is a failure, and
    an enumeration that is present but empty (with no ``failures`` key) means the
    handler reported doing nothing - which is not a success claim either.

    Receipt fields come last and are read by value, not by presence: an empty
    path, an empty list or ``written: false`` is a failure, so a handler that
    returned ``{saved: ""}`` still cannot claim to have saved anything.
    """
    if isinstance(source.get("success"), bool):
        return bool(source["success"]), "success"
    if isinstance(source.get("ok"), bool):
        return bool(source["ok"]), "ok"
    failures = source.get("failures")
    if isinstance(failures, list):
        return (not failures), "failures"
    # Enumerations decide by value, not by being a list: some handlers answer
    # ``created: true`` / ``deleted: true`` while others list names under the
    # same key, and a boolean is just as much a claim as a non-empty array.
    # Reading only the list form left scene_new and delete_file answering
    # missing_success after doing exactly what they were asked.
    for key in _OUTCOME_KEYS:
        if key not in source:
            continue
        verdict = _receipt_verdict(source[key])
        if verdict is not None:
            return verdict, key
    for key in _RECEIPT_KEYS:
        if key not in source:
            continue
        verdict = _receipt_verdict(source[key])
        if verdict is not None:
            return verdict, key
    return None


def normalize_payload(raw: Any, operation: str, *, changed: bool = False,
                      operation_id: str = "") -> Dict[str, Any]:
    """Adapt a legacy bridge payload without turning missing success into success."""
    source = dict(raw) if isinstance(raw, dict) else {"value": raw}
    declared = declared_outcome(source)
    if declared is not None:
        success = declared[0]
    else:
        success = False

    failures = list(source.get("failures") or [])
    if declared is None:
        failures.append({
            "kind": "missing_success",
            "message": "Bridge payload did not declare success=true/false",
        })
    if not success and not failures:
        failures.append({
            "kind": "operation_failed",
            "message": source.get("message") or source.get("error") or "Operation failed",
        })

    payload: Dict[str, Any] = {
        "success": success,
        "operation": operation,
        "changed": bool(source.get("changed", changed)),
        "warnings": list(source.get("warnings") or []),
        "failures": failures,
        "verification": source.get("verification") or {
            "performed": False, "passed": None, "detail": None
        },
        "data": source.get("data", source.get("result", source)),
    }
    if operation_id:
        payload["operation_id"] = operation_id
    if "objects" in source:
        payload["objects"] = source["objects"]
    return payload


def build_batch_result(operation: str, items: List[Dict[str, Any]], *, changed: Optional[bool] = None) -> Dict[str, Any]:
    """Build a conservative per-object result; partial success is never overall success."""
    normalized: List[Dict[str, Any]] = []
    for item in items:
        row = dict(item)
        row["success"] = row.get("success") is True
        row["verified"] = bool(row.get("verified")) and row["success"]
        if not row["success"] and not row.get("error"):
            row["error"] = errors.error("item_failed", "Batch item failed")
        normalized.append(row)
    succeeded = sum(1 for row in normalized if row["success"])
    verified_rows = [row for row in normalized if row["verified"]]
    return {
        "success": bool(normalized) and succeeded == len(normalized),
        "operation": operation,
        "changed": bool(changed if changed is not None else succeeded > 0),
        "objects": normalized,
        "summary": {
            "total": len(normalized),
            "succeeded": succeeded,
            "failed": len(normalized) - succeeded,
        },
        "warnings": [],
        "failures": [] if succeeded == len(normalized) else [errors.error(
            "partial_success" if succeeded else "batch_failed",
            "One or more batch items failed",
        )],
        # Not verified is not the same as verified-and-failed.
        "verification": {
            "performed": bool(verified_rows),
            "passed": (all(row["success"] for row in verified_rows)
                       if len(verified_rows) == len(normalized) and verified_rows else None),
            "detail": None,
        },
    }


def resolve_object_refs(requested: List[Any], available: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Resolve names conservatively; reject ambiguity and stale references.

    A scene may legitimately contain two nodes with the same name (Max allows
    it), and a name may point at nothing after a delete/rename.  Neither case may
    silently resolve to "the first match": the caller gets an explicit refusal so
    it can re-read the scene and retry with a proven identity.
    """
    result: List[Dict[str, Any]] = []
    for ref in requested:
        if isinstance(ref, dict):
            name = ref.get("name")
        else:
            name = ref
        if not isinstance(name, str) or not name.strip():
            result.append({
                "success": False,
                "name": name,
                "error": errors.error(
                    "invalid_object_reference",
                    "Object reference carries no usable name",
                ),
            })
            continue
        matches = [obj for obj in available if isinstance(obj, dict) and obj.get("name") == name]
        if len(matches) > 1:
            result.append({"success": False, "name": name, "error": errors.error(
                "ambiguous_object",
                "{0} scene objects share this name".format(len(matches)),
                candidates=len(matches),
            )})
        elif not matches:
            result.append({"success": False, "name": name, "error": errors.error(
                "stale_object_reference",
                "The reference no longer matches any scene object",
            )})
        else:
            node = matches[0]
            result.append({
                "success": True,
                "name": name,
                "object": node,
                # Diagnostics only: a handle is not treated as a durable ID until
                # a read-back has proved it still resolves.
                "object_ref": {"name": name, "handle": node.get("handle")},
            })
    return result


@dataclass
class Verification:
    performed: bool = False
    passed: Optional[bool] = None
    detail: Any = None

    def as_dict(self) -> Dict[str, Any]:
        return {
            "performed": self.performed,
            "passed": self.passed,
            "detail": self.detail,
        }


@dataclass
class OperationResult:
    """Stable result envelope for Scene Runtime operations."""

    operation: str
    success: bool
    operation_id: str = ""
    changed: bool = False
    result: Any = None
    before: Any = None
    after: Any = None
    warnings: List[Dict[str, Any]] = field(default_factory=list)
    failures: List[Dict[str, Any]] = field(default_factory=list)
    verification: Verification = field(default_factory=Verification)
    recovery: Optional[Dict[str, Any]] = None

    def as_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "success": self.success,
            "operation": self.operation,
            "operation_id": self.operation_id,
            "changed": self.changed,
            "warnings": list(self.warnings),
            "failures": list(self.failures),
            "verification": self.verification.as_dict(),
        }
        if self.recovery is not None:
            payload["recovery"] = self.recovery
        if self.result is not None:
            payload["result"] = self.result
            payload["data"] = self.result
            if isinstance(self.result, dict) and "objects" in self.result:
                payload["objects"] = self.result["objects"]
        if self.before is not None:
            payload["before"] = self.before
        if self.after is not None:
            payload["after"] = self.after
        return payload


class SceneRuntime:
    """Execute bridge operations with explicit scene read-back policy.

    ``snapshot_method`` is normally ``scene_info``.  It is injectable so the
    runtime can be tested with a fake bridge and so future domains can use a
    narrower snapshot (for example an object or mesh snapshot).
    """

    def __init__(self, call: BridgeCall, snapshot_method: str = "scene_info") -> None:
        self._call = call
        self.snapshot_method = snapshot_method

    def snapshot(self) -> Any:
        return self._call(self.snapshot_method, {})

    @staticmethod
    def _bridge_failure(exc: Exception, stage: str = "") -> Dict[str, Any]:
        # One taxonomy for every layer: transport errors keep their bridge_*
        # code, MAXScript errors keep the kind the handler declared
        # (object_not_found, empty_selection, ...) instead of all collapsing
        # into "command_error".
        return errors.from_exception(exc, stage=stage)

    @staticmethod
    def _default_verify(operation: str, result: Any, before: Any, after: Any) -> Any:
        """Verify only invariants whose meaning is unambiguous across Max versions."""
        if not isinstance(before, dict) or not isinstance(after, dict):
            return None
        old = before.get("objectCount")
        new = after.get("objectCount")
        if not isinstance(old, int) or not isinstance(new, int):
            return None
        object_creators = {
            "create_arc", "create_box", "create_capsule", "create_chamferbox",
            "create_circle", "create_cone", "create_cylinder", "create_donut",
            "create_ellipse", "create_geosphere", "create_hedra", "create_helix",
            "create_line", "create_ngon", "create_plane", "create_primitive",
            "create_pyramid", "create_rectangle", "create_sphere", "create_teapot",
            "create_text", "create_torus", "create_tube",
        }
        if operation in object_creators:
            return {"kind": "object_count", "expected": "increase", "passed": new > old}
        if operation == "delete_objects":
            return {"kind": "object_count", "expected": "decrease", "passed": new < old}
        if operation in ("scene_new", "scene_reset"):
            return {"kind": "object_count", "expected": "zero", "passed": new == 0}
        return None

    def execute(
        self,
        operation: str,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        *,
        mutating: bool = True,
        verify: Optional[Verify] = None,
        recover: Optional[Recover] = None,
    ) -> OperationResult:
        """Run one operation and optionally verify its real post-state.

        Bridge exceptions are intentionally converted into structured failures
        at this boundary; callers still receive a result envelope instead of a
        half-shaped success response.  The exception text remains diagnostic
        data and is not treated as a successful Max result.
        """
        operation_id = "op-{0:08d}".format(next(_OPERATION_IDS))
        before = None
        if mutating:
            try:
                before = self.snapshot()
            except Exception as exc:
                return OperationResult(
                    operation=operation,
                    success=False,
                    operation_id=operation_id,
                    failures=[self._bridge_failure(exc, "before")],
                )
        try:
            result = self._call(method, params or {})
        except Exception as exc:  # adapter-specific errors stay below runtime
            recovery = None
            if recover is not None:
                recovery = {"attempted": True, "passed": False}
                try:
                    recovery["detail"] = recover(operation_id)
                    recovery["passed"] = True
                except Exception as recovery_exc:
                    recovery["detail"] = str(recovery_exc)
            return OperationResult(
                operation=operation,
                success=False,
                operation_id=operation_id,
                before=before,
                failures=[self._bridge_failure(exc, "execute")],
                recovery=recovery,
            )

        after = None
        if mutating:
            try:
                after = self.snapshot()
            except Exception as exc:
                return OperationResult(
                    operation=operation,
                    success=False,
                    operation_id=operation_id,
                    changed=True,
                    result=result,
                    before=before,
                    failures=[self._bridge_failure(exc, "after")],
                )
        verification = Verification()
        failures: List[Dict[str, Any]] = []
        warnings: List[Dict[str, Any]] = []
        if result is None and mutating:
            # {"ok":true,"result":null} means the bridge accepted the command but
            # returned no evidence at all.  That is not a failure, but it is also
            # not something a caller may read as "verified".
            warnings.append(errors.error(
                "empty_result",
                "Bridge returned an empty payload; the operation is unverified",
            ))
        declared = declared_outcome(result) if isinstance(result, dict) else None
        if declared is not None:
            ok, source_key = declared
            if not ok:
                detail = {"outcome_source": source_key}
                if isinstance(result.get("failures"), list):
                    detail["reported"] = result["failures"][:10]
                failures.append(errors.error(
                    "operation_failed",
                    result.get("message") or result.get("error")
                    or "Bridge operation reported failure",
                    detail=detail,
                ))
        elif isinstance(result, dict):
            failures.append(errors.error(
                "missing_success",
                "Bridge payload did not declare success=true/false",
                detail=result,
            ))
        verifier = verify
        if verifier is None:
            default_detail = self._default_verify(operation, result, before, after)
            if default_detail is not None:
                verification.performed = True
                verification.detail = default_detail
                verification.passed = bool(default_detail.get("passed"))
        if verifier is not None:
            verification.performed = True
            try:
                detail = verifier(result, before, after)
                verification.detail = detail
                verification.passed = detail if isinstance(detail, bool) else True
            except Exception as exc:
                verification.passed = False
                verification.detail = str(exc)
                failures.append(errors.error("verification_error", str(exc)))
        if verification.passed is False and not any(
            item.get("kind") == "verification_failed" for item in failures
        ):
            failures.append(errors.error(
                "verification_failed",
                "Scene read-back verification did not pass",
                detail=verification.detail,
            ))
        success = not failures and verification.passed is not False
        recovery = None
        if not success and recover is not None:
            recovery = {"attempted": True, "passed": False}
            try:
                recovery["detail"] = recover(operation_id)
                recovery["passed"] = True
            except Exception as exc:
                recovery["detail"] = str(exc)
        return OperationResult(
            operation=operation,
            success=success,
            operation_id=operation_id,
            changed=bool(mutating and before != after),
            result=result,
            before=before,
            after=after,
            warnings=warnings,
            failures=failures,
            verification=verification,
            recovery=recovery,
        )

