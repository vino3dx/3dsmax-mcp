"""Guard: a selection change invalidates the sections that publish it.

No 3ds Max required.  Source-level audit of Phase B F1 / F5 / F6.

What went wrong, measured on 3ds Max 2022
----------------------------------------
`scene.selectionCount` and `selection.count` are the same fact, published from
two different context sections.  Both change paths marked only `selection`:

  * `#selectionSetChanged` mapped to ``#("selection")``;
  * `mcpCtxTick`'s identity check appended only ``"selection"`` when
    ``selection.count`` moved.

So `context_get` kept serving a `scene` section whose `selectionCount` was
frozen at the value it had when the section was first built, while the
`selection` section next to it reported the new count.  Two numbers, one scene.
And because the server-side cache and the `context_get` tool were independent
views, `max://scene/context` could disagree with the tool as well.

The tick also bumped `mcpEvRevision` directly, so the revision moved with no
event-log row to explain it (F5); and interactive geometry edits -- vertex
drags, topology changes -- matched neither the identity check nor any
notification this release delivers (F6).

Checks:
  1. every selection notification names both `scene` and `selection`;
  2. the tick marks both when `selection.count` moves;
  3. the tick reports through the event layer, with explicit domains, instead
     of bumping the revision by hand (F5);
  4. a sliced geometry fingerprint feeds the tick, and its per-tick cost is
     bounded to a fraction of the object list (F6);
  5. the declared tool -> domain table puts `scene` on the tools that move
     `scene.selectionCount`;
  6. read-only tools declare no domain, so a poll never advances `since`;
  7. `context_get` replies are merged into the same cache the resource serves,
     so the two views agree.

Usage:  python test/static/context_selection_sync_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(REPO, "src", "python")
EVENTS = os.path.join(REPO, "src", "ms", "mcp_context.ms")
CONTEXT = os.path.join(REPO, "src", "ms", "mcp_context.ms")
SERVER = os.path.join(SRC, "maxmcp", "server.py")

if SRC not in sys.path:
    sys.path.insert(0, SRC)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def function_body(text: str, name: str) -> str:
    start = text.find("fn {0}".format(name))
    if start < 0:
        return ""
    end = text.find("\n)", start)
    return text[start:end + 2] if end > 0 else text[start:]


def case_branch(body: str, key: str) -> str:
    """The right-hand side of one `case` row, up to the end of its line."""
    match = re.search(r'^[ \t]*"%s":[ \t]*([^\n]*)' % re.escape(key), body, re.M)
    return match.group(1) if match else ""


def main() -> int:
    events = open(EVENTS, encoding="utf-8").read()
    context = open(CONTEXT, encoding="utf-8").read()
    server = open(SERVER, encoding="utf-8").read()

    domains_for = function_body(events, "mcpEvDomainsFor")
    tick = function_body(context, "mcpCtxTick")

    print("1. selection notifications invalidate scene as well")
    check("mcpEvDomainsFor found", bool(domains_for))
    for note in ("selectionsetchanged", "selectionchanged"):
        branch = case_branch(domains_for, note)
        check("#{0} names scene".format(note), '"scene"' in branch, branch or "branch missing")
        check("#{0} still names selection".format(note), '"selection"' in branch, branch or "branch missing")

    print("2. the tick marks both domains")
    check("tick found", bool(tick))
    scene_on_selection = re.search(
        r'now\[2\][^\n]*\n?\s*\(\s*\n\s*append changed "scene"', tick
    )
    check("selection.count change appends scene", bool(scene_on_selection),
          "a scene section with a stale selectionCount is what F1 reported")
    check("selection.count change appends selection",
          re.search(r'now\[2\][^\n]*\n?\s*\(\s*\n(?:[^\n]*\n)*?[^\n]*append changed "selection"', tick))

    print("3. the tick's revision bump is logged (F5)")
    check("tick reports through mcpEvFire", 'mcpEvFire "tick"' in tick,
          "the bump used to happen with no event row")
    check("tick passes explicit domains", re.search(r'mcpEvFire "tick"[^\n]*domains:', tick))
    direct = [line for line in tick.splitlines()
              if "mcpEvRevision" in line and "+=" in line]
    # One bump is allowed, and only as the fallback for "the event layer is not
    # loaded": without it the cursor would skip a change that did happen.
    fallback_only = (
        len(direct) <= 1
        and (not direct or "mcpEvRevision != undefined" in direct[0])
    )
    check("no unconditional revision bump in the tick", fallback_only,
          "found: {0}".format(direct[0].strip() if direct else ""))
    if direct:
        before = tick[: tick.find(direct[0])]
        check("the remaining bump is a failure fallback", "catch" in before.split("try ( mcpEvFire")[-1],
              "the bump must only run when mcpEvFire is unavailable")
    check("mcpEvFire accepts a domains override",
          re.search(r"fn mcpEvFire kind detail:\"\" domains:undefined", events))
    check("mcpEvFire logs the override",
          re.search(r"mcpPair row \"domains\" dlist", events))

    print("4. interactive geometry edits reach the tick (F6)")
    check("geometry sweep exists", "fn mcpCtxGeomChanged" in context)
    check("tick calls the sweep", "mcpCtxGeomChanged()" in tick)
    sweep = function_body(context, "mcpCtxGeomChanged")
    check("the sweep is bounded to a slice", "(total + 7) / 8" in sweep,
          "a full 7 ms sweep does not belong on a 25 ms pump")
    check("the sweep advances a cursor", "mcpCtxGeomCursor" in sweep)
    check("a shape change marks objects", 'append changed "objects"' in tick.split("geomChanged > 0")[-1])
    check("the modify panel edit is not treated as selection only",
          case_branch(domains_for, "modpanelobjpostchange").find('"objects"') >= 0)

    print("5. declared table carries scene for selection writers")
    from maxmcp.catalog import domains as cat_domains  # noqa: E402

    for name in ("select_objects", "select_all", "select_by_superclass", "deselect_all"):
        declared = cat_domains.domains_for(name)
        check("{0} declares scene".format(name), declared is not None and "scene" in declared,
              "got {0}".format(declared))
        check("{0} declares selection".format(name),
              declared is not None and "selection" in declared, "got {0}".format(declared))
    for name in ("mat_assign", "mat_delete", "mat_rename"):
        declared = cat_domains.domains_for(name)
        check("{0} declares selection (selection[].material)".format(name),
              declared is not None and "selection" in declared, "got {0}".format(declared))
    for name in ("anim_goto_frame", "anim_play"):
        declared = cat_domains.domains_for(name)
        check("{0} declares scene (scene.currentFrame)".format(name),
              declared is not None and "scene" in declared, "got {0}".format(declared))

    print("6. reads never advance the cursor")
    from maxmcp.catalog import build_catalog  # noqa: E402

    offenders = []
    for entry in build_catalog():
        if not entry.mutating and entry.mutates:
            offenders.append("{0}={1}".format(entry.name, entry.mutates))
    check("no read-only tool declares a domain", not offenders,
          ", ".join(offenders[:5]))
    check("every tool is declared", all(entry.mutates is not None for entry in build_catalog()))

    print("7. resource and tool share one cache")
    check("context_get replies are merged", "def _merge_context_reply" in server)
    check("merge is wired to the tool",
          re.search(r'entry\.name == "context_get":\s*\n\s*self\._merge_context_reply', server))
    check("a full detail dump is not cached", 'detail") == "full"' in server,
          "the brief snapshot must not keep a 200-row selection dump")

    from maxmcp.context import SceneContextCache  # noqa: E402

    cache = SceneContextCache()
    first = {
        "revision": 7,
        "availableSections": ["scene", "selection"],
        "sections": {
            "scene": {"domain": "scene", "changedAt": 6, "data": {"selectionCount": 0}},
            "selection": {"domain": "selection", "changedAt": 7, "data": {"count": 0}},
        },
    }
    cache.merge(first)
    # What the tool would return after a selection change: both sections again,
    # because the scene section is stale too.
    second = {
        "revision": 8,
        "availableSections": ["scene", "selection"],
        "sections": {
            "scene": {"domain": "scene", "changedAt": 8, "data": {"selectionCount": 2}},
            "selection": {"domain": "selection", "changedAt": 8, "data": {"count": 2}},
        },
    }
    cache.merge(second)
    snap = cache.snapshot(["scene", "selection"])
    check("the cached scene agrees with the tool's scene",
          snap["sections"]["scene"]["data"]["selectionCount"] == 2,
          "got {0}".format(snap["sections"]["scene"]["data"]))
    check("the cached selection agrees with the tool's selection",
          snap["sections"]["selection"]["data"]["count"] == 2)

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("context selection sync: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
