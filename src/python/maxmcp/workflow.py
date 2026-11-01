"""A lightweight execution model for multi-step agent scene work.

Why this exists
---------------
Stage 1-2 gave the agent reliable *single* operations: one call, one envelope,
read-back verification, stable error codes.  A scene task, however, is a
sequence ("create a ground, a wall, a cube and a ball, then check the count"),
and sequences fail in ways single calls do not: the third step fails, so the
fifth must not run; a step succeeds but changes nothing; the bridge dies and
every later step is meaningless; a delete is retried and removes two objects.

This module is deliberately *not* a job scheduler:

* it runs steps in order, in one thread, inside one tool call;
* it owns no transport and no error taxonomy - it calls the existing dispatcher
  and reads the envelopes that already exist;
* it does not re-implement verification - :mod:`maxmcp.verify` does that from
  read-back;
* it does not re-implement the scene snapshot - :mod:`maxmcp.scene_state` does.

What it does own is the *policy* between steps: what a status means, when a
dependent step is skipped, which failures abort, which failures may be retried
automatically (almost none - see :func:`retry_decision`), and what the final
workflow status is allowed to claim.

Step statuses
-------------
    pending              not started yet (only in a pre-run record)
    running              currently executing
    success              executed and (when declared) verified
    failed               executed and reported failure
    skipped              never executed (failed dependency, or an earlier abort)
    verification_failed  executed, but the scene does not show the requested state
    interrupted          a transport failure stopped the run here

``success`` means "executed, and every declared verification passed".  A step
whose verification could not run at all is still ``success`` but carries
``verified: false``, and the workflow cannot claim a full success.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from . import errors, scene_state, verify

# ------------------------------------------------------------------- statuses
PENDING = "pending"
RUNNING = "running"
SUCCESS = "success"
FAILED = "failed"
SKIPPED = "skipped"
VERIFICATION_FAILED = "verification_failed"
INTERRUPTED = "interrupted"

STEP_STATUSES = (PENDING, RUNNING, SUCCESS, FAILED, SKIPPED,
                 VERIFICATION_FAILED, INTERRUPTED)

EXECUTION_SUCCESS = "execution_success"
EXECUTION_FAILED = "execution_failed"
EXECUTION_SKIPPED = "execution_skipped"
EXECUTION_INTERRUPTED = "execution_interrupted"

VERIFICATION_PASSED = "verification_passed"
VERIFICATION_FAILED_STATE = "verification_failed"
VERIFICATION_UNAVAILABLE = "verification_unavailable"

WORKFLOW_STATUSES = ("pending", "running", "success", "partial", "failed", "interrupted")

#: Tools whose repeated execution cannot change the outcome.  Everything else
#: that mutates the scene is treated as non-idempotent: a second ``clone_objects``
#: creates a second clone, a second ``delete_objects`` can delete a re-created
#: name, a relative ``transform_object`` moves twice.
IDEMPOTENT_MUTATIONS = frozenset({
    "select_objects",        # replaces/adds a selection; repeating is harmless
    "scene_info",            # read-only, listed for completeness
    "get_selection",
    "get_object_info",
    "find_objects",
    "list_objects",
    "poly_get_stats",
    "mat_list",
    "mat_get",
    "mat_get_for_object",
})

#: Operations that must never be retried automatically under any declaration.
NEVER_RETRY = frozenset({"execute_maxscript", "execute_python"})

MAX_ATTEMPTS = 2


# ------------------------------------------------------------------- outcomes
def _nested_errors(payload: Any, limit: int = 500) -> List[Dict[str, Any]]:
    """Error entries nested inside a batch/reconcile payload.

    Reliability mode returns one row per object, each with its own ``error``.
    Reading only the envelope would lose the cause, so both the row's error and
    the row itself are considered when they carry a code.
    """
    if not isinstance(payload, dict):
        return []
    out: List[Dict[str, Any]] = []
    for key in ("objects", "failures", "results", "steps"):
        items = payload.get(key)
        if not isinstance(items, list):
            continue
        for item in items[:limit]:
            if not isinstance(item, dict):
                continue
            for candidate in (item.get("error"), item):
                if isinstance(candidate, dict) and (candidate.get("code") or candidate.get("kind")):
                    out.append(candidate)
                    break
    return out


@dataclass
class ToolOutcome:
    """What one tool call produced, independent of transport details."""

    ok: bool
    payload: Any = None
    error: Optional[Dict[str, Any]] = None
    images: List[Dict[str, Any]] = field(default_factory=list)
    image_errors: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def code(self) -> str:
        if not isinstance(self.error, dict):
            return ""
        return str(self.error.get("code") or self.error.get("kind") or "")

    @property
    def transport_code(self) -> str:
        """First transport error code in this outcome, or ``""``.

        A batch reply wraps per-object failures in its own envelope, so the
        top-level code can read ``aborted`` while the real cause was a lost
        bridge.  The difference decides whether the step is *interrupted* (the
        scene is in an unknown state) or merely *failed* (Max answered and said
        no), and whether a read-only step may be replayed.
        """
        if errors.is_transport_failure(self.code):
            return self.code
        for item in _nested_errors(self.payload):
            candidate = str(item.get("code") or item.get("kind") or "")
            if errors.is_transport_failure(candidate):
                return candidate
        return ""

    @classmethod
    def from_mapping(cls, value: Any) -> "ToolOutcome":
        """Accept a plain dict so callers/tests can stay dict-shaped."""
        if isinstance(value, ToolOutcome):
            return value
        if not isinstance(value, dict):
            return cls(ok=bool(value), payload=value)
        return cls(
            ok=bool(value.get("ok", value.get("success", False))),
            payload=value.get("payload", value.get("data")),
            error=value.get("error"),
            images=list(value.get("images") or []),
            image_errors=list(value.get("image_errors") or []),
        )


# ----------------------------------------------------------------- definition
@dataclass
class Step:
    """One declarative step: a tool call plus the goal it is supposed to reach."""

    id: str
    operation: str
    arguments: Dict[str, Any] = field(default_factory=dict)
    verify: Optional[Dict[str, Any]] = None
    depends_on: Tuple[str, ...] = ()
    on_failure: str = "abort"          # abort | continue
    retry: str = "never"               # never | transport
    optional: bool = False             # failure degrades to "partial", never aborts
    note_zh: str = ""
    note_en: str = ""

    @classmethod
    def from_dict(cls, raw: Dict[str, Any], index: int) -> "Step":
        if not isinstance(raw, dict):
            raise ValueError("step {0} is not an object".format(index + 1))
        operation = raw.get("operation")
        if not isinstance(operation, str) or not operation:
            raise ValueError("step {0} has no operation".format(index + 1))
        step_id = raw.get("id") or "step_{0:03d}".format(index + 1)
        if not isinstance(step_id, str):
            raise ValueError("step {0} has a non-string id".format(index + 1))
        arguments = raw.get("arguments") or {}
        if not isinstance(arguments, dict):
            raise ValueError("step '{0}' arguments must be an object".format(step_id))
        depends = raw.get("depends_on") or ()
        if isinstance(depends, str):
            depends = (depends,)
        verify_spec = raw.get("verification", raw.get("verify"))
        if verify_spec is not None and not isinstance(verify_spec, dict):
            raise ValueError("step '{0}' verification must be an object".format(step_id))
        on_failure = raw.get("on_failure") or "abort"
        if on_failure not in ("abort", "continue"):
            raise ValueError("step '{0}' on_failure must be abort or continue".format(step_id))
        retry = raw.get("retry") or "never"
        if retry not in ("never", "transport"):
            raise ValueError("step '{0}' retry must be never or transport".format(step_id))
        return cls(
            id=step_id,
            operation=operation,
            arguments=dict(arguments),
            verify=verify_spec,
            depends_on=tuple(str(item) for item in depends),
            on_failure=on_failure,
            retry=retry,
            optional=bool(raw.get("optional")),
            note_zh=str(raw.get("note_zh") or ""),
            note_en=str(raw.get("note_en") or ""),
        )


@dataclass
class Workflow:
    """An ordered list of steps plus the goal the finished scene should show."""

    name: str
    steps: List[Step]
    description_zh: str = ""
    description_en: str = ""
    expect: Dict[str, Any] = field(default_factory=dict)
    capture: bool = True          # snapshot before/after for the scene diff

    def step(self, step_id: str) -> Optional[Step]:
        for item in self.steps:
            if item.id == step_id:
                return item
        return None

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "Workflow":
        if not isinstance(raw, dict):
            raise ValueError("workflow must be an object")
        name = raw.get("name") or raw.get("workflow_id") or "workflow"
        raw_steps = raw.get("steps")
        if not isinstance(raw_steps, list) or not raw_steps:
            raise ValueError("workflow needs a non-empty steps array")
        steps = [Step.from_dict(item, index) for index, item in enumerate(raw_steps)]
        expect = raw.get("expect") or {}
        if not isinstance(expect, dict):
            raise ValueError("workflow expect must be an object")
        return cls(
            name=str(name),
            steps=steps,
            description_zh=str(raw.get("description_zh") or ""),
            description_en=str(raw.get("description_en") or ""),
            expect=dict(expect),
            capture=bool(raw.get("capture", True)),
        )


def validate(workflow: Workflow, known_operations: Optional[Sequence[str]] = None) -> List[str]:
    """Structural problems that must be refused before any step runs."""
    problems: List[str] = []
    seen = set()
    for step in workflow.steps:
        if step.id in seen:
            problems.append("duplicate step id: {0}".format(step.id))
        seen.add(step.id)
    for step in workflow.steps:
        for dependency in step.depends_on:
            if dependency not in seen:
                problems.append("step '{0}' depends on unknown step '{1}'".format(
                    step.id, dependency))
        if step.id in step.depends_on:
            problems.append("step '{0}' depends on itself".format(step.id))
        if step.operation == "workflow_run":
            problems.append("step '{0}': a workflow may not call workflow_run".format(step.id))
        if known_operations is not None and step.operation not in known_operations:
            problems.append("step '{0}': unknown operation '{1}'".format(step.id, step.operation))
        if step.verify is not None:
            kind = step.verify.get("kind")
            if kind not in verify.VERIFY_KINDS:
                problems.append("step '{0}': unknown verification kind '{1}'".format(
                    step.id, kind))
    # Dependency cycles (depth-first, iterative to stay readable for long plans).
    state: Dict[str, int] = {}
    for step in workflow.steps:
        stack = [(step.id, iter(step.depends_on))]
        while stack:
            node, children = stack[-1]
            if state.get(node) is None:
                state[node] = 1
            child = next(children, None)
            if child is None:
                state[node] = 2
                stack.pop()
                continue
            if state.get(child) == 1:
                problems.append("dependency cycle through '{0}'".format(child))
                return problems
            if state.get(child) is None:
                child_step = workflow.step(child)
                stack.append((child, iter(child_step.depends_on if child_step else ())))
    return problems


# --------------------------------------------------------------- retry policy
def retry_decision(step: Step, outcome: ToolOutcome, attempt: int,
                   max_attempts: int = MAX_ATTEMPTS) -> Dict[str, Any]:
    """Decide whether the engine may run this step again, and say why.

    Automatic retry is only ever allowed for a *read-only* operation, or for an
    explicitly idempotent mutation, and only when the failure is a transport
    failure that the error catalogue marks retryable.  Everything else - clone,
    delete, create, a relative transform, any MAXScript escape hatch - is
    refused: repeating it can double the effect, and a doubled destructive
    effect is worse than a reported failure.
    """
    if attempt >= max_attempts:
        return {"retry": False, "reason": "attempts_exhausted", "attempts": attempt}
    if step.retry != "transport":
        return {"retry": False, "reason": "policy_never"}
    if step.operation in NEVER_RETRY:
        return {"retry": False, "reason": "escape_hatch_never_retried"}
    # The nested cause matters: a batch envelope may say "aborted" while the
    # real reason was a lost bridge, and only the real reason can justify a retry.
    code = outcome.transport_code or outcome.code
    if not errors.is_transport_failure(code):
        return {"retry": False, "reason": "not_a_transport_failure", "code": outcome.code}
    if not errors.retryable(code):
        return {"retry": False, "reason": "code_not_retryable", "code": code}
    if step.operation in IDEMPOTENT_MUTATIONS:
        return {"retry": True, "reason": "idempotent_read", "code": code}
    return {
        "retry": False,
        "reason": "non_idempotent_operation",
        "code": code,
        "detail": "{0} may have already changed the scene; re-read it and decide".format(
            step.operation),
    }


# --------------------------------------------------------------------- engine
class WorkflowEngine:
    """Run a :class:`Workflow` against an injected tool dispatcher.

    ``invoke(operation, arguments) -> ToolOutcome | dict`` is the only bridge to
    the rest of the system.  In production it is the MCP server's own execution
    path, so a workflow step behaves exactly like the same tool called by the
    agent - including runtime verification, batch envelopes and error codes.
    """

    def __init__(self, invoke: Callable[[str, Dict[str, Any]], Any], *,
                 capture: Optional[Callable[[], Any]] = None,
                 tolerance: float = scene_state.DEFAULT_TOLERANCE,
                 max_attempts: int = MAX_ATTEMPTS) -> None:
        self._invoke = invoke
        self._capture = capture
        self._tolerance = tolerance
        self._max_attempts = max_attempts
        self._reader = verify.SceneReader(self._read)

    # ------------------------------------------------------------- plumbing
    def _call(self, operation: str, arguments: Dict[str, Any]) -> ToolOutcome:
        try:
            return ToolOutcome.from_mapping(self._invoke(operation, arguments or {}))
        except Exception as exc:  # a dispatcher bug is a failure, not a pass
            return ToolOutcome(ok=False, error=errors.from_exception(exc, "workflow"))

    def _read(self, operation: str, arguments: Dict[str, Any]) -> Any:
        """Read-only probe used by verification; never raises."""
        try:
            outcome = ToolOutcome.from_mapping(self._invoke(operation, arguments or {}))
        except Exception as exc:
            return {"ok": False, "error": errors.from_exception(exc, "readback")}
        return {"ok": outcome.ok, "error": outcome.error, "payload": outcome.payload}

    def _snapshot(self) -> Dict[str, Any]:
        if self._capture is None:
            return {"ok": False, "error": errors.error(
                "snapshot_unavailable", "No snapshot source is configured")}
        try:
            document = self._capture()
        except Exception as exc:
            return {"ok": False, "error": errors.from_exception(exc, "snapshot")}
        return {"ok": True, "document": document}

    # ----------------------------------------------------------------- run
    def run(self, workflow: Workflow, *, workflow_id: str = "",
            known_operations: Optional[Sequence[str]] = None) -> Dict[str, Any]:
        problems = validate(workflow, known_operations)
        identifier = workflow_id or "workflow_{0:03d}".format(next(_WORKFLOW_IDS))
        if problems:
            return {
                "workflow_id": identifier,
                "name": workflow.name,
                "status": FAILED,
                "steps": [],
                "failures": [errors.error("workflow_invalid", "; ".join(problems))],
                "summary": _summarize([]),
                "diff": None,
                "expectation": {"performed": False, "passed": None, "checks": []},
            }

        before: Dict[str, Any] = {"ok": False}
        diff: Optional[Dict[str, Any]] = None
        warnings: List[Dict[str, Any]] = []
        if workflow.capture:
            before = self._snapshot()
            if not before["ok"]:
                warnings.append(errors.error(
                    "snapshot_unavailable",
                    "The scene could not be read before the workflow; "
                    "before/after comparison is unavailable",
                    detail=before.get("error"),
                ))

        before_count = None
        if before.get("ok") and isinstance(before.get("document"), dict):
            before_count = before["document"].get("node_count")

        rows: List[Dict[str, Any]] = []
        statuses: Dict[str, str] = {}
        aborted: Optional[str] = None      # reason for skipping everything after
        interrupted = False

        for step in workflow.steps:
            if aborted is not None:
                rows.append(_skipped_row(step, aborted))
                statuses[step.id] = SKIPPED
                continue
            unmet = [dep for dep in step.depends_on if statuses.get(dep) != SUCCESS]
            if unmet:
                rows.append(_skipped_row(step, "dependency_failed", unmet=unmet))
                statuses[step.id] = SKIPPED
                continue

            row, state = self._run_step(step, before_count=before_count)
            rows.append(row)
            statuses[step.id] = state["status"]

            if state["status"] == INTERRUPTED:
                interrupted = True
                aborted = "interrupted"
                continue
            if state["status"] in (FAILED, VERIFICATION_FAILED):
                if step.optional:
                    continue
                if step.on_failure == "abort":
                    aborted = "aborted_after_failure"

        after: Dict[str, Any] = {"ok": False}
        if workflow.capture:
            after = self._snapshot()
            if not after["ok"]:
                warnings.append(errors.error(
                    "snapshot_unavailable",
                    "The scene could not be read after the workflow; "
                    "before/after comparison is unavailable",
                    detail=after.get("error"),
                ))
        if before.get("ok") and after.get("ok"):
            diff = scene_state.diff_documents(before.get("document"),
                                              after.get("document"), self._tolerance)

        expectation = scene_state.check_expectations(
            workflow.expect, diff, (after.get("document") if after.get("ok") else None))

        summary = _summarize(rows)
        status = _workflow_status(rows, interrupted=interrupted,
                                  expectation=expectation if workflow.expect else None)
        return {
            "workflow_id": identifier,
            "name": workflow.name,
            "status": status,
            "steps": rows,
            "summary": summary,
            "diff": diff,
            "expectation": expectation,
            "warnings": warnings,
            "failures": _workflow_failures(rows, status),
        }

    # ------------------------------------------------------------ one step
    def _run_step(self, step: Step, *, before_count: Optional[int]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        attempts = 0
        retry_log: List[Dict[str, Any]] = []
        outcome = ToolOutcome(ok=False)
        while True:
            attempts += 1
            outcome = self._call(step.operation, step.arguments)
            if outcome.ok:
                break
            decision = retry_decision(step, outcome, attempts, self._max_attempts)
            retry_log.append({"attempt": attempts,
                              "code": outcome.code,
                              "retry": decision["retry"],
                              "reason": decision["reason"]})
            if not decision["retry"]:
                break

        row: Dict[str, Any] = {
            "id": step.id,
            "operation": step.operation,
            "arguments": step.arguments,
            "attempts": attempts,
            "retry": retry_log,
            "optional": step.optional,
            "execution": EXECUTION_SUCCESS,
            "verification": {
                "status": VERIFICATION_UNAVAILABLE,
                "performed": False,
                "passed": None,
                "detail": None,
            },
            "verified": False,
            "status": SUCCESS,
            "result": outcome.payload,
            "images": outcome.images,
            "error": None,
        }
        if step.note_zh or step.note_en:
            row["note_zh"] = step.note_zh
            row["note_en"] = step.note_en

        if not outcome.ok:
            code = outcome.code or "operation_failed"
            transport = bool(outcome.transport_code)
            row["execution"] = EXECUTION_INTERRUPTED if transport else EXECUTION_FAILED
            row["status"] = INTERRUPTED if transport else FAILED
            row["error"] = outcome.error or errors.error(code, "Step failed")
            if transport and outcome.transport_code != code:
                # Keep the envelope code visible but name the real cause, so the
                # caller can tell "Max said no" from "the bridge vanished".
                row["error"] = dict(row["error"] or {})
                row["error"]["transport_code"] = outcome.transport_code
            blocked = [item for item in retry_log if item["reason"] in
                       ("non_idempotent_operation", "escape_hatch_never_retried")]
            if blocked:
                row["retry_blocked"] = {
                    "kind": "retry_blocked",
                    "reason": blocked[-1]["reason"],
                    "detail": "Automatic retry refused because the operation is not "
                              "idempotent; re-read the scene before deciding.",
                }
            row["recovery"] = self._recover(step)
            return row, {"status": row["status"]}

        ctx = {
            "payload": outcome.payload,
            "images": outcome.images,
            "image_errors": outcome.image_errors,
            "reader": self._reader,
            "before_count": before_count,
        }
        verification = verify.evaluate(step.verify, ctx)
        performed = bool(verification.get("performed"))
        passed = verification.get("passed")
        if performed and passed is True:
            vstatus = VERIFICATION_PASSED
            row["status"] = SUCCESS
            row["verified"] = True
        elif performed and passed is False:
            vstatus = VERIFICATION_FAILED_STATE
            row["status"] = VERIFICATION_FAILED
            row["verified"] = False
        else:
            vstatus = VERIFICATION_UNAVAILABLE
            row["status"] = SUCCESS
            row["verified"] = False
        row["verification"] = {
            "status": vstatus,
            "performed": performed,
            "passed": passed,
            "detail": verification.get("detail"),
            "kind": verification.get("kind"),
            "spec": verification.get("spec"),
        }
        if row["status"] == VERIFICATION_FAILED:
            row["error"] = errors.error(
                "verification_failed",
                "The scene read-back does not show the state this step asked for",
                step=step.id,
                verification=verification.get("kind"),
            )
            row["recovery"] = self._recover(step)
        return row, {"status": row["status"]}

    # ----------------------------------------------------------- recovery
    def _recover(self, step: Step) -> Dict[str, Any]:
        """Re-read the scene after a failure; never retry on our own.

        The point is to hand the agent evidence: is the bridge still alive, is
        the scene still readable, and what does the count look like now.  A
        destructive step that "failed" may still have taken effect, so the
        answer is a fresh observation, not a guess.
        """
        count_status, count_value = self._reader.count()
        readable = count_status == "ok"
        recovery: Dict[str, Any] = {
            "attempted": True,
            "scene_readable": readable,
            "object_count": count_value if readable else None,
            "automatic_retry": False,
            "note_zh": "失败后已重新读取场景；是否重试由调用方按实际状态决定。",
            "note_en": "The scene was re-read after the failure; the caller decides "
                       "whether to retry, based on the observed state.",
        }
        selection_status, selection_value = self._reader.selection()
        if selection_status == "ok":
            recovery["selection"] = selection_value
        return recovery


_WORKFLOW_IDS = itertools.count(1)


def _skipped_row(step: Step, reason: str, **extra: Any) -> Dict[str, Any]:
    row: Dict[str, Any] = {
        "id": step.id,
        "operation": step.operation,
        "arguments": step.arguments,
        "attempts": 0,
        "execution": EXECUTION_SKIPPED,
        "status": SKIPPED,
        "skip_reason": reason,
        "verification": {"status": VERIFICATION_UNAVAILABLE, "performed": False,
                         "passed": None, "detail": None},
        "verified": False,
        "result": None,
        "error": errors.error(
            "dependency_failed" if reason == "dependency_failed" else "not_attempted",
            "Step was not executed: {0}".format(reason),
        ),
        "optional": step.optional,
    }
    row.update(extra)
    return row


def _summarize(rows: List[Dict[str, Any]]) -> Dict[str, int]:
    def count(predicate) -> int:
        return sum(1 for row in rows if predicate(row))

    return {
        "total": len(rows),
        "succeeded": count(lambda r: r.get("status") == SUCCESS),
        "failed": count(lambda r: r.get("status") == FAILED),
        "skipped": count(lambda r: r.get("status") == SKIPPED),
        "verification_failed": count(lambda r: r.get("status") == VERIFICATION_FAILED),
        "interrupted": count(lambda r: r.get("status") == INTERRUPTED),
        "verified": count(lambda r: r.get("verified") is True),
        "unverified": count(lambda r: r.get("status") == SUCCESS
                            and r.get("verified") is not True),
    }


def _workflow_status(rows: List[Dict[str, Any]], *, interrupted: bool,
                     expectation: Optional[Dict[str, Any]]) -> str:
    """What the finished run is allowed to claim.

    A run is only ``success`` when every step executed, every declared check
    passed, and the goal-level expectation held.  Anything weaker is reported as
    ``partial`` - never upgraded to success because the steps "mostly" worked.
    """
    if interrupted or any(row.get("status") == INTERRUPTED for row in rows):
        return "interrupted"
    hard_failures = [row for row in rows
                     if row.get("status") in (FAILED, VERIFICATION_FAILED)
                     and not row.get("optional")]
    if hard_failures:
        return "failed"
    degraded = (
        any(row.get("status") == SKIPPED for row in rows)
        or any(row.get("status") in (FAILED, VERIFICATION_FAILED) for row in rows)
        or any(row.get("status") == SUCCESS and row.get("verified") is not True for row in rows)
    )
    if expectation is not None and expectation.get("passed") is not True:
        degraded = True
    if degraded:
        return "partial"
    if not rows:
        return "failed"
    return "success"


def _workflow_failures(rows: List[Dict[str, Any]], status: str) -> List[Dict[str, Any]]:
    """One entry per failed step, plus one for an aborted tail."""
    out: List[Dict[str, Any]] = []
    for row in rows:
        if row.get("status") in (FAILED, VERIFICATION_FAILED, INTERRUPTED):
            entry = dict(row.get("error") or {})
            entry.setdefault("kind", "operation_failed")
            entry.setdefault("code", entry["kind"])
            entry["step"] = row["id"]
            entry["operation"] = row["operation"]
            out.append(entry)
    if status == "interrupted" and not any(item.get("kind") == "workflow_interrupted" for item in out):
        out.append(errors.error(
            "workflow_interrupted",
            "A transport failure stopped the workflow before the remaining steps ran",
        ))
    skipped = [row for row in rows if row.get("status") == SKIPPED]
    if skipped and status in ("failed", "interrupted"):
        out.append(errors.error(
            "not_attempted",
            "{0} step(s) were skipped after the failure".format(len(skipped)),
            steps=[row["id"] for row in skipped],
        ))
    return out


# --------------------------------------------------------- standard workflows
def _step(index: int, step_id: str, operation: str, arguments: Dict[str, Any],
          verification: Optional[Dict[str, Any]] = None,
          depends_on: Sequence[str] = (), **extra: Any) -> Step:
    return Step(
        id=step_id,
        operation=operation,
        arguments=arguments,
        verify=verification,
        depends_on=tuple(depends_on),
        on_failure=extra.pop("on_failure", "abort"),
        retry=extra.pop("retry", "never"),
        optional=extra.pop("optional", False),
        note_zh=extra.pop("note_zh", ""),
        note_en=extra.pop("note_en", ""),
    )


BASIC_SCENE = Workflow(
    name="basic_scene",
    description_zh="搭建一个包含地面、墙体、立方体和球体的基础场景，并核对对象数量与变换。",
    description_en="Build a simple scene with a ground plane, a wall, a cube and a "
                   "sphere, then check the object count and the transforms.",
    steps=[
        _step(1, "precondition", "scene_info", {},
              {"kind": "read_ok", "fields": ["objectCount"]},
              note_zh="先读一次场景，确认桥接与场景可读。",
              note_en="Read the scene once to confirm the bridge and the scene are readable."),
        _step(2, "ground", "create_plane",
              {"name": "Ground", "length": 200, "width": 200, "position": [0, 0, 0]},
              {"kind": "exists", "objects": ["Ground"]}, depends_on=["precondition"]),
        _step(3, "wall", "create_box",
              {"name": "Wall", "length": 10, "width": 200, "height": 80,
               "position": [0, 105, 40]},
              {"kind": "exists", "objects": ["Wall"]}, depends_on=["precondition"]),
        _step(4, "cube", "create_box",
              {"name": "Cube", "length": 40, "width": 40, "height": 40,
               "position": [-40, 0, 20]},
              {"kind": "exists", "objects": ["Cube"]}, depends_on=["precondition"]),
        _step(5, "ball", "create_sphere",
              {"name": "Ball", "radius": 20, "position": [40, 0, 20]},
              {"kind": "exists", "objects": ["Ball"]}, depends_on=["precondition"]),
        _step(6, "place_cube", "transform_object",
              {"objects": ["Cube"], "operation": "move", "mode": "absolute",
               "value": [-50, 0, 20]},
              {"kind": "transform", "object": "Cube", "position": [-50, 0, 20]},
              depends_on=["cube"]),
        _step(7, "place_ball", "transform_object",
              {"objects": ["Ball"], "operation": "move", "mode": "absolute",
               "value": [50, 0, 20]},
              {"kind": "transform", "object": "Ball", "position": [50, 0, 20]},
              depends_on=["ball"]),
        _step(8, "count_check", "scene_info", {},
              {"kind": "count", "atLeast": 4}, depends_on=["place_cube", "place_ball"]),
        _step(9, "object_state", "find_objects", {"name": "Cube", "exact": True},
              {"kind": "exists", "objects": ["Cube"]}, depends_on=["place_cube"],
              note_zh="复核单个对象确实存在且唯一。",
              note_en="Re-check that the single object exists and is unique."),
        _step(10, "visual", "vision_capture", {"max_edge": 640},
              {"kind": "image"}, depends_on=["count_check"],
              on_failure="continue", optional=True,
              note_zh="视觉反馈：拿不到图不视为场景搭建失败。",
              note_en="Visual feedback: a missing image does not fail the build."),
    ],
    expect={"added_includes": ["Ground", "Wall", "Cube", "Ball"], "count_delta": 4},
)


MODEL_PROCESSING = Workflow(
    name="model_processing",
    description_zh="把一个已有对象转为 Editable Poly，做一次面挤出并添加 TurboSmooth，"
                   "再核对类型、修改器与面数。",
    description_en="Convert an existing object to Editable Poly, extrude a face group, "
                   "add TurboSmooth, then check the class, modifier list and face count.",
    steps=[
        _step(1, "find_target", "find_objects", {"name": "Cube", "exact": True},
              {"kind": "exists", "objects": ["Cube"]},
              note_zh="确认目标对象存在且唯一，后续步骤都以名称引用它。",
              note_en="Confirm the target exists and is unique; later steps refer to it by name."),
        _step(2, "identity", "get_object_info", {"name": "Cube"},
              {"kind": "class", "object": "Cube", "allowed": ["Box", "Editable_Poly"]},
              depends_on=["find_target"],
              note_zh="记录操作前的类型，作为身份证据。",
              note_en="Record the pre-operation class as identity evidence."),
        _step(3, "to_poly", "convert_to_editable_poly", {"objects": ["Cube"]},
              {"kind": "class", "object": "Cube", "allowed": ["Editable_Poly"]},
              depends_on=["identity"]),
        _step(4, "stats_before", "poly_get_stats", {"objects": ["Cube"]},
              {"kind": "payload_number", "field": "faces", "atLeast": 1},
              depends_on=["to_poly"]),
        _step(5, "select_faces", "poly_select_faces",
              {"objects": ["Cube"], "normalAxis": "z", "normalSign": "+"},
              {"kind": "payload_number", "field": "faces", "atLeast": 1},
              depends_on=["stats_before"],
              note_zh="只按法线方向选面，不依赖上一次的选择集。",
              note_en="Select faces by normal direction only, never by leftover selection."),
        _step(6, "extrude", "poly_extrude_faces", {"objects": ["Cube"], "amount": 10},
              {"kind": "face_count", "object": "Cube", "atLeast": 6},
              depends_on=["select_faces"]),
        _step(7, "smooth", "mod_add", {"objects": ["Cube"], "modifier": "TurboSmooth"},
              {"kind": "modifier", "object": "Cube", "modifier": "TurboSmooth"},
              depends_on=["extrude"]),
        _step(8, "stats_after", "poly_get_stats", {"objects": ["Cube"]},
              {"kind": "payload_number", "field": "faces", "atLeast": 6},
              depends_on=["smooth"]),
        _step(9, "final_state", "get_object_info", {"name": "Cube"},
              {"kind": "modifier", "object": "Cube", "modifier": "TurboSmooth"},
              depends_on=["stats_after"]),
        _step(10, "visual", "vision_capture", {"max_edge": 640},
              {"kind": "image"}, depends_on=["final_state"],
              on_failure="continue", optional=True),
    ],
    expect={"modified_includes": ["Cube"]},
)


MATERIAL_LOOK = Workflow(
    name="material_look",
    description_zh="为场景中的对象分别创建并分配两个标准材质，再核对每个对象上的材质。",
    description_en="Create two standard materials, assign them to different objects, "
                   "then check the material recorded on each object.",
    steps=[
        _step(1, "material_list", "mat_list", {},
              {"kind": "read_ok", "fields": ["materials"]},
              note_zh="先看场景里已有哪些材质，避免重复创建同名材质。",
              note_en="List the existing materials first so a same-named one is not duplicated."),
        _step(2, "create_red", "mat_create_standard",
              {"name": "MatteRed", "diffuse": [200, 40, 40]},
              {"kind": "read_ok"}, depends_on=["material_list"]),
        _step(3, "create_blue", "mat_create_standard",
              {"name": "MatteBlue", "diffuse": [40, 70, 200]},
              {"kind": "read_ok"}, depends_on=["material_list"]),
        _step(4, "assign_ground", "mat_assign",
              {"material": "MatteRed", "objects": ["Ground"]},
              {"kind": "material", "object": "Ground", "material": "MatteRed"},
              depends_on=["create_red"]),
        _step(5, "assign_ball", "mat_assign",
              {"material": "MatteBlue", "objects": ["Ball"]},
              {"kind": "material", "object": "Ball", "material": "MatteBlue"},
              depends_on=["create_blue"]),
        _step(6, "verify_ground", "mat_get_for_object", {"objects": ["Ground", "Ball"]},
              {"kind": "read_ok"}, depends_on=["assign_ground", "assign_ball"]),
        _step(7, "visual", "vision_capture", {"max_edge": 640},
              {"kind": "image"}, depends_on=["verify_ground"],
              on_failure="continue", optional=True),
    ],
    expect={"modified_includes": ["Ground", "Ball"]},
)


STANDARD_WORKFLOWS: Dict[str, Workflow] = {
    workflow.name: workflow
    for workflow in (BASIC_SCENE, MODEL_PROCESSING, MATERIAL_LOOK)
}


def list_workflows() -> List[Dict[str, Any]]:
    return [
        {
            "name": workflow.name,
            "description_zh": workflow.description_zh,
            "description_en": workflow.description_en,
            "steps": len(workflow.steps),
            "operations": [step.operation for step in workflow.steps],
        }
        for workflow in STANDARD_WORKFLOWS.values()
    ]


def get_workflow(name: str) -> Optional[Workflow]:
    return STANDARD_WORKFLOWS.get(name)


__all__ = [
    "ToolOutcome", "Step", "Workflow", "WorkflowEngine",
    "STANDARD_WORKFLOWS", "list_workflows", "get_workflow", "validate",
    "retry_decision", "STEP_STATUSES", "WORKFLOW_STATUSES",
    "PENDING", "RUNNING", "SUCCESS", "FAILED", "SKIPPED",
    "VERIFICATION_FAILED", "INTERRUPTED",
]
