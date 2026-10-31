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
from typing import Any, Callable, Dict, List, Optional


BridgeCall = Callable[[str, Dict[str, Any]], Any]
Verify = Callable[[Any, Any, Any], Any]
Recover = Callable[[str], Any]
_OPERATION_IDS = itertools.count(1)


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
    warnings: List[str] = field(default_factory=list)
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
                    failures=[{"kind": "bridge_error", "stage": "before", "message": str(exc)}],
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
                failures=[{"kind": "bridge_error", "message": str(exc)}],
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
                    failures=[{"kind": "bridge_error", "stage": "after", "message": str(exc)}],
                )
        verification = Verification()
        failures: List[Dict[str, Any]] = []
        if isinstance(result, dict) and result.get("success") is False:
            failures.append({
                "kind": "operation_failed",
                "message": result.get("message") or result.get("error") or "Bridge operation reported failure",
                "detail": result,
            })
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
                failures.append({"kind": "verification_error", "message": str(exc)})
        if verification.passed is False and not any(
            item.get("kind") == "verification_failed" for item in failures
        ):
            failures.append({
                "kind": "verification_failed",
                "message": "Scene read-back verification did not pass",
                "detail": verification.detail,
            })
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
            failures=failures,
            verification=verification,
            recovery=recovery,
        )

