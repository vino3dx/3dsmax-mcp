"""Per-object execution and reconciliation for the batch-capable tools.

Why this layer exists
---------------------
The MAXScript handlers behind ``transform_object``, ``clone_objects``,
``delete_objects``, ``select_objects``, ``mat_assign`` and ``mod_add`` took a
list of nodes and resolved it with ``mcpResolveNodes``.  That helper aborts the
whole command when *one* name is unknown, and several handlers wrap each node in
``try(...) catch()`` - so a scene edit could fail for object 3 of 5 and still
answer ``{"message": "完成。"}``.  The MCP layer had no way to tell.

This module gives the agent what it actually needs:

* one result row per requested object, including a stable error ``kind``;
* partial success reported as ``success: false`` with an exact ``summary``;
* ambiguity and stale references refused instead of "first match wins";
* read-back verification from the scene (never from the request parameters);
* transport failures abort the batch instead of silently skipping work.

It is transport-agnostic: the only dependency is a ``call(method, params)``
callable, which in production is ``MaxBridge.call``.

Name strings handled here stay in wire space (the ANSI-latin-1 view produced by
``maxmcp.wire.to_wire``) because the payload arriving from the server is already
encoded for the bridge and the bridge replies are decoded once, centrally, in
``MaxMcpServer.on_tools_call``.  Only our own diagnostics are plain ASCII.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from . import errors, scene_state

BridgeCall = Callable[[str, Dict[str, Any]], Any]

#: Tools where each object can be executed independently without changing the
#: meaning of the request.
PER_OBJECT_TOOLS = frozenset({"transform_object", "clone_objects", "delete_objects"})

#: Tools that must run as a single command (selection semantics / one undo
#: entry) but still report one row per requested object, reconciled against what
#: Max said it actually did.
RECONCILE_TOOLS = frozenset({"select_objects", "mat_assign", "mod_add"})

BATCH_TOOLS = PER_OBJECT_TOOLS | RECONCILE_TOOLS

#: Upper bound on read-back probes spent verifying a single clone batch.
MAX_VERIFY_OBJECTS = 64


# --------------------------------------------------------------------- utilities
def _as_name(entry: Any) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """Return ``(name, error)`` for one entry of an ``objects`` parameter."""
    if isinstance(entry, str):
        if not entry.strip():
            return None, errors.error("invalid_object_reference", "An object reference was an empty string")
        return entry, None
    if isinstance(entry, dict):
        name = entry.get("name")
        if isinstance(name, str) and name.strip():
            return name, None
        if "object_ref" in entry or "handle" in entry:
            return None, errors.error(
                "invalid_object_reference",
                "A reference without a name was rejected: numeric handles are not "
                "validated as stable identities yet, pass the object name instead",
            )
        return None, errors.error(
            "invalid_object_reference", "Object reference dict has no usable 'name'")
    if isinstance(entry, (int, float)) and not isinstance(entry, bool):
        return None, errors.error(
            "invalid_object_reference",
            "Numeric handles are not accepted as object references; pass the object name",
        )
    return None, errors.error(
        "invalid_object_reference",
        "Unsupported object reference type: {0}".format(type(entry).__name__),
    )


def _payload_objects(params: Dict[str, Any]) -> Optional[List[Any]]:
    value = params.get("objects")
    if isinstance(value, list):
        return value
    return None


def _unique_names(raw: Sequence[Any]) -> Tuple[List[str], List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Split entries into unique names plus per-entry lookup failures.

    Returns ``(names, rejected_rows, warnings)``.  Duplicates are collapsed: the
    same object must not be moved twice by one request.
    """
    names: List[str] = []
    rejected: List[Dict[str, Any]] = []
    warnings: List[Dict[str, Any]] = []
    seen = set()
    for entry in raw:
        name, failure = _as_name(entry)
        if failure is not None:
            rejected.append({"name": str(entry), "success": False, "changed": None,
                             "verified": False, "error": failure})
            continue
        assert name is not None
        if name in seen:
            warnings.append({
                "kind": "duplicate_object_in_request",
                "message": "Object was listed more than once and executed once",
                "object": name,
            })
            continue
        seen.add(name)
        names.append(name)
    return names, rejected, warnings


