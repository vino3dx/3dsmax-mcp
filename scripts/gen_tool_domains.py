#!/usr/bin/env python3
"""Compile the per-tool domain declarations into ``src/ms/mcp_domains.ms``.

The declaration lives in Python (``src/python/maxmcp/catalog/domains.py``)
because that is where the tool catalog and its contract tests live.  The
dispatcher runs inside 3ds Max and has no access to Python, so the same table is
compiled into MAXScript.  One source, one generated artefact, and a drift gate:

    python scripts/gen_tool_domains.py            # write the .ms file
    python scripts/gen_tool_domains.py --check    # exit 1 when it is stale

``test/static/tool_domain_contract_test.py`` calls ``--check`` and additionally
fails when a registered command has no declaration at all.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src" / "python"))

MS_DIR = ROOT / "src" / "ms"
OUT_PATH = MS_DIR / "mcp_domains.ms"

#: mcpRegister "method" mcpH_handler [undoable:false] [label:"..."]
REGISTER_RE = re.compile(r'mcpRegister\s+"([a-z0-9_]+)"\s+([A-Za-z0-9_]+)([^\n]*)')

HEADER = """\
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_domains.ms
   GENERATED FILE -- edit src/python/maxmcp/catalog/domains.py instead, then run
   `python scripts/gen_tool_domains.py`.

   What this file is
   -----------------
   The declared answer to one question per command: "which context domains does
   this write invalidate?".  mcpDispatch reads it through mcpToolDomains() and
   tells the ledger, so the answer no longer comes from the undo flag.  Those
   two properties are not the same: a command can change the scene and still be
   registered undoable:false (render_set_*, bake_*, poly_select, set_units ...),
   and a command can be undoable:true while only moving the selection.

   #() is a declaration, not a gap: it says the command changes nothing the nine
   domains describe (viewport state, files on disk, bridge configuration), so
   the revision must not move -- a read-only client would otherwise be pushed a
   `since` cursor forward for a change that never happened.

   Regenerate after adding or renaming a tool; the static contract test fails
   while this file and the catalog disagree.
-----------------------------------------------------------------------------*/

global mcpDomainNames, mcpDomainTable, mcpToolDomains

-- Declared once so callers can validate a table entry without hardcoding names.
if mcpDomainNames == undefined do mcpDomainNames = #(
{domain_names}
)

/* Assigned unconditionally: this is derived data, so reloading the module must
   pick up a regenerated table instead of keeping the copy from first load. */
mcpDomainTable = #(
{rows}
)

/* Declared domains for a bridge command, or undefined when the command has no
   row.  Linear scan on purpose: the table is ~360 rows of interned strings, the
   same order of cost as mcpFindEntry's walk over the registry, and a hashtable
   would have to be rebuilt on every reload. */
fn mcpToolDomains method =
(
    if method == undefined then return undefined
    for row in mcpDomainTable do
    (
        if row[1] == method then return row[2]
    )
    undefined
)
"""


def registered() -> List[Tuple[str, str, bool]]:
    """(method, file, undoable) for every mcpRegister call in src/ms."""
    out: List[Tuple[str, str, bool]] = []
    seen: Dict[str, str] = {}
    for path in sorted(MS_DIR.glob("*.ms")):
        if path.name == OUT_PATH.name:
            continue
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        for match in REGISTER_RE.finditer(text):
            method, _handler, tail = match.group(1), match.group(2), match.group(3)
            if method in seen:
                raise SystemExit(
                    "duplicate registration: {0} in {1} and {2}".format(
                        method, seen[method], path.name
                    )
                )
            seen[method] = path.name
            out.append((method, path.name, "undoable:false" not in tail))
    return out


def declarations() -> Tuple[Dict[str, Tuple[str, ...]], List[str]]:
    """method -> declared domains, plus the list of undeclared commands."""
    from maxmcp.catalog import build_catalog
    from maxmcp.catalog.domains import KNOWN_DOMAINS, domains_for

    catalog = build_catalog()
    by_method: Dict[str, Tuple[str, ...]] = {}
    for entry in catalog:
        if entry.mutates is None:
            continue
        by_method.setdefault(entry.bridge_method, tuple(entry.mutates))

    table: Dict[str, Tuple[str, ...]] = {}
    undeclared: List[str] = []
    for method, _file, _undoable in registered():
        if method in by_method:
            domains = by_method[method]
        else:
            from maxmcp.catalog.domains import domains_for

            resolved = domains_for(method)
            if resolved is None:
                undeclared.append(method)
                continue
            domains = tuple(resolved)
        for name in domains:
            if name not in KNOWN_DOMAINS:
                raise SystemExit(
                    "unknown domain {0!r} declared for {1}".format(name, method)
                )
        table[method] = domains
    return table, undeclared


def render(table: Dict[str, Tuple[str, ...]]) -> str:
    from maxmcp.catalog.domains import DOMAIN_NAMES

    skill_lines = "\n".join(
        '    "{0}"{1}'.format(d, "," if i < len(DOMAIN_NAMES) - 1 else "")
        for i, d in enumerate(DOMAIN_NAMES)
    )
    rows = []
    for method in sorted(table):
        domains = table[method]
        if domains:
            body = ", ".join('"{0}"'.format(d) for d in domains)
            rows.append('    #("{0}", #({1}))'.format(method, body))
        else:
            rows.append('    #("{0}", #())'.format(method))
    return HEADER.format(domain_names=skill_lines, rows=",\n".join(rows))


def write(text: str) -> None:
    # MAXScript on Windows wants CRLF and reads the file as ANSI unless it sees
    # a UTF-8 BOM; the content is ASCII today, the BOM keeps it stable anyway.
    data = "\ufeff" + text.replace("\r\n", "\n").replace("\n", "\r\n")
    OUT_PATH.write_bytes(data.encode("utf-8"))


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when the generated file is stale")
    args = parser.parse_args(argv[1:])

    table, undeclared = declarations()
    if undeclared:
        print("undeclared commands ({0}):".format(len(undeclared)))
        for name in undeclared:
            print("  " + name)
        if not args.check:
            print("\nrefusing to write a table with holes", file=sys.stderr)
            return 1

    text = render(table)

    if args.check:
        if not OUT_PATH.exists():
            print("missing {0}".format(OUT_PATH))
            return 1
        current = OUT_PATH.read_text(encoding="utf-8-sig")
        if current.replace("\r\n", "\n").rstrip("\n") != text.replace("\r\n", "\n").rstrip("\n"):
            print("stale: {0} does not match the catalog".format(OUT_PATH))
            return 1
        print("up to date: {0} ({1} commands)".format(OUT_PATH.name, len(table)))
        return 0

    write(text)
    print("wrote {0} ({1} commands)".format(OUT_PATH, len(table)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
