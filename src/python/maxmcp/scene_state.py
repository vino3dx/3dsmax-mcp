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


def _usable_handle(snapshot: Dict[str, Any]) -> Optional[int]:
    """A handle is only usable for identity when it is a positive integer.

    Max reports 0 when ``getHandleByAnim`` fails, and the field is absent on a
    partial snapshot; neither may be treated as an identity.
    """
    handle = snapshot.get("handle")
    if isinstance(handle, int) and not isinstance(handle, bool) and handle > 0:
        return handle
    return None


def _handle_index(snapshots: Dict[str, Dict[str, Any]]) -> Dict[int, List[str]]:
    """Map a handle to every name that reported it.

    Only handles owned by exactly one name are usable for matching: a handle
    seen twice tells us the field is not unique in this scene (a stub, an old
    Max build, or two nodes aliasing), so matching on it would invent an
    identity that does not exist.
    """
    index: Dict[int, List[str]] = {}
    for name, snapshot in snapshots.items():
        handle = _usable_handle(snapshot)
        if handle is None:
            continue
        index.setdefault(handle, []).append(name)
    return index


def _match_renames(before: Dict[str, Dict[str, Any]], after: Dict[str, Dict[str, Any]],
                   removed: List[str], added: List[str]) -> Tuple[List[Dict[str, Any]],
                                                                   List[Dict[str, Any]],
                                                                   List[str], List[str]]:
    """Pair vanished names with new names using a unique, unchanged handle.

    A rename must not look like "one object deleted, another created": the diff
    would then report a destructive change that never happened.  A handle proves
    the pairing only when exactly one node owned it on each side *and* the class
    still matches; anything weaker is reported as uncertain instead of guessed.

    Returns ``(renamed, identity_uncertain, leftover_removed, leftover_added)``.
    """
    if not removed or not added:
        return [], [], list(removed), list(added)

    before_handles = _handle_index(before)
    after_handles = _handle_index(after)
    renamed: List[Dict[str, Any]] = []
    uncertain: List[Dict[str, Any]] = []
    matched_removed: List[str] = []
    matched_added: List[str] = []

    for old_name in sorted(removed):
        handle = _usable_handle(before[old_name])
        if handle is None or len(before_handles.get(handle, [])) != 1:
            continue
        candidates = after_handles.get(handle, [])
        if len(candidates) != 1:
            continue
        new_name = candidates[0]
        if new_name not in added:
            continue
        old_class = before[old_name].get("class")
        new_class = after[new_name].get("class")
        if isinstance(old_class, str) and isinstance(new_class, str) and old_class != new_class:
            uncertain.append({
                "name": new_name,
                "candidate": old_name,
                "reason": "class_mismatch",
                "message": "The handle matches but the class changed; identity not proven",
            })
            continue
        renamed.append({"from": old_name, "to": new_name, "handle": handle})
        matched_removed.append(old_name)
        matched_added.append(new_name)

    leftover_removed = [name for name in removed if name not in matched_removed]
    leftover_added = [name for name in added if name not in matched_added]

    # Anything left over may still be a rename we cannot prove.  Say so instead
    # of silently reporting a delete plus a create.
    for new_name in leftover_added:
        new_class = after[new_name].get("class")
        candidates = [
            old_name for old_name in leftover_removed
            if not (isinstance(new_class, str) and isinstance(before[old_name].get("class"), str)
                    and before[old_name].get("class") != new_class)
        ]
        if not candidates:
            continue
        handle = _usable_handle(after[new_name])
        if handle is None:
            reason = "handle_missing"
        elif len(after_handles.get(handle, [])) > 1:
            reason = "handle_duplicated"
        else:
            reason = "handle_not_in_before"
        uncertain.append({
            "name": new_name,
            "candidates": candidates[:3],
            "reason": reason,
            "message": "This may be a rename of a vanished object; identity is not proven",
        })

    return renamed, uncertain, leftover_removed, leftover_added


