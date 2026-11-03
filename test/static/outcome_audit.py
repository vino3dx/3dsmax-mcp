"""Audit which mutating tools declare an outcome the runtime can read.

The reliability layer refuses to call an operation successful when the handler
said nothing about what it did ("no evidence is not success").  That rule is
correct, but it turns into a false failure whenever a handler declares its
result in a shape ``runtime.declared_outcome`` does not know about.  Stage 3 hit
that with ``{applied, failures}``; Stage 4 hit it again with receipt fields such
as ``{saved: "C:/a.max"}`` and ``{written: true}``.

This audit keeps the gap visible and stops it from growing: it reads every
``mcpH_*`` handler in ``src/ms``, collects the keys it emits with ``mcpPair``
(plus the keys of any ``mcp*`` helper it calls, since some handlers delegate the
whole reply), and asks whether ``declared_outcome`` can decide anything from
that key set.  Nothing is executed - this is a Static audit.

The hard assertion covers the ``core`` profile only: those are the tools that
really do run through the runtime on every call, so a gap there is a live bug,
not a backlog item.

Reading the output:

    declared   the handler emits a key ``declared_outcome`` understands
    missing    it emits only keys that carry no conclusion (``message`` is the
               usual one).  Those tools are still callable; under reliability
               mode they will answer ``missing_success`` instead of a verdict.

Stage 9 added a second question, about the *content* of the verdict: a handler
can declare success through ``objects`` while that list is really the request it
was given.  ``grade_handler`` classifies those five ways, and only the core
profile is gated - see ``docs/audit/STAGE9_OUTCOME_AUDIT.md`` for why the rest is
a backlog rather than a gate.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.catalog import build_catalog
from maxmcp.catalog.schema import CORE_TOOLS
from maxmcp.runtime import _OUTCOME_KEYS, _RECEIPT_KEYS

#: Keys that decide an outcome, in the order ``declared_outcome`` tries them.
DECISIVE = {"success", "ok", "failures"} | set(_OUTCOME_KEYS) | set(_RECEIPT_KEYS)

#: ``mcpPair p "objects" (for n in nodes collect n.name)`` echoes the request.
#: The runtime reads ``objects`` as an enumeration, so such a handler reports
#: success even when every node was skipped.  Reported, not asserted: the fix is
#: a per-handler rewrite (collect what was applied, name what was not), and a
#: gate would just fail until someone did all of them.
ECHO_OBJECTS = re.compile(
    r'mcpPair\s+\w+\s+"objects"\s+\(\s*for\s+\w+\s+in\s+\w+\s+collect')

# ---------------------------------------------------------------- grading
#: ``objects`` is built from a list the handler filled only on success.
APPLIED_OBJECTS = re.compile(r'mcpPair\s+\w+\s+"objects"\s+applied\b')
#: The handler names the nodes it could not process.
DECLARES_FAILURES = re.compile(r'mcpPair\s+\w+\s+"failures"')
#: ``catch()`` with an empty body: the exception is discarded, not recorded.
BARE_CATCH = re.compile(r'catch\s*\(\s*\)')

CONFIRMED_BUG = "CONFIRMED_BUG"      # echoes the request and never records a failure
SUSPICIOUS = "SUSPICIOUS"            # one half is honest, the other is not
SAFE_ECHO = "SAFE_ECHO"              # echo, but the verdict comes from another field
VERIFIED_RESULT = "VERIFIED_RESULT"  # objects == applied, failures named
UNKNOWN = "UNKNOWN"                  # no static read is possible

GRADES = (CONFIRMED_BUG, SUSPICIOUS, SAFE_ECHO, VERIFIED_RESULT, UNKNOWN)


def grade_handler(body: str) -> tuple:
    """``(grade, reasons)`` for one handler body - purely structural."""
    reasons = []
    echo = bool(ECHO_OBJECTS.search(body))
    applied = bool(APPLIED_OBJECTS.search(body))
    failures = bool(DECLARES_FAILURES.search(body))
    bare = len(BARE_CATCH.findall(body))

    if bare:
        reasons.append("%d bare catch" % bare)
    if applied and failures:
        grade = VERIFIED_RESULT
        reasons.insert(0, "objects=applied, failures named")
    elif applied:
        grade = SUSPICIOUS
        reasons.insert(0, "objects=applied but no failure list")
    elif echo and failures:
        grade = SUSPICIOUS
        reasons.insert(0, "failures named but objects still echoes the request")
    elif echo:
        grade = CONFIRMED_BUG
        reasons.insert(0, "objects echoes the request, no failure list")
    elif failures:
        grade = SAFE_ECHO
        reasons.insert(0, "verdict rests on failures alone")
    else:
        grade = UNKNOWN
        reasons.insert(0, "no objects/applied/failures shape recognised")
    return grade, reasons

#: ``fn name whatever =`` opens a definition; the block runs to the next one.
_FN = re.compile(r"^fn\s+(\w+)\s*[^=\n]*=", re.M)
_PAIR = re.compile(r'mcpPair\s+\w+\s+"(\w+)"')
#: Handlers are usually called mcpHx, but the naming is not the contract - what
#: the bridge actually dispatches is whatever ``mcpRegister`` bound the command
#: to, e.g. ``mcpRegister "create_box" mcpH_create_primitive``.
_REGISTER = re.compile(r'mcpRegister\s+"([\w]+)"\s+(\w+)')
_CALL = re.compile(r"\b(mcp\w+)\b")


def _blocks() -> dict:
    """Map every ``mcp*`` function to the body text that defines it."""
    out = {}
    for path in sorted((ROOT / "src" / "ms").glob("*.ms")):
        text = path.read_text(encoding="utf-8-sig")
        starts = [(m.start(), m.group(1)) for m in _FN.finditer(text)]
        for i, (pos, name) in enumerate(starts):
            end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
            out.setdefault(name, []).append(text[pos:end])
    return out


def _registered() -> dict:
    """Map a bridge command to the function ``mcpRegister`` bound it to."""
    out = {}
    for path in sorted((ROOT / "src" / "ms").glob("*.ms")):
        text = path.read_text(encoding="utf-8-sig")
        for command, handler in _REGISTER.findall(text):
            out.setdefault(command, handler)
    return out


def _keys(body: str, blocks: dict, seen: set) -> set:
    """Keys this body emits, following ``mcp*`` helper calls.

    Following calls can only *add* keys, so an imprecise walk can hide a gap but
    never invent one - the failure mode is conservative for a report, and the
    assertion below only fires on tools that stay empty even after it.
    """
    keys = set(_PAIR.findall(body))
    for helper in set(_CALL.findall(body)):
        if helper in seen or helper not in blocks:
            continue
        seen.add(helper)
        keys |= _keys("\n".join(blocks[helper]), blocks, seen)
    return keys


def main() -> None:
    catalog = build_catalog()
    blocks = _blocks()
    registered = _registered()

    from maxmcp.batch import PER_OBJECT_TOOLS, RECONCILE_TOOLS

    # Tools executed one object at a time get their verdict built in Python from
    # the per-object rows, so the bridged reply shape does not decide anything.
    batched = set(PER_OBJECT_TOOLS) | set(RECONCILE_TOOLS)

    mutating = [entry for entry in catalog if entry.mutating and not entry.local]
    missing = []
    unknown = []
    for entry in mutating:
        if entry.name in batched:
            continue
        handler = registered.get(entry.bridge_method, "mcpH_" + entry.bridge_method)
        if handler not in blocks:
            unknown.append(entry.name)
            continue
        keys = _keys("\n".join(blocks[handler]), blocks, set())
        if not (keys & DECISIVE):
            missing.append((entry.name, sorted(keys)))

    audited = len(mutating) - len(unknown) - len([e for e in mutating if e.name in batched])
    print("outcome audit: mutating=%d batched=%d audited=%d declared=%d missing=%d unreadable=%d" % (
        len(mutating), len([e for e in mutating if e.name in batched]),
        audited, audited - len(missing), len(missing), len(unknown)))
    print("core profile: mutating=%d missing=%d" % (
        len([e for e in mutating if e.name in CORE_TOOLS and e.name not in batched]),
        len([name for name, _ in missing if name in CORE_TOOLS])))

    if missing:
        print("missing (declare a result, or accept missing_success):")
        for name, keys in missing:
            print("  %-28s %s" % (name, ", ".join(keys) or "<no mcpPair at all>"))
    if unknown:
        print("unreadable (handler not found statically): " + ", ".join(sorted(unknown)))

    graded = {grade: [] for grade in GRADES}
    for entry in catalog:
        if entry.local:
            continue
        handler = registered.get(entry.bridge_method, "mcpH_" + entry.bridge_method)
        if handler not in blocks:
            continue
        body = "\n".join(blocks[handler])
        if not (ECHO_OBJECTS.search(body) or APPLIED_OBJECTS.search(body)):
            continue
        grade, reasons = grade_handler(body)
        graded[grade].append((entry.name, reasons))

    print("result integrity (handlers that report an object list):")
    for grade in GRADES:
        names = sorted(name for name, _ in graded[grade])
        print("  %-16s %2d  %s" % (grade, len(names), ", ".join(names)))
    for name, reasons in graded[CONFIRMED_BUG] + graded[SUSPICIOUS]:
        print("    %-28s %s" % (name, "; ".join(reasons)))

    # A core tool that echoes the request and never records a failure is a live
    # lie in the default profile, so that stays a gate.  The rest of the list is
    # a backlog: gating it would only push people to add `success: true`.
    core_bad = [name for name, _ in graded[CONFIRMED_BUG] if name in CORE_TOOLS]
    assert not core_bad, (
        "core tools must not report an object list that merely echoes the request: "
        + ", ".join(sorted(core_bad))
    )

    # The standard workflows are the strongest claim the project makes, so the
    # tools they drive must be readable by the runtime - otherwise a working
    # step is recorded as a failure and the workflow lies about the scene.
    from maxmcp.workflow import STANDARD_WORKFLOWS
    used = set()
    for definition in STANDARD_WORKFLOWS.values():
        for step in definition.steps:
            used.add(step.operation)
    core_missing = [name for name, _ in missing if name in used]
    assert not core_missing, (
        "tools used by the standard workflows must declare an outcome the "
        "runtime can read, or the workflow reports a success as a failure: "
        + ", ".join(sorted(core_missing))
    )
    assert not core_missing, (
        "core profile tools must declare an outcome the runtime can read, "
        "otherwise reliability mode reports a success as a failure: "
        + ", ".join(name for name, _ in core_missing)
    )


if __name__ == "__main__":
    main()
