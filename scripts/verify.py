"""Static integrity checks for the 3ds Max MCP plugin.

Runs without 3ds Max:

  * catalog builds and every tool has a bilingual description
  * every catalog tool has a matching `mcpRegister "<name>"` in MAXScript
  * every MAXScript handler name is referenced by the catalog (no orphans)
  * no forbidden MAXScript constructs anywhere in src/ms/
  * balanced (), [] and "..." per file
  * every module listed in mcp_bridge.ms actually exists on disk
  * every bridge symbol in the Listener cheatsheet still exists
  * every statistic the docs publish matches the code (tool totals,
    category/profile tables, command and module counts) -- delegated to
    test/doc_alignment_audit.py
  * offline lint of every Python and MAXScript source (syntax, encoding,
    undefined names, hardcoded paths) plus the catalog tool definitions
    (descriptions, parameter types, default values) -- delegated to
    test/offline_lint_helper.py

Usage:  python scripts/verify.py
"""

from __future__ import annotations

import os
import re
import sys
from typing import Dict, List, Set, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "python")
MAX = os.path.join(ROOT, "src", "ms")
TEST = os.path.join(ROOT, "test")

if SRC not in sys.path:
    sys.path.insert(0, SRC)

from maxmcp.catalog import Tool, build_catalog  # noqa: E402

REGISTER_RE = re.compile(r'mcpRegister\s+"([^"]+)"')
MODULE_RE = re.compile(r'"([a-z0-9_]+\.ms)"')

# Symbols the listener cheatsheet is allowed to reference.
GLOBAL_RE = re.compile(r"^global\s+(.+)$", re.M)
FN_NAME_RE = re.compile(r"^fn\s+(mcp[A-Za-z0-9_]+)", re.M)
SYMBOL_RE = re.compile(r"\bmcp[A-Za-z_][A-Za-z0-9_]*\b")

FORBIDDEN = (
    (re.compile(r"^\s*struct\s+\w+", re.M), "struct definition"),
    (re.compile(r"\bfn\s*\("), "lambda with parenthesised args"),
    (re.compile(r"=\s*fn\s+[\w]*\s*="), "lambda assignment"),
    (re.compile(r"\\\s*$", re.M), "trailing backslash line continuation"),
)

# mcp_core.ms is the one file allowed to touch the hold stack: it wraps it in
# mcpHoldBegin / mcpHoldAccept / mcpHoldCancel for everyone else.
HOLD_PATTERN = re.compile(r"theHold\.(Begin|Accept|Cancel)")
HOLD_ALLOWED = {"mcp_core.ms"}

# Bridge commands that deliberately have no catalog entry (internal helpers).
INTERNAL_COMMANDS = {"mat_create_guarded"}