def _envelope(*, operation: str, rows: List[Dict[str, Any]], warnings: List[Dict[str, Any]],
              failures: List[Dict[str, Any]], scope: str = "objects",
              detail: Optional[Dict[str, Any]] = None,
              extra: Optional[Dict[str, Any]] = None,
              success: Optional[bool] = None) -> Dict[str, Any]:
    succeeded = sum(1 for row in rows if row.get("success") is True)
    failed = len(rows) - succeeded
    skipped = sum(1 for row in rows if row.get("skipped"))
    verified = sum(1 for row in rows if row.get("verified") is True)
    changed_flags = [row.get("changed") for row in rows]
    if any(flag is True for flag in changed_flags):
        changed: Optional[bool] = True
    elif any(flag is False for flag in changed_flags):
        changed = False
    else:
        changed = None

    overall = bool(rows) and failed == 0 if success is None else bool(success)
    batch_failures = list(failures)
    if rows and failed:
        if succeeded:
            batch_failures.append(errors.error(
                "partial_success",
                "{0} of {1} objects failed".format(failed, len(rows)),
            ))
        else:
            batch_failures.append(errors.error(
                "batch_failed", "All {0} objects failed".format(len(rows))))

    attempted = [row for row in rows if not row.get("skipped")]
    verified_rows = [row for row in attempted if row.get("verified") is True]
    # "passed" must never imply something that was not read back: when only part
    # of the batch could be verified, the verdict is None unless a *verified* row
    # already failed.
    if not verified_rows:
        passed: Optional[bool] = None
    elif len(verified_rows) < len(attempted):
        passed = False if any(row.get("success") is False for row in verified_rows) else None
    else:
        passed = all(row.get("success") is True for row in verified_rows)

    verification = {
        "performed": verified > 0,
        "passed": passed,
        "detail": {
            "verified": verified,
            "unverified": len(attempted) - len(verified_rows),
            "scope": scope,
        },
    }
    if detail is not None:
        verification["detail"].update(detail)

    envelope: Dict[str, Any] = {
        "success": overall,
        "operation": operation,
        "scope": scope,
        "changed": changed,
        "warnings": warnings,
        "failures": batch_failures,
        "verification": verification,
        "objects": rows,
        "summary": {
            "total": len(rows),
            "succeeded": succeeded,
            "failed": failed,
            "skipped": skipped,
            "verified": verified,
        },
    }
    if extra:
        envelope["data"] = extra
    return envelope


