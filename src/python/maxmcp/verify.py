"""Operation verification: did the scene actually reach the state we asked for?

Execution success and goal attainment are different claims.  A tool can answer
``success: true`` while the object it was told to move never moved, the
modifier was silently dropped by a ``catch()``, or the material ended up on a
different node.  This module answers the second question from *read-back only*:
every check re-reads the scene through the same bridge the operation used, and
nothing is inferred from the request parameters.

Three outcomes are possible, and they are not interchangeable:

    passed        the read-back proves the requested state
    failed        the read-back contradicts the requested state
    unavailable   the read-back itself failed, so nothing is known

``unavailable`` must never be reported as ``passed`` - the same rule the scene
runtime already applies to ``verification.passed`` being ``None``.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from . import scene_state

#: Outcome of one read attempt: ``("ok" | "absent" | "unavailable", value)``.
ReadStatus = Tuple[str, Any]


class SceneReader:
    """Narrow, read-only view of the scene used by verification.

    Only four reads are exposed - a node, the object count, the selection and
    poly statistics - because those are the facts the verifiers need.  Anything
    wider would turn verification into a second scene database.
    """

    def __init__(self, invoke: Callable[[str, Dict[str, Any]], Any]) -> None:
        self._invoke = invoke

    # ------------------------------------------------------------------ reads
    def node(self, name: str) -> ReadStatus:
        """Return ``("found"|"absent"|"unavailable", node)`` for one name.

        ``find_objects`` with ``exact`` reports both matches and a zero count,
        so "the object is gone" is distinguishable from "the bridge is gone".
        """
        if not isinstance(name, str) or not name:
            return "unavailable", {"reason": "invalid_name"}
        outcome = self._invoke("find_objects", {"name": name, "exact": True})
        if not _ok(outcome):
            return "unavailable", _error_of(outcome)
        payload = _payload(outcome)
        if not isinstance(payload, dict):
            return "unavailable", {"reason": "empty_reply"}
        found = payload.get("objects")
        if not isinstance(found, list):
            return "unavailable", {"reason": "missing_objects"}
        count = payload.get("count")
        if not isinstance(count, int):
            count = len(found)
        if count == 0:
            return "absent", None
        if count > 1:
            return "found", {"ambiguous": True, "count": count,
                             "node": found[0] if found else None}
        return "found", {"ambiguous": False, "count": 1, "node": found[0] if found else None}

    def count(self) -> ReadStatus:
        outcome = self._invoke("scene_info", {})
        if not _ok(outcome):
            return "unavailable", _error_of(outcome)
        payload = _payload(outcome)
        value = payload.get("objectCount") if isinstance(payload, dict) else None
        if not isinstance(value, int):
            return "unavailable", {"reason": "missing_object_count"}
        return "ok", value

    def selection(self) -> ReadStatus:
        outcome = self._invoke("get_selection", {})
        if not _ok(outcome):
            return "unavailable", _error_of(outcome)
        payload = _payload(outcome)
        objects = payload.get("objects") if isinstance(payload, dict) else None
        if not isinstance(objects, list):
            return "unavailable", {"reason": "missing_selection"}
        names: List[str] = []
        for entry in objects:
            if isinstance(entry, dict) and isinstance(entry.get("name"), str):
                names.append(entry["name"])
        return "ok", names

    def poly_stats(self, name: str) -> ReadStatus:
        outcome = self._invoke("poly_get_stats", {"objects": [name]})
        if not _ok(outcome):
            return "unavailable", _error_of(outcome)
        payload = _payload(outcome)
        objects = payload.get("objects") if isinstance(payload, dict) else None
        if not isinstance(objects, list) or not objects:
            return "unavailable", {"reason": "missing_poly_stats"}
        first = objects[0]
        if not isinstance(first, dict):
            # The MAXScript handler puts an "ERROR <name>: ..." string in the
            # list when the node is not an editable poly; that is a real answer.
            return "unavailable", {"reason": "poly_stats_string", "detail": first}
        return "ok", first


def _ok(outcome: Any) -> bool:
    if isinstance(outcome, dict):
        if outcome.get("ok") is False:
            return False
        return outcome.get("ok") is True
    return getattr(outcome, "ok", False) is True


def _payload(outcome: Any) -> Any:
    if isinstance(outcome, dict):
        return outcome.get("payload")
    return getattr(outcome, "payload", None)


def _error_of(outcome: Any) -> Any:
    if isinstance(outcome, dict):
        return outcome.get("error")
    return getattr(outcome, "error", None)


# --------------------------------------------------------------------- helpers
def _result(kind: str, performed: bool, passed: Optional[bool], **detail: Any) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "kind": kind,
        "performed": performed,
        "passed": passed,
        "detail": detail or None,
    }
    if not performed:
        payload["detail"] = detail or {"reason": "unavailable"}
    return payload


def _unavailable(kind: str, reason: str, **detail: Any) -> Dict[str, Any]:
    body = {"reason": reason}
    body.update(detail)
    return _result(kind, False, None, **body)


def _node_of(status: str, value: Any) -> Tuple[bool, Optional[Dict[str, Any]], Dict[str, Any]]:
    """Normalise :meth:`SceneReader.node` into ``(found, node, info)``."""
    if status == "unavailable":
        return False, None, {"unavailable": True, "error": value}
    if status == "absent":
        return False, None, {"absent": True}
    info = value if isinstance(value, dict) else {}
    node = info.get("node")
    return True, (node if isinstance(node, dict) else None), info


# ------------------------------------------------------------------- verifiers
def verify_read_ok(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    """The read itself worked and carried the fields the step needs."""
    payload = ctx.get("payload")
    fields = spec.get("fields") or []
    if not isinstance(payload, dict):
        return _result("read_ok", True, False, reason="payload_not_an_object",
                       payload_type=type(payload).__name__)
    missing = [field for field in fields if payload.get(field) is None]
    return _result("read_ok", True, not missing, missing=missing,
                   fields=fields, keys=sorted(payload)[:12])


def verify_exists(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    wanted: Sequence[str] = spec.get("objects") or []
    if not wanted:
        return _unavailable("exists", "no_objects_requested")
    found: List[str] = []
    absent: List[str] = []
    duplicated: List[str] = []
    unreadable: List[Any] = []
    for name in wanted:
        status, value = reader.node(name)
        ok, node, info = _node_of(status, value)
        if info.get("unavailable"):
            unreadable.append({"object": name, "error": info.get("error")})
        elif not ok:
            absent.append(name)
        elif info.get("ambiguous"):
            duplicated.append(name)
        else:
            found.append(name)
    if unreadable:
        return _unavailable("exists", "read_back_failed", objects=wanted, errors=unreadable)
    passed = not absent and not duplicated
    return _result("exists", True, passed, found=found, missing=absent,
                   duplicated=duplicated)


def verify_absent(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    wanted: Sequence[str] = spec.get("objects") or []
    if not wanted:
        return _unavailable("absent", "no_objects_requested")
    still_there: List[str] = []
    gone: List[str] = []
    errors: List[Any] = []
    for name in wanted:
        status, value = reader.node(name)
        ok, node, info = _node_of(status, value)
        if info.get("unavailable"):
            errors.append({"object": name, "error": info.get("error")})
        elif ok:
            still_there.append(name)
        else:
            gone.append(name)
    if errors:
        return _unavailable("absent", "read_back_failed", errors=errors)
    return _result("absent", True, not still_there, removed=gone, remaining=still_there)


def verify_count(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    status, value = reader.count()
    if status != "ok":
        return _unavailable("count", "object_count_unreadable", error=value)
    checks: List[Dict[str, Any]] = []
    if isinstance(spec.get("equals"), int):
        checks.append({"check": "equals", "expected": spec["equals"], "actual": value,
                       "passed": value == spec["equals"]})
    if isinstance(spec.get("atLeast"), int):
        checks.append({"check": "atLeast", "expected": spec["atLeast"], "actual": value,
                       "passed": value >= spec["atLeast"]})
    delta = spec.get("delta")
    if isinstance(delta, int) and isinstance(ctx.get("before_count"), int):
        observed = value - int(ctx["before_count"])
        checks.append({"check": "delta", "expected": delta, "actual": observed,
                       "passed": observed == delta})
    if not checks:
        return _unavailable("count", "no_expectation_declared", actual=value)
    return _result("count", True, all(item["passed"] for item in checks),
                   actual=value, checks=checks)


def verify_transform(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    name = spec.get("object")
    if not isinstance(name, str) or not name:
        return _unavailable("transform", "no_object_requested")
    status, value = reader.node(name)
    ok, node, info = _node_of(status, value)
    if info.get("unavailable"):
        return _unavailable("transform", "read_back_failed", error=info.get("error"))
    if not ok or node is None:
        return _result("transform", True, False, object=name, reason="object_not_found")
    tolerance = spec.get("tolerance")
    tolerance = float(tolerance) if isinstance(tolerance, (int, float)) else scene_state.DEFAULT_TOLERANCE
    fields = [field for field in ("position", "rotation", "scale") if field in spec]
    if not fields:
        return _unavailable("transform", "no_field_requested", object=name)
    checks: List[Dict[str, Any]] = []
    unknown: List[str] = []
    for field in fields:
        verdict = scene_state.compare_absolute(field, spec.get(field), node.get(field), tolerance)
        if verdict is None:
            unknown.append(field)
            continue
        checks.append({"field": field, "expected": spec[field],
                       "actual": node.get(field), "passed": verdict})
    if unknown:
        return _unavailable("transform", "field_not_comparable", object=name, fields=unknown)
    return _result("transform", True, all(item["passed"] for item in checks),
                   object=name, checks=checks, tolerance=tolerance)


def verify_material(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    name = spec.get("object")
    expected = spec.get("material")
    if not isinstance(name, str) or not name:
        return _unavailable("material", "no_object_requested")
    status, value = reader.node(name)
    ok, node, info = _node_of(status, value)
    if info.get("unavailable"):
        return _unavailable("material", "read_back_failed", error=info.get("error"))
    if not ok or node is None:
        return _result("material", True, False, object=name, reason="object_not_found")
    actual = node.get("material")
    if actual is None:
        return _unavailable("material", "material_field_missing", object=name)
    return _result("material", True, actual == expected, object=name,
                   expected=expected, actual=actual)


def verify_modifier(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    name = spec.get("object")
    expected = spec.get("modifier")
    if not isinstance(name, str) or not name:
        return _unavailable("modifier", "no_object_requested")
    if not isinstance(expected, str) or not expected:
        return _unavailable("modifier", "no_modifier_requested")
    status, value = reader.node(name)
    ok, node, info = _node_of(status, value)
    if info.get("unavailable"):
        return _unavailable("modifier", "read_back_failed", error=info.get("error"))
    if not ok or node is None:
        return _result("modifier", True, False, object=name, reason="object_not_found")
    modifiers = node.get("modifiers")
    if not isinstance(modifiers, list):
        return _unavailable("modifier", "modifier_list_missing", object=name)
    wanted = expected.lower()
    matched = [item for item in modifiers
               if isinstance(item, str) and (item.lower() == wanted or wanted in item.lower())]
    return _result("modifier", True, bool(matched), object=name, expected=expected,
                   actual=modifiers, matched=matched)


def verify_class(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    name = spec.get("object")
    allowed = spec.get("allowed") or []
    if not isinstance(name, str) or not name:
        return _unavailable("class", "no_object_requested")
    if not isinstance(allowed, list) or not allowed:
        return _unavailable("class", "no_class_requested")
    status, value = reader.node(name)
    ok, node, info = _node_of(status, value)
    if info.get("unavailable"):
        return _unavailable("class", "read_back_failed", error=info.get("error"))
    if not ok or node is None:
        return _result("class", True, False, object=name, reason="object_not_found")
    actual = node.get("baseClass") or node.get("class")
    if not isinstance(actual, str) or not actual:
        return _unavailable("class", "class_field_missing", object=name)
    return _result("class", True, actual in allowed, object=name,
                   expected=allowed, actual=actual)


def verify_face_count(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    name = spec.get("object")
    if not isinstance(name, str) or not name:
        return _unavailable("face_count", "no_object_requested")
    status, value = reader.poly_stats(name)
    if status != "ok":
        return _unavailable("face_count", "poly_stats_unavailable", error=value)
    faces = value.get("faces")
    if not isinstance(faces, int):
        return _unavailable("face_count", "face_count_missing", stats=value)
    checks: List[Dict[str, Any]] = [{"check": "actual", "value": faces}]
    if isinstance(spec.get("atLeast"), int):
        checks.append({"check": "atLeast", "expected": spec["atLeast"],
                       "passed": faces >= spec["atLeast"]})
    if isinstance(spec.get("equals"), int):
        checks.append({"check": "equals", "expected": spec["equals"],
                       "passed": faces == spec["equals"]})
    graded = [item for item in checks if "passed" in item]
    if not graded:
        return _unavailable("face_count", "no_expectation_declared", faces=faces)
    return _result("face_count", True, all(item["passed"] for item in graded),
                   object=name, faces=faces, checks=checks)


def verify_selection(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    reader: SceneReader = ctx["reader"]
    wanted: Sequence[str] = spec.get("objects") or []
    status, value = reader.selection()
    if status != "ok":
        return _unavailable("selection", "selection_unreadable", error=value)
    selected = list(value or [])
    missing = [name for name in wanted if name not in selected]
    return _result("selection", True, bool(wanted) and not missing,
                   expected=list(wanted), actual=selected, missing=missing)


def verify_payload_number(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    """Check a scalar the tool itself reported (counts, face totals...).

    Used when the answer already contains a number the read-back would repeat,
    for example ``poly_get_stats.faces``.  It is *not* a substitute for reading
    the scene back when the claim is about the scene changing.
    """
    payload = ctx.get("payload")
    field = spec.get("field")
    if not isinstance(payload, dict) or not isinstance(field, str) or not field:
        return _unavailable("payload_number", "field_not_readable", field=field)
    container: Any = payload
    if field not in payload and isinstance(payload.get("objects"), list) and payload["objects"]:
        first = payload["objects"][0]
        container = first if isinstance(first, dict) else {}
    value = container.get(field)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return _unavailable("payload_number", "field_not_numeric", field=field,
                            value=value if isinstance(value, (int, float)) else None)
    checks: List[Dict[str, Any]] = [{"check": "actual", "value": value}]
    if isinstance(spec.get("atLeast"), (int, float)):
        checks.append({"check": "atLeast", "expected": spec["atLeast"],
                       "passed": value >= spec["atLeast"]})
    if isinstance(spec.get("equals"), (int, float)):
        checks.append({"check": "equals", "expected": spec["equals"],
                       "passed": value == spec["equals"]})
    graded = [item for item in checks if "passed" in item]
    if not graded:
        return _unavailable("payload_number", "no_expectation_declared", value=value)
    return _result("payload_number", True, all(item["passed"] for item in graded),
                   field=field, value=value, checks=checks)


def verify_image(spec: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
    """Visual feedback is only "available" when real image bytes came back."""
    images = ctx.get("images") or []
    image_errors = ctx.get("image_errors") or []
    labels = [item.get("label") for item in images if isinstance(item, dict)]
    if images:
        want = spec.get("label")
        passed = True if not want else want in labels
        return _result("image", True, passed, labels=labels, count=len(images))
    if image_errors:
        return _result("image", True, False, reason="image_unusable",
                       errors=image_errors[:3], count=0)
    return _unavailable("image", "no_image_returned", count=0)


VERIFIERS: Dict[str, Callable[[Dict[str, Any], Dict[str, Any]], Dict[str, Any]]] = {
    "read_ok": verify_read_ok,
    "exists": verify_exists,
    "absent": verify_absent,
    "count": verify_count,
    "transform": verify_transform,
    "material": verify_material,
    "modifier": verify_modifier,
    "class": verify_class,
    "face_count": verify_face_count,
    "selection": verify_selection,
    "payload_number": verify_payload_number,
    "image": verify_image,
}

#: Every kind a workflow step may declare.
VERIFY_KINDS = frozenset(VERIFIERS)


def evaluate(spec: Optional[Dict[str, Any]], ctx: Dict[str, Any]) -> Dict[str, Any]:
    """Run one verification spec.

    An empty spec means "the workflow declares no goal for this step", which is
    reported as ``performed: false`` rather than as a pass.  Unknown kinds are
    refused instead of being ignored, so a typo cannot silently disable a check.
    """
    if not spec:
        return {"kind": "none", "performed": False, "passed": None, "detail": None}
    kind = spec.get("kind")
    verifier = VERIFIERS.get(kind) if isinstance(kind, str) else None
    if verifier is None:
        return {"kind": str(kind), "performed": False, "passed": None,
                "detail": {"reason": "unknown_verification_kind", "declared": kind,
                           "known": sorted(VERIFY_KINDS)}}
    try:
        result = verifier(spec, ctx)
    except Exception as exc:  # a verifier bug must not read as "passed"
        return {"kind": str(kind), "performed": False, "passed": None,
                "detail": {"reason": "verification_error", "message": str(exc)}}
    result["spec"] = {key: value for key, value in spec.items() if key != "kind"}
    return result


__all__ = ["SceneReader", "VERIFIERS", "VERIFY_KINDS", "evaluate"]
