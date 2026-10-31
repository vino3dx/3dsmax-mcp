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

    def execute(
        self,
        operation: str,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        *,
        mutating: bool = True,
        verify: Optional[Verify] = None,
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
            return OperationResult(
                operation=operation,
                success=False,
                operation_id=operation_id,
                before=before,
                failures=[{"kind": "bridge_error", "message": str(exc)}],
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
        if verify is not None:
            verification.performed = True
            try:
                detail = verify(result, before, after)
                verification.detail = detail
                verification.passed = detail if isinstance(detail, bool) else True
            except Exception as exc:
                verification.passed = False
                verification.detail = str(exc)
                failures.append({"kind": "verification_error", "message": str(exc)})
        success = not failures and verification.passed is not False
        return OperationResult(
            operation=operation,
            success=success,
            operation_id=operation_id,
            changed=bool(mutating),
            result=result,
            before=before,
            after=after,
            failures=failures,
            verification=verification,
        )