def diff_snapshots(before: Dict[str, Dict[str, Any]],
                   after: Dict[str, Dict[str, Any]],
                   tolerance: float = DEFAULT_TOLERANCE) -> Dict[str, Any]:
    """Compare two snapshots produced by :func:`snapshot_nodes`.

    ``modified[*].fields`` lists the fields whose values differ; ``unknown``
    lists fields that could not be compared because one side did not read them.

    Names are the lookup key but never a proven identity: a rename is reported
    in ``renamed`` (and as a ``modified`` entry carrying ``previous_name``) when
    a unique handle proves it, and in ``identity_uncertain`` when it cannot be
    proven either way.
    """
    before_names = set(before)
    after_names = set(after)
    common = before_names & after_names
    removed = sorted(before_names - after_names)
    added = sorted(after_names - before_names)
    renamed, identity_uncertain, removed, added = _match_renames(before, after, removed, added)

    modified: List[Dict[str, Any]] = []
    unknown: List[Dict[str, Any]] = []
    unchanged = 0
    partial = False

    def compare(name: str, old: Dict[str, Any], new: Dict[str, Any],
                forced: Optional[Dict[str, Any]] = None,
                previous: Optional[str] = None) -> None:
        nonlocal unchanged, partial
        changed: Dict[str, Any] = dict(forced or {})
        unread: List[str] = []
        for field in SNAPSHOT_FIELDS:
            if forced and field in forced:
                continue
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
            entry: Dict[str, Any] = {"name": name, "fields": changed}
            if previous:
                entry["previous_name"] = previous
                entry["renamed"] = True
            modified.append(entry)
        elif not forced:
            unchanged += 1

    for name in sorted(common):
        compare(name, before[name], after[name])

    for pair in renamed:
        old = before[pair["from"]]
        new = after[pair["to"]]
        compare(pair["to"], old, new,
                forced={"name": {"before": pair["from"], "after": pair["to"]}},
                previous=pair["from"])

    return {
        "added": added,
        "removed": removed,
        "modified": modified,
        "renamed": renamed,
        "identity_uncertain": identity_uncertain,
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


# --------------------------------------------------------------- full documents
def build_snapshot(raw_nodes: Iterable[Any], *,
                   selection: Optional[Iterable[Any]] = None,
                   reported_count: Optional[int] = None,
                   truncated: bool = False,
                   source: str = "list_objects") -> Dict[str, Any]:
    """Turn one real scene read into a comparable snapshot document.

    ``reported_count`` is what Max said the scene holds; when the collected
    nodes are fewer than that, the snapshot is *partial* - a diff over it can
    only describe the nodes that were actually read.

    ``selection`` is stored as names because that is what
    ``get_selection``/``scene_info`` expose.  It is compared as a set, so the
    order Max returns the selection in never looks like a change.
    """
    nodes = list(raw_nodes)
    snapshots: Dict[str, Dict[str, Any]] = {}
    partial_nodes: List[str] = []
    missing_fields: List[str] = []
    for info in nodes:
        snap = node_snapshot(info)
        if snap is None:
            continue
        name = snap.get("name")
        if not isinstance(name, str) or not name:
            name = "<unnamed:{0}>".format(len(snapshots))
        if name in snapshots:
            # Two nodes with the same name cannot be told apart by name; keep
            # the first and say so rather than overwriting one with the other.
            partial_nodes.append(name)
            continue
        if snap["missing"]:
            partial_nodes.append(name)
            for field in snap["missing"]:
                if field not in missing_fields:
                    missing_fields.append(field)
        snapshots[name] = snap

    selection_names: List[str] = []
    selection_read = selection is not None
    for entry in (selection or []):
        if isinstance(entry, dict):
            candidate = entry.get("name")
        else:
            candidate = entry
        if isinstance(candidate, str) and candidate and candidate not in selection_names:
            selection_names.append(candidate)

    handles = [value for value in (_usable_handle(snap) for snap in snapshots.values())
               if value is not None]
    reported = reported_count if isinstance(reported_count, int) else len(snapshots)
    complete = (not truncated and not missing_fields
                and len(snapshots) >= reported and selection_read)
    return {
        "nodes": snapshots,
        "selection": selection_names,
        "selection_read": selection_read,
        "summary": summarize(snapshots.values()),
        "complete": complete,
        "truncated": bool(truncated) or len(snapshots) < reported,
        "node_count": len(snapshots),
        "reported_count": reported,
        "partial_nodes": partial_nodes,
        "missing_fields": missing_fields,
        "handles_unique": len(handles) == len(set(handles)) and len(handles) == len(snapshots),
        "source": source,
    }


def diff_documents(before: Optional[Dict[str, Any]], after: Optional[Dict[str, Any]],
                   tolerance: float = DEFAULT_TOLERANCE) -> Optional[Dict[str, Any]]:
    """Diff two :func:`build_snapshot` documents, including the selection set."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return None
    diff = diff_snapshots(before.get("nodes") or {}, after.get("nodes") or {}, tolerance)
    old_selection = set(before.get("selection") or [])
    new_selection = set(after.get("selection") or [])
    diff["selection"] = {
        "added": sorted(new_selection - old_selection),
        "removed": sorted(old_selection - new_selection),
        "unchanged": sorted(old_selection & new_selection),
        "read": bool(before.get("selection_read")) and bool(after.get("selection_read")),
    }
    diff["counts"]["selection_before"] = len(old_selection)
    diff["counts"]["selection_after"] = len(new_selection)
    diff["complete"] = bool(diff.get("complete")) and diff["selection"]["read"]
    if not diff["selection"]["read"]:
        # An unread selection is not an unchanged selection.
        diff.setdefault("unknown", []).append({"name": "<selection>", "fields": ["selection"]})
    return diff


def check_expectations(expect: Optional[Dict[str, Any]], diff: Optional[Dict[str, Any]],
                       after: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Compare the workflow's advertised goal with the observed scene diff.

    This is the goal-level question ("did the scene become what was asked for"),
    which is deliberately separate from per-step execution success.  When no
    diff exists every check is *unavailable*, never "passed".
    """
    checks: List[Dict[str, Any]] = []
    expect = expect or {}
    if not expect:
        return {"performed": False, "passed": None, "checks": []}
    if not isinstance(diff, dict):
        return {"performed": False, "passed": None, "checks": [
            {"check": name, "passed": None, "reason": "diff_unavailable"}
            for name in sorted(expect)
        ]}

    added = set(diff.get("added") or [])
    removed = set(diff.get("removed") or [])
    modified = {item.get("name") for item in diff.get("modified") or []}
    renamed_from = {item.get("from") for item in diff.get("renamed") or []}
    unchanged_names = set((after or {}).get("nodes") or {}) - added - modified

    for key in ("added_includes", "removed_includes", "modified_includes",
                "unchanged_includes", "selection_includes"):
        wanted = expect.get(key)
        if not isinstance(wanted, list):
            continue
        pool = {
            "added_includes": added,
            "removed_includes": removed,
            "modified_includes": modified,
            "unchanged_includes": unchanged_names,
            "selection_includes": set((diff.get("selection") or {}).get("unchanged") or [])
            | set((diff.get("selection") or {}).get("added") or []),
        }[key]
        for name in wanted:
            checks.append({
                "check": key,
                "value": name,
                "passed": name in pool or name in renamed_from,
            })

    for key in ("min_added", "min_removed", "min_modified"):
        wanted = expect.get(key)
        if not isinstance(wanted, int):
            continue
        actual = {"min_added": len(added), "min_removed": len(removed),
                  "min_modified": len(modified)}[key]
        checks.append({"check": key, "expected": wanted, "actual": actual,
                       "passed": actual >= wanted})

    delta = expect.get("count_delta")
    if isinstance(delta, int):
        counts = diff.get("counts") or {}
        observed = int(counts.get("after", 0)) - int(counts.get("before", 0))
        checks.append({"check": "count_delta", "expected": delta,
                       "actual": observed, "passed": observed == delta})

    passed = all(check.get("passed") is True for check in checks) if checks else None
    return {"performed": bool(checks), "passed": passed, "checks": checks}