# ------------------------------------------------------------------ the executor
class BatchExecutor:
    """Turn a list-taking tool call into per-object, verified results."""

    def __init__(self, call: BridgeCall) -> None:
        self._call = call

    # ------------------------------------------------------------- public entry
    def supports(self, name: str) -> bool:
        return name in BATCH_TOOLS

    def run(self, operation: str, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        raw = _payload_objects(params)
        if not raw:
            return self._selection_scope(operation, method, params)
        names, rejected, warnings = _unique_names(raw)
        if operation in PER_OBJECT_TOOLS:
            return self._run_per_object(operation, method, params, names, rejected, warnings)
        return self._run_reconcile(operation, method, params, names, rejected, warnings)

    # -------------------------------------------------------- selection fallback
    def _selection_scope(self, operation: str, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """No object list: Max acts on the current selection, so rows are impossible."""
        warnings = [{
            "kind": "selection_scope",
            "message": "No object list was given, so the command acted on the current "
                       "selection and no per-object result can be reported",
        }]
        try:
            payload = self._call(method, params)
        except Exception as exc:  # noqa: BLE001 - classified below
            return _envelope(
                operation=operation, rows=[], warnings=warnings,
                failures=[errors.from_exception(exc)], scope="selection", success=False,
            )
        return _envelope(
            operation=operation, rows=[], warnings=warnings, failures=[], scope="selection",
            # Mirror the Scene Runtime convention: the bridge payload lives under
            # data, which also keeps `_images` discoverable for vision tools.
            extra=dict(payload) if isinstance(payload, dict) else {"value": payload},
            success=True,
        )

    # --------------------------------------------------------- per-object branch
    def _run_per_object(self, operation: str, method: str, params: Dict[str, Any],
                        names: List[str], rejected: List[Dict[str, Any]],
                        warnings: List[Dict[str, Any]]) -> Dict[str, Any]:
        rows: List[Dict[str, Any]] = list(rejected)
        failures: List[Dict[str, Any]] = []
        aborted = False

        for name in names:
            if aborted:
                rows.append(self._skipped_row(name))
                continue

            ref = self._resolve(name)
            if ref["status"] != "ok":
                rows.append({
                    "name": name,
                    "success": False,
                    "changed": None,
                    "verified": False,  # the operation never ran, so nothing to verify
                    "error": ref["error"],
                })
                if errors.is_transport_failure(ref["error"].get("kind", "")):
                    aborted = True
                continue

            row, transport_failure = self._execute_one(operation, method, params, name, ref["node"])
            rows.append(row)
            if transport_failure:
                aborted = True

        if aborted:
            failures.append(errors.error(
                "aborted",
                "Execution stopped after a bridge/transport failure; "
                "remaining objects were not attempted",
            ))
        return _envelope(
            operation=operation, rows=rows, warnings=warnings, failures=failures,
            detail={"mode": "per_object"},
        )

    @staticmethod
    def _skipped_row(name: str) -> Dict[str, Any]:
        return {
            "name": name,
            "success": False,
            "skipped": True,
            "changed": None,
            "verified": False,
            "error": errors.error(
                "not_attempted",
                "Not attempted because an earlier object hit a transport failure",
            ),
        }

    def _resolve(self, name: str) -> Dict[str, Any]:
        """Read the scene to prove which object ``name`` refers to.

        ``find_objects`` with ``exact:true`` compares node names exactly inside
        Max; the reply is a real scene read, not a guess.
        """
        try:
            payload = self._call("find_objects", {"name": name, "exact": True})
        except Exception as exc:  # noqa: BLE001
            failure = errors.from_exception(exc, stage="resolve")
            return {"status": "error", "error": failure}

        matches: List[Dict[str, Any]] = []
        if isinstance(payload, dict):
            raw = payload.get("objects")
            if isinstance(raw, list):
                for info in raw:
                    if isinstance(info, dict) and info.get("name") == name:
                        matches.append(info)
        if not matches:
            return {"status": "missing", "error": errors.error(
                "object_not_found",
                "No scene object is named exactly this; it may have been deleted or renamed",
                object=name,
            )}
        if len(matches) > 1:
            return {"status": "ambiguous", "error": errors.error(
                "ambiguous_object",
                "{0} objects share this name; refusing to guess which one was meant".format(len(matches)),
                object=name,
                candidates=len(matches),
            )}
        return {"status": "ok", "node": matches[0]}

    def _execute_one(self, operation: str, method: str, params: Dict[str, Any],
                     name: str, before_node: Dict[str, Any]) -> Tuple[Dict[str, Any], bool]:
        """Run one object and verify it against a second scene read."""
        single = dict(params)
        single["objects"] = [name]
        try:
            payload = self._call(method, single)
        except Exception as exc:  # noqa: BLE001
            failure = errors.from_exception(exc, stage="execute")
            if failure.get("kind") == "object_not_found":
                # The name resolved one statement earlier, so "not found" now
                # means the object disappeared in between: a stale reference,
                # not a typo in the request.
                failure = errors.error(
                    "stale_object_reference",
                    "The object vanished between resolution and execution",
                    object=name,
                )
            return ({
                "name": name,
                "success": False,
                "changed": None,
                "verified": False,
                "object_ref": self._object_ref(name, before_node),
                "error": failure,
            }, errors.is_transport_failure(failure.get("kind", "")))

        if operation == "transform_object":
            row, transport = self._verify_transform(name, params, before_node), False
        elif operation == "delete_objects":
            row, transport = self._verify_delete(name, payload), False
        elif operation == "clone_objects":
            row, transport = self._verify_clone(name, payload), False
        else:
            row, transport = ({
                "name": name,
                "success": True,
                "changed": None,
                "verified": False,
                "result": payload,
            }, False)
        row.setdefault("object_ref", self._object_ref(name, before_node))
        return row, transport

    @staticmethod
    def _object_ref(name: str, node: Any) -> Dict[str, Any]:
        """Diagnostic identity: the name plus the handle Max reported for it."""
        handle = node.get("handle") if isinstance(node, dict) else None
        return {"name": name, "handle": handle}

    # ------------------------------------------------------------ verifications
    def _verify_transform(self, name: str, params: Dict[str, Any],
                          before_node: Dict[str, Any]) -> Dict[str, Any]:
        row: Dict[str, Any] = {"name": name, "success": True, "changed": None,
                               "verified": False}
        try:
            after_node = self._call("get_object_info", {"name": name})
        except Exception as exc:  # noqa: BLE001
            row["error"] = errors.from_exception(exc, stage="readback")
            row["success"] = False
            return row

        before = scene_state.node_snapshot(before_node)
        after = scene_state.node_snapshot(after_node)
        delta = scene_state.transform_delta(before, after)
        row["changed"] = bool(delta)
        row["verified"] = True
        row["readback"] = {"changed_fields": sorted(delta)}

        op = str(params.get("operation") or "move")
        mode = str(params.get("mode") or "relative")
        value = params.get("value")
        field = {"move": "position", "rotate": "rotation", "scale": "scale"}.get(op)
        if field is None:
            row["error"] = errors.error("invalid_arguments", "Unsupported transform operation")
            row["success"] = False
            return row

        if mode == "absolute" and op != "rotate":
            verdict = scene_state.compare_absolute(field, value, (after or {}).get(field))
        elif mode == "absolute":
            # Euler read-back of an axis-angle request is not comparable without
            # knowing the original orientation; only claim "something rotated".
            verdict = True if delta else None
        elif isinstance(value, list) and all(
            isinstance(v, (int, float)) and abs(float(v)) < 1e-9 for v in value
        ) and len(value) == 3:
            # A relative no-op was requested: nothing changing is correct.
            verdict = not delta
        else:
            verdict = bool(delta)

        if verdict is False:
            row["success"] = False
            row["error"] = errors.error(
                "no_effect" if not delta else "verification_failed",
                "Scene read-back does not match the requested transform",
                field=field,
                expected=value,
                actual=(after or {}).get(field),
            )
        return row

    def _verify_delete(self, name: str, payload: Any) -> Dict[str, Any]:
        row: Dict[str, Any] = {"name": name, "success": True, "changed": True,
                               "verified": False}
        ref = self._resolve(name)
        if ref["status"] == "missing":
            row["verified"] = True
            row["readback"] = {"exists": False}
            return row
        if ref["status"] == "ambiguous":
            # Duplicate names made the pre-flight refuse, so reaching this is a
            # genuine inconsistency: report it rather than assume deletion.
            row["success"] = False
            row["changed"] = None
            row["verified"] = True
            row["error"] = errors.error(
                "verification_failed",
                "Name still matches multiple objects after delete",
            )
            return row
        if ref["status"] == "error":
            row["success"] = False
            row["changed"] = None
            row["error"] = ref["error"]
            return row
        row["success"] = False
        row["changed"] = False
        row["verified"] = True
        row["readback"] = {"exists": True}
        row["error"] = errors.error(
            "not_deleted", "The object still exists after the delete command", object=name)
        return row

    def _verify_clone(self, name: str, payload: Any) -> Dict[str, Any]:
        created: List[Any] = []
        if isinstance(payload, dict):
            raw = payload.get("created")
            if isinstance(raw, list):
                created = raw
        row: Dict[str, Any] = {
            "name": name,
            "success": bool(created),
            "changed": True if created else False,
            "verified": False,
            "created": created,
        }
        if not created:
            row["error"] = errors.error(
                "no_effect", "Clone command returned no created object names", object=name)
            return row

        checked = 0
        missing: List[Any] = []
        for created_name in created[:MAX_VERIFY_OBJECTS]:
            if not isinstance(created_name, str):
                continue
            ref = self._resolve(created_name)
            checked += 1
            if ref["status"] != "ok":
                missing.append(created_name)
        row["verified"] = checked > 0
        row["readback"] = {
            "created_checked": checked,
            "created_total": len(created),
            "missing": missing,
        }
        if missing:
            row["success"] = False
            row["error"] = errors.error(
                "verification_failed",
                "Cloned objects reported by Max could not be found in the scene",
                missing=missing,
            )
        return row

    # ----------------------------------------------------------- reconcile mode
    def _run_reconcile(self, operation: str, method: str, params: Dict[str, Any],
                       names: List[str], rejected: List[Dict[str, Any]],
                       warnings: List[Dict[str, Any]]) -> Dict[str, Any]:
        rows: List[Dict[str, Any]] = list(rejected)
        try:
            payload = self._call(method, params)
        except Exception as exc:  # noqa: BLE001
            for name in names:
                rows.append({
                    "name": name,
                    "success": False,
                    "changed": None,
                    "verified": False,
                    "error": errors.from_exception(exc),
                })
            return _envelope(operation=operation, rows=rows, warnings=warnings,
                             failures=[errors.from_exception(exc)],
                             detail={"mode": "reconcile", "batch_call_failed": True})

        if operation == "select_objects":
            rows.extend(self._reconcile_selection(names, params, payload, warnings))
        else:
            rows.extend(self._reconcile_applied(
                names, payload, changed=None if operation == "mat_assign" else True,
                warnings=warnings))
        return _envelope(operation=operation, rows=rows, warnings=warnings, failures=[],
                         detail={"mode": "reconcile"})

    @staticmethod
    def _string_list(value: Any) -> List[str]:
        if isinstance(value, list):
            return [item for item in value if isinstance(item, str)]
        return []

    def _reconcile_applied(self, names: List[str], payload: Any,
                           changed: Optional[bool],
                           warnings: Optional[List[Dict[str, Any]]] = None) -> List[Dict[str, Any]]:
        applied_raw = payload.get("applied") if isinstance(payload, dict) else None
        if not isinstance(applied_raw, list):
            # No per-object report at all (older/unknown bridge): do not invent
            # failures, mark the rows unverified instead.
            if warnings is not None:
                warnings.append({
                    "kind": "reconcile_unavailable",
                    "message": "The bridge reply carried no 'applied' list, so per-object "
                               "success could not be reconciled",
                })
            return [{
                "name": name, "success": True, "changed": None, "verified": False,
            } for name in names]

        applied = set(self._string_list(applied_raw))
        failure_text: Dict[str, str] = {}
        if isinstance(payload, dict):
            for entry in self._string_list(payload.get("failures")):
                head, _, tail = entry.partition(":")
                failure_text[head.strip()] = tail.strip() or entry
        rows: List[Dict[str, Any]] = []
        for name in names:
            if name in applied:
                rows.append({
                    "name": name, "success": True, "changed": changed,
                    # Max appends to "applied" only after the assignment/addModifier
                    # call returned, so this is a reported outcome, not our guess.
                    "verified": True,
                })
                continue
            message = failure_text.get(name) or (
                "Max did not report this object as applied; the per-object "
                "operation was skipped or failed inside 3ds Max")
            rows.append({
                "name": name, "success": False, "changed": None, "verified": True,
                "error": errors.error("not_applied", message, object=name),
            })
        return rows

    def _reconcile_selection(self, names: List[str], params: Dict[str, Any],
                             payload: Any,
                             warnings: Optional[List[Dict[str, Any]]] = None) -> List[Dict[str, Any]]:
        mode = str(params.get("mode") or "replace")
        selected: List[str] = []
        if isinstance(payload, dict):
            for info in payload.get("objects") or []:
                if isinstance(info, dict) and isinstance(info.get("name"), str):
                    selected.append(info["name"])
        selected_set = set(selected)
        if mode == "invert":
            return [{
                "name": name, "success": True, "changed": None, "verified": False,
                "note": "invert has no per-object expectation to verify",
            } for name in names]

        if not isinstance(payload, dict) or "objects" not in payload:
            if warnings is not None:
                warnings.append({
                    "kind": "reconcile_unavailable",
                    "message": "The bridge reply carried no selection list, so the "
                               "selection could not be verified",
                })
            return [{
                "name": name, "success": True, "changed": None, "verified": False,
            } for name in names]

        if names and not (set(names) & selected_set) and selected_set:
            # Max answered with a selection that shares no name with the request
            # (groups, instanced hierarchies, renamed nodes...).  We cannot tell
            # whether this is a failure or a naming effect, so we refuse to guess.
            if warnings is not None:
                warnings.append({
                    "kind": "reconcile_unavailable",
                    "message": "None of the requested names appear in the resulting "
                               "selection; per-object verification was skipped",
                })
            return [{
                "name": name, "success": True, "changed": None, "verified": False,
            } for name in names]

        rows: List[Dict[str, Any]] = []
        for name in names:
            if mode == "subtract":
                ok = name not in selected_set
                detail = "Object is no longer selected" if ok else "Object is still selected"
            else:  # replace / add
                ok = name in selected_set
                detail = "Object is selected" if ok else "Object was not selected by Max"
            rows.append({
                "name": name,
                "success": ok,
                "changed": None,
                # The payload *is* Max's selection read-back.
                "verified": True,
                "readback": {"selected": name in selected_set, "detail": detail},
                **({} if ok else {"error": errors.error("not_applied", detail, object=name)}),
            })
        return rows