def max_files() -> List[str]:
    return sorted(f for f in os.listdir(MAX) if f.endswith(".ms"))


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def strip_comments(text: str) -> str:
    """Remove comments, leaving string literals intact.

    A regex cannot do this job: MAXScript string literals may contain ``--``
    and ``/*`` (mcp_vision.ms has a self-test banner full of dashes), and
    verbatim strings (``@"..."``) escape a quote by doubling it.  Eating the
    tail of a line that merely *contains* a comment marker inside a string
    used to unbalance the rest of the file.  Newlines inside removed spans
    are preserved so reported line numbers stay true.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' or (c == "@" and i + 1 < n and text[i + 1] == '"'):
            start = i
            verbatim = c == "@"
            i += 2 if verbatim else 1
            while i < n:
                if verbatim:
                    if text[i] == '"':
                        if i + 1 < n and text[i + 1] == '"':
                            i += 2
                            continue
                        i += 1
                        break
                    i += 1
                else:
                    if text[i] == "\\":
                        i += 2
                        continue
                    if text[i] == '"':
                        i += 1
                        break
                    if text[i] in "\r\n":
                        break
                    i += 1
            out.append(text[start:i])
        elif c == "-" and i + 1 < n and text[i + 1] == "-":
            j = text.find("\n", i)
            if j < 0:
                j = n
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def mask_strings(text: str):
    """Blank out string literals (keeping newlines), report lex errors.

    Same lexer rules as ``strip_comments``; the bracket scanner then never
    has to reason about quote state at all.
    """
    out = []
    errors = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            out.append(c)
            i += 1
        elif c == '"' or (c == "@" and i + 1 < n and text[i + 1] == '"'):
            verbatim = c == "@"
            start = i
            i += 2 if verbatim else 1
            closed = False
            while i < n:
                if verbatim:
                    if text[i] == '"':
                        if i + 1 < n and text[i + 1] == '"':
                            i += 2
                            continue
                        i += 1
                        closed = True
                        break
                    if text[i] == "\n":
                        line += 1
                    i += 1
                else:
                    if text[i] == "\\":
                        if i + 1 < n and text[i + 1] == "\n":
                            line += 1
                        i += 2
                        continue
                    if text[i] == '"':
                        i += 1
                        closed = True
                        break
                    if text[i] == "\n":
                        break
                    i += 1
            if not closed:
                errors.append(("unterminated string literal", line))
            span = text[start:i]
            out.append("".join("\n" if ch == "\n" else " " for ch in span))
            line += span.count("\n")
        else:
            out.append(c)
            i += 1
    return "".join(out), errors


def check_balance(path: str, raw: str) -> List[str]:
    """Parenthesis balance, ignoring strings and comments.

    MAXScript uses () for blocks, so an imbalance is a hard syntax error.
    """
    text, lex_errors = mask_strings(strip_comments(raw))
    problems: List[str] = [
        "{0}: {1} on line {2}".format(os.path.basename(path), msg, ln)
        for msg, ln in lex_errors
    ]
    depth = 0
    bracket = 0
    line = 1
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\n":
            line += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                problems.append("{0}: unbalanced ')' at line {1}".format(os.path.basename(path), line))
                depth = 0
        elif ch == "[":
            bracket += 1
        elif ch == "]":
            bracket -= 1
            if bracket < 0:
                problems.append("{0}: unbalanced ']' at line {1}".format(os.path.basename(path), line))
                bracket = 0
        i += 1
    if depth != 0:
        problems.append("{0}: {1} unclosed '(' at end of file".format(os.path.basename(path), depth))
    if bracket != 0:
        problems.append("{0}: {1} unclosed '[' at end of file".format(os.path.basename(path), bracket))
    return problems


def print_distribution(tools: List[Tool]) -> None:
    """Per-module distribution of the catalog, for the developer's overview.

    Answers the questions the bare category counts cannot: which module
    owns how many tools, how the read-only / mutating split falls per
    module, and where the dangerous (delete/remove/clear/collapse/reset/
    cleanup/optimize) tools live.  The dangerous-token rule is shared with
    test/offline_lint_helper.py (which mirrors catalog_contract_test.py,
    the authority for the gate table) so the three never drift.
    """
    import importlib

    from maxmcp.catalog import MODULE_NAMES

    if TEST not in sys.path:
        sys.path.insert(0, TEST)
    import offline_lint_helper

    rows: List[Tuple[str, List[Tool]]] = []
    for name in MODULE_NAMES:
        try:
            module = importlib.import_module("maxmcp.catalog." + name)
        except ImportError:
            continue
        rows.append((name, list(getattr(module, "TOOLS", []))))
    if not rows:
        return

    total = len(tools)
    print("\ncatalog distribution: {0} tools / {1} modules / {2} categories".format(
        total, len(rows), len({entry.category for entry in tools})))
    print("  {0:<10} {1:>5} {2:>9} {3:>10} {4:>10}  {5}".format(
        "module", "tools", "mutating", "read-only", "dangerous", "categories"))
    sum_mutating = sum_readonly = sum_dangerous = 0
    for name, entries in rows:
        mutating = sum(1 for entry in entries if entry.mutating)
        readonly = len(entries) - mutating
        dangerous = sum(1 for entry in entries if offline_lint_helper.is_dangerous(entry))
        sum_mutating += mutating
        sum_readonly += readonly
        sum_dangerous += dangerous
        per_category: Dict[str, int] = {}
        for entry in entries:
            per_category[entry.category] = per_category.get(entry.category, 0) + 1
        print("  {0:<10} {1:>5} {2:>9} {3:>10} {4:>10}  {5}".format(
            name, len(entries), mutating, readonly, dangerous,
            " ".join("{0}={1}".format(cat, num)
                     for cat, num in sorted(per_category.items()))))
    print("  {0:<10} {1:>5} {2:>9} {3:>10} {4:>10}  {5}".format(
        "total", total, sum_mutating, sum_readonly, sum_dangerous,
        "mutating share {0:.1f}%".format(100.0 * sum_mutating / max(total, 1))))


def main() -> int:
    failures: List[str] = []
    warnings: List[str] = []

    # ------------------------------------------------------------- catalog
    catalog = build_catalog()
    tools = list(catalog)
    print("catalog: {0} tools in {1} categories".format(len(tools), len(catalog.categories())))
    for category, count in sorted(catalog.categories().items()):
        print("   {0:<14} {1}".format(category, count))
    print_distribution(tools)

    if len(tools) < 160:
        failures.append("expected at least 160 tools, found {0}".format(len(tools)))

    names = set()
    for entry in tools:
        if entry.name in names:
            failures.append("duplicate tool name: {0}".format(entry.name))
        names.add(entry.name)
        if not entry.name.startswith(tuple("abcdefghijklmnopqrstuvwxyz")):
            failures.append("{0}: tool name must start with a letter".format(entry.name))
        if not re.match(r"^[a-zA-Z0-9_-]{1,64}$", entry.name):
            failures.append("{0}: illegal characters for an MCP tool name".format(entry.name))
        if not entry.description_zh.strip() or not entry.description_en.strip():
            failures.append("{0}: missing a bilingual description".format(entry.name))
        if len(entry.description_zh.strip()) < 8:
            warnings.append("{0}: Chinese description looks too short".format(entry.name))
        for prop in (entry.schema.get("properties") or {}):
            if prop in ("undo", "undo_label"):
                failures.append("{0}: '{1}' is reserved by the transport".format(entry.name, prop))

    # --------------------------------------------------------- MAXScript side
    files = max_files()
    if "mcp_bridge.ms" not in files:
        failures.append("src/ms/mcp_bridge.ms is missing")

    registered: Dict[str, str] = {}
    declared: Set[str] = set()
    for fname in files:
        path = os.path.join(MAX, fname)
        raw = read(path)
        body = strip_comments(raw)

        for match in GLOBAL_RE.finditer(raw):
            for part in match.group(1).split(","):
                name = part.strip()
                if name:
                    declared.add(name)
        declared.update(FN_NAME_RE.findall(raw))

        for match in REGISTER_RE.finditer(body):
            handler = match.group(1)
            if handler in registered:
                failures.append(
                    "handler '{0}' registered twice ({1} and {2})".format(handler, registered[handler], fname)
                )
            registered[handler] = fname

        for pattern, label in FORBIDDEN:
            for hit in pattern.finditer(body):
                line = body[: hit.start()].count("\n") + 1
                failures.append("{0}:{1}: forbidden construct ({2})".format(fname, line, label))

        if fname not in HOLD_ALLOWED:
            for hit in HOLD_PATTERN.finditer(body):
                line = body[: hit.start()].count("\n") + 1
                failures.append(
                    "{0}:{1}: manual hold transaction (undo is handled by the dispatcher)".format(fname, line)
                )

        failures.extend(check_balance(path, raw))

    print("\nMAXScript modules: {0}, registered commands: {1}".format(len(files), len(registered)))

    missing = sorted(names - set(registered))
    orphans = sorted(set(registered) - names)
    if missing:
        # A catalog tool may intentionally map to another bridge command.
        bridged = {e.name: e.bridge_method for e in tools}
        real_missing = [m for m in missing if bridged.get(m, m) not in registered]
        if real_missing:
            failures.append(
                "{0} catalog tool(s) with no MAXScript handler: {1}".format(
                    len(real_missing), ", ".join(real_missing[:20])
                )
            )
    if orphans:
        orphans = [o for o in orphans if o not in INTERNAL_COMMANDS]
    if orphans:
        warnings.append(
            "{0} MAXScript command(s) not exposed as tools: {1}".format(
                len(orphans), ", ".join(orphans[:20])
            )
        )

    # --------------------------------------------------------- bridge loader
    bridge = strip_comments(read(os.path.join(MAX, "mcp_bridge.ms")))
    listed = set(MODULE_RE.findall(bridge))
    on_disk = set(files)
    absent = sorted(listed - on_disk)
    unlisted = sorted(on_disk - listed - {"mcp_bridge.ms"})
    if absent:
        failures.append("mcp_bridge.ms loads missing file(s): {0}".format(", ".join(absent)))
    if unlisted:
        failures.append("module(s) on disk but not loaded by mcp_bridge.ms: {0}".format(", ".join(unlisted)))

    # ------------------------------------------------------ cheatsheet symbols
    # examples/maxscript/listener_cheatsheet.ms is documentation users paste
    # straight into the Listener. Renaming a bridge function would leave it
    # silently broken, so every mcp* symbol it mentions must still exist.
    cheatsheet = os.path.join(ROOT, "examples", "maxscript", "listener_cheatsheet.ms")
    if os.path.isfile(cheatsheet):
        sheet = read(cheatsheet)
        code = "\n".join(line for line in sheet.splitlines() if not line.strip().startswith("--"))
        referenced = sorted(set(SYMBOL_RE.findall(code)))
        unknown = [symbol for symbol in referenced if symbol not in declared]
        if unknown:
            failures.append(
                "listener_cheatsheet.ms references unknown bridge symbol(s): {0}".format(
                    ", ".join(unknown)
                )
            )
        else:
            print("Listener cheatsheet: {0} bridge symbols resolve".format(len(referenced)))

    # ---------------------------------------------------- doc alignment audit
    # README statistics, docs/tools.txt and the cheatsheet are maintained by
    # hand, so they drift silently.  The audit recomputes every published
    # number from the code; it runs in-process, no Max, no network.
    test_dir = os.path.join(ROOT, "test")
    if test_dir not in sys.path:
        sys.path.insert(0, test_dir)
    try:
        import doc_alignment_audit
        audit_problems, audit_report = doc_alignment_audit.audit()
    except Exception as exc:
        failures.append("doc alignment audit could not run: {0}".format(exc))
    else:
        print()
        for line in audit_report:
            print(line)
        failures.extend(audit_problems)

    # --------------------------------------------------- offline lint (gate 7)
    # Python syntax / encoding / undefined names / hardcoded paths, MAXScript
    # encoding + structure and the catalog tool-definition audit.  Pure text
    # analysis: in-process, no Max, no network.  Violations and warnings are
    # folded into the global result so "verify is green" covers them.
    try:
        import offline_lint_helper
        lint_report = offline_lint_helper.run_checks(quiet=True)
    except Exception as exc:
        failures.append("offline lint could not run: {0}".format(exc))
    else:
        failures.extend(lint_report.failures)
        warnings.extend(lint_report.warnings)
        print("offline lint: {0} python file(s), {1} maxscript file(s), "
              "{2} tool(s) -- {3} violation(s), {4} warning(s)".format(
                  lint_report.stats.get("python_files", 0),
                  lint_report.stats.get("maxscript_files", 0),
                  lint_report.stats.get("catalog_tools", 0),
                  len(lint_report.failures), len(lint_report.warnings)))

    # ----------------------------------------------------------------- output
    if warnings:
        print("\n{0} warning(s):".format(len(warnings)))
        for warning in warnings:
            print("  ! {0}".format(warning))

    if failures:
        print("\n{0} FAILURE(S):".format(len(failures)))
        for failure in failures:
            print("  x {0}".format(failure))
        return 1

    print("\nall integrity checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
