"""Audit the contract between a tool's declared parameters and its handler.

A catalog entry promises the client "these arguments do something".  When the
handler never reads one, the promise is false: the agent sends ``keepScene: true``,
the call succeeds, and the setting is silently thrown away.  This audit compares
the two sides statically, so that kind of drift fails a test instead of being
found months later by a confused user.

It found three real cases on the day it was written:

    scene_new.keepScene        never read, every call reset units/render/frameRate
    light_set_sun.timeOfDay    never read, no portable API behind it
    rig_skin_add_bone.rigid    never read, addBone was always called with 0

Two classes of handler are skipped because a static scan cannot read them:

* handlers that loop over a key list (``for pn in dimProps do mcpGet params pn``)
  - the primitive and spline creators;
* handlers that forward everything unread (``mcpPairs params``) to a modifier's
  property bag - the ``mod_*`` family built on ``mod_add``.

Skipping is deliberate: a false "missing" would push someone to delete a real
parameter, which is worse than not detecting a fake one.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(ROOT / "test" / "static"))

from maxmcp.catalog import build_catalog  # noqa: E402

import outcome_audit  # noqa: E402

#: A literal key the handler asks for.
READ_LITERAL = re.compile(
    r'mcp(?:Get|Str|Bool|Int|Num|Arr|ReqStr|ReqInt|ReqNum)\s+params\s+"(\w+)"')

#: A key held in a variable: the handler loops over a known list.
READ_DYNAMIC = re.compile(
    r'mcp(?:Get|Str|Bool|Int|Num|Arr|ReqStr|ReqInt|ReqNum)\s+params\s+[a-z_]\w*\b',
    re.I)

#: Everything unread is forwarded, e.g. to a modifier property bag.
READ_PASSTHROUGH = "mcpPairs params"


def _collected(body: str, blocks: dict, seen: set) -> tuple:
    """``(literals, is_dynamic)`` for one handler body, following helpers."""
    literals = set(READ_LITERAL.findall(body))
    dynamic = bool(READ_DYNAMIC.search(body)) or READ_PASSTHROUGH in body
    for helper in set(re.findall(r"\b(mcp\w+)\b", body)):
        if helper in seen or helper not in blocks:
            continue
        seen.add(helper)
        rest = "\n".join(blocks[helper])
        if "params" not in rest:
            continue
        sub_literals, sub_dynamic = _collected(rest, blocks, seen)
        literals |= sub_literals
        dynamic = dynamic or sub_dynamic
    return literals, dynamic


def report_undeclared(catalog, blocks: dict, registered: dict) -> None:
    """Print keys a handler reads that the catalog does not declare.

    The opposite direction of the assertion below, and deliberately a report
    rather than a gate: two legitimate shapes live here.

      * an alias - ``set_language`` accepts ``lang`` when ``language`` is absent,
        ``execute_maxscript`` accepts ``command`` when ``code`` is absent;
      * a shared handler - the five ``light_create_*`` wrappers all call
        ``mcpH_light_create``, so each one declares the subset that makes sense
        for its light type while the handler still understands the union.

    Printing it keeps a new surprise visible in the test log without failing a
    build over something that is usually intentional.
    """
    lines = []
    for entry in catalog:
        if entry.local:
            continue
        handler = registered.get(entry.bridge_method, "mcpH_" + entry.bridge_method)
        if handler not in blocks:
            continue
        literals, dynamic = _collected("\n".join(blocks[handler]), blocks, set())
        if dynamic:
            continue
        # A preset supplies the key, so the client never has to.
        extra = literals - set(entry.schema.get("properties") or {}) - set(entry.preset or {})
        if extra:
            lines.append("  %-26s %s" % (entry.name, sorted(extra)))
    print("undeclared-but-read: %d (alias / shared handler; see PARAMETER_SURFACE.md)"
          % len(lines))
    for line in lines:
        print(line)


def main() -> None:
    catalog = build_catalog()
    blocks = outcome_audit._blocks()
    registered = outcome_audit._registered()

    checked = 0
    skipped = 0
    fake = []
    for entry in catalog:
        if entry.local:
            continue
        handler = registered.get(entry.bridge_method, "mcpH_" + entry.bridge_method)
        if handler not in blocks:
            continue
        literals, dynamic = _collected("\n".join(blocks[handler]), blocks, set())
        if dynamic:
            skipped += 1
            continue
        declared = set(entry.schema.get("properties") or {})
        missing = declared - literals
        if missing:
            fake.append((entry.name, sorted(missing), handler))
        checked += 1

    print("param contract: checked=%d skipped(dynamic)=%d violations=%d" % (
        checked, skipped, len(fake)))
    report_undeclared(catalog, blocks, registered)
    for name, missing, handler in fake:
        print("  %-26s declares %s but %s never reads it" % (name, missing, handler))

    assert not fake, (
        "a declared parameter the handler never reads is a false promise; "
        "implement it or remove it: "
        + ", ".join("%s(%s)" % (name, ",".join(missing)) for name, missing, _ in fake)
    )


if __name__ == "__main__":
    main()
