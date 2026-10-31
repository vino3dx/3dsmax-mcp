"""Scene-state snapshots and diffs built from real bridge read-backs.

An agent that only sees ``{"success": true}`` cannot tell a completed edit from a
silently ignored one.  The bridge already returns per-node state
(``mcpNodeInfo`` in ``src/ms/mcp_core.ms``): name, handle, class, transform,
material and the modifier list.  This module turns those payloads into a
comparable snapshot and a diff, so before/after can be checked without trusting
the request parameters.

Two deliberate rules:

* A snapshot is *partial* when a field is absent.  Absence means "not read", never
  "the object does not have this property" - a Max version that cannot report
  modifiers must not look like an object with no modifiers.
* A missing field never counts as "unchanged".  It is reported in ``unknown`` so
  a caller cannot mistake "we did not look" for "it did not change".
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

#: Fields compared between snapshots.  Order matters for stable output.
SNAPSHOT_FIELDS: Tuple[str, ...] = (
    "name",
    "handle",
    "class",
    "position",
    "rotation",
    "scale",
    "material",
    "modifiers",
)

TRANSFORM_FIELDS: Tuple[str, ...] = ("position", "rotation", "scale")

#: Max reports floats after undo/redo round trips; exact equality is useless.
DEFAULT_TOLERANCE = 1e-4


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _close(a: Any, b: Any, tolerance: float) -> Optional[bool]:
    """Compare two values; ``None`` when they are not comparable."""
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        if len(a) != len(b):
            return False
        results = [_close(x, y, tolerance) for x, y in zip(a, b)]
        if any(result is None for result in results):
            return None
        return all(results)
    if _is_number(a) and _is_number(b):
        return abs(float(a) - float(b)) <= tolerance
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    if a is None or b is None:
        return None
    return a == b


def node_snapshot(info: Any) -> Optional[Dict[str, Any]]:
    """Extract the comparable subset of one ``mcpNodeInfo`` payload.

    Returns ``None`` when the payload is not a node dict at all.
    """
    if not isinstance(info, dict):
        return None
    snapshot: Dict[str, Any] = {}
    missing: List[str] = []
    for field in SNAPSHOT_FIELDS:
        if field in info and info[field] is not None:
            snapshot[field] = info[field]
        else:
            missing.append(field)
    snapshot["missing"] = missing
    snapshot["complete"] = not missing
    return snapshot


def snapshot_nodes(payload: Any) -> Dict[str, Dict[str, Any]]:
    """Build ``{name: snapshot}`` from a ``list_objects``/``find_objects`` reply."""
    nodes: Sequence[Any] = ()
    if isinstance(payload, dict):
        raw = payload.get("objects")
        if isinstance(raw, list):
            nodes = raw
    elif isinstance(payload, list):
        nodes = payload
    out: Dict[str, Dict[str, Any]] = {}
    for info in nodes:
        snap = node_snapshot(info)
        if snap is None:
            continue
        name = snap.get("name")
        if not isinstance(name, str) or not name:
            # A node without a name cannot be tracked; keep the raw entry under
            # a synthetic key so the caller still sees it in the summary.
            name = "<unnamed:{0}>".format(len(out))
        out[name] = snap
    return out


def diff_snapshots(before: Dict[str, Dict[str, Any]],
                   after: Dict[str, Dict[str, Any]],
                   tolerance: float = DEFAULT_TOLERANCE) -> Dict[str, Any]:
    """Compare two snapshots produced by :func:`snapshot_nodes`.

    ``modified[*].fields`` lists the fields whose values differ; ``unknown``
    lists fields that could not be compared because one side did not read them.
    """
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    modified: List[Dict[str, Any]] = []
    unknown: List[Dict[str, Any]] = []
    unchanged = 0
    partial = False

    for name in sorted(set(before) & set(after)):
        old = before[name]
        new = after[name]
        changed: Dict[str, Any] = {}
        unread: List[str] = []
        for field in SNAPSHOT_FIELDS:
            if field not in old or field not in new:
                unread.append(field)
                continue
            verdict = _close(old[field], new[field], tolerance)
            if verdict is None:
                unread.append(field)
            elif verdict is False:
                changed[field] = {"before": old[field], "after": new[field]}
        if unread:
            partial = True
            unknown.append({"name": name, "fields": unread})
        if changed:
            modified.append({"name": name, "fields": changed})
        else:
            unchanged += 1

    return {
        "added": added,
        "removed": removed,
        "modified": modified,
        "unknown": unknown,
        "unchanged": unchanged,
        "complete": not partial,
        "counts": {
            "before": len(before),
            "after": len(after),
            "changed": len(added) + len(removed) + len(modified),
        },
    }


def transform_delta(before: Optional[Dict[str, Any]],
                    after: Optional[Dict[str, Any]],
                    tolerance: float = DEFAULT_TOLERANCE) -> Dict[str, Any]:
    """Which transform components actually changed between two node snapshots."""
    deltas: Dict[str, Any] = {}
    if not before or not after:
        return deltas
    for field in TRANSFORM_FIELDS:
        if field not in before or field not in after:
            continue
        verdict = _close(before[field], after[field], tolerance)
        if verdict is False:
            deltas[field] = {"before": before[field], "after": after[field]}
    return deltas


def compare_absolute(field: str, requested: Any, actual: Any,
                     tolerance: float = DEFAULT_TOLERANCE) -> Optional[bool]:
    """Compare an absolute request against the value read back from the scene."""
    if not isinstance(requested, (list, tuple)) or len(requested) != 3:
        return None
    if not isinstance(actual, (list, tuple)) or len(actual) != 3:
        return None
    if field == "rotation":
        # Euler angles wrap: 359 deg and -1 deg are the same orientation.
        pairs = []
        for want, got in zip(requested, actual):
            if not (_is_number(want) and _is_number(got)):
                return None
            diff = abs((float(got) - float(want) + 180.0) % 360.0 - 180.0)
            pairs.append(diff <= 1.0)
        return all(pairs)
    return _close(list(requested), list(actual), tolerance)


def summarize(nodes: Iterable[Dict[str, Any]]) -> Dict[str, Any]:
    """Compact, human-readable scene summary used in verification details."""
    names: List[str] = []
    types: Dict[str, int] = {}
    complete = True
    for snapshot in nodes:
        if not isinstance(snapshot, dict):
            continue
        name = snapshot.get("name")
        if isinstance(name, str):
            names.append(name)
        klass = snapshot.get("class")
        if isinstance(klass, str) and klass:
            types[klass] = types.get(klass, 0) + 1
        if not snapshot.get("complete", False):
            complete = False
    return {
        "count": len(names),
        "names": names,
        "types": types,
        "complete": complete,
    }
