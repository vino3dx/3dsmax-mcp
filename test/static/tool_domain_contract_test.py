#!/usr/bin/env python3
"""Static contract for the declared write -> domain mapping (context ledger).

The dispatcher used to decide "did this write change the scene?" from the undo
flag.  That is a different question, and 49 registered commands answered it
wrongly in the dangerous direction: they changed the scene while being
registered ``undoable:false``, so ``context_get(since:)`` never re-sent the
domains they invalidated.

This test pins the replacement:

A. every registered MAXScript command has exactly one row in the generated
   table, and nothing else does;
B. every row names only known domains, without duplicates, in sorted order;
C. every row equals the declaration in ``maxmcp.catalog.domains``;
D. no non-read-only tool is left undeclared;
E. read-only tools declare ``()`` -- a read must not move the revision;
F. the generated file matches what the generator would write right now;
G. the acceptance cases named in the task carry the domain set they claim;
H. the dispatcher reports *after* a successful handler and never on failure,
   and the ledger bumps the revision before stamping the domains.

Runtime behaviour (a real write actually marks render dirty, ``since`` re-sends
it, ``changedAt`` moves) cannot be proven here: see
``test/live/write_tracking_test.py``, which needs a running 3ds Max and explicit
permission.

Usage:  python test/static/tool_domain_contract_test.py [--json]
Exit code 1 on any failure.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

MS_DIR = ROOT / "src" / "ms"
TABLE_PATH = MS_DIR / "mcp_domains.ms"

REGISTER_RE = re.compile(r'mcpRegister\s+"([a-z0-9_]+)"\s+([A-Za-z0-9_]+)([^\n]*)')
ROW_RE = re.compile(r'#\("([a-z0-9_]+)",\s*#\(([^)]*)\)\)')

FAILS: List[str] = []
NOTES: List[str] = []


def fail(msg: str) -> None:
    FAILS.append(msg)


def check(condition: bool, msg: str) -> bool:
    if not condition:
        fail(msg)
    return condition


def registrations() -> Dict[str, bool]:
    """method -> undoable, parsed from the mcpRegister calls."""
    out: Dict[str, bool] = {}
    for path in sorted(MS_DIR.glob("*.ms")):
        if path.name == TABLE_PATH.name:
            continue
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        for match in REGISTER_RE.finditer(text):
            method, tail = match.group(1), match.group(3)
            if method in out:
                fail("duplicate registration of {0}".format(method))
            out[method] = "undoable:false" not in tail
    return out


def table_rows() -> Tuple[Dict[str, Tuple[str, ...]], List[str], List[str]]:
    """method -> domains, plus the raw order and the raw domain strings."""
    text = TABLE_PATH.read_text(encoding="utf-8-sig") if TABLE_PATH.exists() else ""
    if not text:
        return {}, [], []
    body = text.split("mcpDomainTable = #(", 1)
    if len(body) != 2:
        fail("mcp_domains.ms has no mcpDomainTable")
        return {}, [], []
    rows: Dict[str, Tuple[str, ...]] = {}
    order: List[str] = []
    raw: List[str] = []
    for match in ROW_RE.finditer(body[1]):
        method, inner = match.group(1), match.group(2)
        domains = tuple(d.strip().strip('"') for d in inner.split(",") if d.strip())
        if method in rows:
            fail("duplicate row for {0}".format(method))
        rows[method] = domains
        order.append(method)
        raw.append(match.group(0))
    return rows, order, raw


def main(argv: List[str]) -> int:
    as_json = "--json" in argv

    from maxmcp.catalog import build_catalog
    from maxmcp.catalog import domains as domain_rules

    catalog = build_catalog()
    by_tool = {t.name: t for t in catalog}
    by_method: Dict[str, object] = {}
    for entry in catalog:
        by_method.setdefault(entry.bridge_method, entry)

    regs = registrations()
    rows, order, _raw = table_rows()

    # -- A. table <-> registrations ------------------------------------------
    missing = sorted(set(regs) - set(rows))
    extra = sorted(set(rows) - set(regs))
    check(not missing, "registered but not declared: {0}".format(", ".join(missing[:8]) or "-"))
    check(not extra, "declared but not registered: {0}".format(", ".join(extra[:8]) or "-"))

    # -- B. shape ------------------------------------------------------------
    for method, domains in sorted(rows.items()):
        check(domain_rules.is_known_domains(domains),
              "{0}: unknown domain in {1}".format(method, domains))
        check(len(set(domains)) == len(domains), "{0}: duplicate domain in {1}".format(method, domains))
    check(order == sorted(order), "mcp_domains.ms rows are not sorted (regenerate)")

    # -- C. table == catalog declaration -------------------------------------
    # Registered commands that deliberately have no MCP tool.  `bridge_stop`
    # is one: it is reachable from the Max panel and the Listener, never from an
    # AI client (Phase B F14), yet it stays in the table so "every registered
    # command is declared" remains true.  A command with no tool must declare
    # nothing -- no caller would ever read the domains it marked.
    no_tool = {"bridge_stop"}

    mismatched: List[str] = []
    for method, domains in sorted(rows.items()):
        entry = by_method.get(method)
        if entry is None:
            if method in no_tool:
                check(not domains,
                      "{0}: no tool, so it must declare no domain (got {1})".format(method, domains))
                continue
            mismatched.append("{0}: no catalog tool".format(method))
            continue
        if tuple(entry.mutates) != domains:
            mismatched.append(
                "{0}: table {1} vs catalog {2}".format(method, domains, tuple(entry.mutates))
            )
    check(not mismatched, "table/catalog disagreement: {0}".format("; ".join(mismatched[:5]) or "-"))

    # -- D. no undeclared writer --------------------------------------------
    undeclared = sorted(t.name for t in catalog if t.mutating and t.mutates is None)
    check(
        not undeclared,
        "non-read-only tools without a mutates declaration ({0}): {1}".format(
            len(undeclared), ", ".join(undeclared[:10])
        ),
    )

    # A declaration is not optional for a registered command either: a name that
    # resolves to nothing would fall back to the prefix heuristic at run time.
    unresolved = sorted(m for m in regs if domain_rules.domains_for(m) is None)
    check(not unresolved, "undeclared commands: {0}".format(", ".join(unresolved[:10]) or "-"))

    # -- E. reads declare nothing -------------------------------------------
    noisy_reads = sorted(t.name for t in catalog if not t.mutating and t.mutates)
    check(not noisy_reads, "read-only tools declaring domains: {0}".format(", ".join(noisy_reads[:10]) or "-"))

    empty_declared = sorted(t.name for t in catalog if t.mutating and t.mutates == ())
    NOTES.append(
        "{0} mutating tools declare () (viewport / files / bridge): {1}".format(
            len(empty_declared), ", ".join(empty_declared)
        )
    )

    # -- F. generated file is current ---------------------------------------
    gen_text = None
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "gen_tool_domains", str(ROOT / "scripts" / "gen_tool_domains.py")
        )
        module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(module)  # type: ignore[union-attr]
        table, undeclared_gen = module.declarations()
        gen_text = module.render(table)
        check(not undeclared_gen, "generator reports undeclared: {0}".format(", ".join(undeclared_gen[:8])))
    except Exception as exc:  # noqa: BLE001
        fail("could not run the generator: {0}: {1}".format(type(exc).__name__, exc))

    if gen_text is not None and TABLE_PATH.exists():
        current = TABLE_PATH.read_text(encoding="utf-8-sig")
        check(
            current.replace("\r\n", "\n").rstrip("\n") == gen_text.replace("\r\n", "\n").rstrip("\n"),
            "mcp_domains.ms is stale: run python scripts/gen_tool_domains.py",
        )

    # -- G. the cases the task names ---------------------------------------
    expectations = {
        # one domain, exactly: a render-setting write must not invalidate project
        "render_set_resolution": ("render",),
        "render_set_engine": ("render",),
        "render_set_output": ("render",),
        "render_element_add": ("render",),
        "render_element_remove": ("render",),
        "render_element_set_output": ("render",),
        # a material write can introduce a bitmap, so assets is part of it
        "mat_set_slot": ("materials", "assets"),
        "mat_set_map_slot": ("materials", "assets"),
        "mat_set_diffuse": ("materials", "assets"),
        # selection-only write, no geometry change
        "poly_select": ("selection",),
        # multi-domain: scene + animation + render all carry the frame settings
        "set_time_config": ("scene", "animation", "render"),
        # bake runs two backends; materials + assets cover both result shapes
        "bake_texture": ("materials", "assets"),
        # arbitrary code
        "execute_maxscript": domain_rules.ALL_DOMAINS,
        "execute_python": domain_rules.ALL_DOMAINS,
    }
    for method, want in expectations.items():
        got = rows.get(method)
        if got is None:
            fail("{0}: no table row".format(method))
            continue
        check(tuple(got) == tuple(want), "{0}: declared {1}, expected {2}".format(method, got, want))

    # Multi-domain writes must name every domain that changes, not a subset.
    for method in ("create_box", "delete_objects", "import_fbx", "scene_new"):
        got = rows.get(method)
        if got is None:
            fail("{0}: no table row".format(method))
            continue
        check(len(got) >= 2, "{0}: expected a multi-domain declaration, got {1}".format(method, got))
    check(rows.get("create_box") == ("scene", "objects", "selection"),
          "create_box must move scene.count, objects and selection")

    # mat -> assets and render_element -> render, as the task requires.
    check("assets" in (rows.get("mat_set_slot") or ()), "mat_* must invalidate assets")
    check(rows.get("render_element_add") == ("render",),
          "render_element_* must invalidate render and nothing else")

    # -- G2. cross-domain fields (Phase B F4) ------------------------------
    # A field that lives in a *different* section from the tool's name prefix is
    # the mismatch no prefix table can see: `select_objects` moves a number that
    # `scene` publishes, `mat_assign` changes the string a `selection` row
    # prints.  domains.py records those facts explicitly; this walks them so the
    # next tool added to one of these families cannot quietly lose the owner.
    field_map = getattr(domain_rules, "CROSS_DOMAIN_FIELDS", {})
    check(len(field_map) >= 4, "CROSS_DOMAIN_FIELDS is missing or too small")

    def effective(entry_name: str):
        """The declaration the dispatcher will actually use for this name."""
        tool = by_tool.get(entry_name)
        if tool is not None:
            return tuple(tool.mutates or ())
        return domain_rules.domains_for(entry_name)

    for field_path, spec in field_map.items():
        owner = spec.get("owner")
        for writer in spec.get("writers", ()):
            declared = effective(writer)
            if declared is None:
                fail("{0}: writer {1} has no declaration".format(field_path, writer))
                continue
            check(owner in declared,
                  "{0}: {1} does not declare {2} (got {3})".format(
                      field_path, writer, owner, declared))
        # A reader must not declare a domain: reads do not move the cursor.
        for reader in spec.get("readers", ()):
            declared = effective(reader)
            check(not declared,
                  "{0}: reader {1} declares {2}; reads must not advance `since`".format(
                      field_path, reader, declared))

    # -- H. dispatcher / ledger invariants ---------------------------------
    net = (MS_DIR / "mcp_core.ms").read_text(encoding="utf-8-sig")
    events = (MS_DIR / "mcp_context.ms").read_text(encoding="utf-8-sig")

    dispatch = net.split("fn mcpDispatch method params", 1)
    check(len(dispatch) == 2, "mcpDispatch not found in mcp_net.ms")
    body = dispatch[1].split("fn mcpHandleLineInner", 1)[0] if len(dispatch) == 2 else ""

    check("mcpEntryUndoable" not in body,
          "mcpDispatch still consults the undo flag to decide notification")
    check(re.search(r"if not wantUndo do\s*\(\s*local readOnlyResult = handler params", body) is not None,
          "non-undo branch no longer reads as expected")
    check("mcpDispatchNotify method domains readOnlyResult" in body,
          "the non-undo branch does not notify the ledger")
    check("mcpDispatchNotify method domains result" in body,
          "the undo branch does not notify the ledger after success")
    try:
        check(body.index("if failure != undefined do throw failure")
              < body.index("mcpDispatchNotify method domains result"),
              "the undo branch notifies before deciding whether the handler failed")
    except ValueError as exc:
        fail("could not locate the success/failure ordering in mcpDispatch: {0}".format(exc))

    notify = net.split("fn mcpDispatchNotify method domains result", 1)
    check(len(notify) == 2, "mcpDispatchNotify not found")
    if len(notify) == 2:
        nbody = notify[1].split("fn mcpDispatch method params", 1)[0]
        check('mcpGet result "ok"' in nbody, "mcpDispatchNotify does not check a payload-level failure flag")
        check("flag == false" in nbody, "mcpDispatchNotify does not skip on ok:false")

    after = events.split("fn mcpEvAfterWrite method domains:undefined", 1)
    check(len(after) == 2, "mcpEvAfterWrite not found")
    if len(after) == 2:
        ebody = after[1].split("fn mcpEvWanted", 1)[0]
        check("if list.count == 0 then return mcpEvRevision" in ebody,
              "mcpEvAfterWrite can bump the revision for an empty domain set")
        try:
            check(ebody.index("mcpEvRevision += 1") < ebody.index("mcpCtxMarkDirty list"),
                  "the revision must be bumped before the domain stamp is taken")
        except ValueError as exc:
            fail("could not locate the bump/stamp ordering in mcpEvAfterWrite: {0}".format(exc))
        check("domains != undefined" in ebody, "mcpEvAfterWrite ignores the declared domains argument")

    # -- report -------------------------------------------------------------
    total_reads = sum(1 for t in catalog if not t.mutating)
    summary = {
        "registered_commands": len(regs),
        "table_rows": len(rows),
        "catalog_tools": len(catalog),
        "read_only_tools": total_reads,
        "mutating_declared_empty": len(empty_declared),
        "failures": FAILS,
        "notes": NOTES,
    }
    if as_json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("registered commands : {0}".format(summary["registered_commands"]))
        print("table rows          : {0}".format(summary["table_rows"]))
        print("catalog tools       : {0} ({1} read-only)".format(
            summary["catalog_tools"], summary["read_only_tools"]))
        print("declared empty      : {0}".format(summary["mutating_declared_empty"]))
        for note in NOTES:
            print("  note: " + note)
        if FAILS:
            print("\n=== failures ({0}) ===".format(len(FAILS)))
            for item in FAILS:
                print("  FAIL " + item)
        else:
            print("\ndomain contract holds")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
