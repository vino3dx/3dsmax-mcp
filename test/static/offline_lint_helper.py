#!/usr/bin/env python3
r"""Offline static analysis helper -- the seventh no-Max gate.

Why this exists
---------------
The other gates each own one slice of the repository: ``ms_check.py`` reports
MAXScript encoding / brackets / undefined ``mcp*`` symbols, ``verify.py``
cross-checks catalog tools against MAXScript registrations, and
``catalog_contract_test.py`` drives the real server against a MockBridge.  What
nobody owned was the *Python source itself* outside the import graph of the
catalog: ``scripts/`` and ``test/`` are never imported by the server, so a
syntax error, a stray encoding or a name typo there only surfaces when a
developer happens to run that exact file.  This helper closes that gap and,
while it is at it, audits every tool definition in ``src/python/maxmcp/catalog/``
for description / parameter-type / default-value mistakes.

What it checks
--------------
1. Python sources (``src/python``, ``scripts``, ``test``; ``examples`` joins for
   syntax / encoding / names only -- its sample commands deliberately show
   Windows path syntax):
   * syntax   -- ``ast.parse``; a SyntaxError means the file cannot run at all
   * encoding -- strict UTF-8, no BOM (every tool on Windows agrees on that)
   * names    -- an AST *load* of a name that is never imported, defined or
                 built in (the classic "works on my machine because of a stale
                 ``sys.path`` entry" bug); skipped for ``import *`` modules
   * imports  -- imported but never used (warning only; ``__init__.py``
                 re-export hubs and ``__all__`` names are exempt)
   * paths    -- author-machine paths (user profiles, POSIX homes) and
                 ``%ENV%`` literals in *code*; comments and docstrings are
                 masked out with ``tokenize`` first, so documented example
                 paths stay legal.  Standard install locations
                 (``C:\Program Files``, ``C:\Windows``) are the platform
                 contract and stay allowed.
2. MAXScript sources (every ``.ms`` in the repository):
   * encoding -- the Autodesk rule: pure ASCII, ANSI/GBK, or UTF-8 **with**
                 BOM; a UTF-8 file *without* BOM is mis-decoded by ``fileIn``
   * structure -- balanced ``()``/``[]`` and terminated strings, reusing the
                 proven lexer from ``ms_check.py`` (never reimplemented)
3. Catalog tool definitions (every module in ``maxmcp.catalog.MODULE_NAMES``):
   * bilingual descriptions present, not placeholders, not identical
   * parameter ``type`` spelled as one of the six JSON schema types
   * ``default`` / ``enum`` values match the declared type (``bool`` is not an
     ``integer`` -- ``isinstance(True, int)`` is ``True`` in Python!)
   * ``minimum``/``maximum`` only on numeric types and correctly ordered
   * category spelled as one of the eight documented categories
   * no tool name declared by two modules

Parameter *names* are deliberately not case-checked here: the catalog mixes
lowerCamelCase (mirroring MAXScript property names, e.g. ``dryRun``) with
snake_case (the vision family reads ``"max_edge"`` by that exact name), and
the load-bearing invariant -- a declared parameter must be read by the
bridge handler under the same name -- belongs to the bridge contract, not to
a local naming heuristic.

Everything here is pure text analysis: no 3ds Max instance, no port 8765, no
registry, no network.  ``scripts/verify.py`` runs this helper as part of its
global integrity check.

Usage:
    python test/offline_lint_helper.py           # human-readable report
    python test/offline_lint_helper.py --json    # machine-readable report
Exit code 0 when clean (warnings allowed), 1 on violations, 2 on harness
errors (e.g. the catalog no longer imports).
"""

from __future__ import annotations

import ast
import builtins
import io
import json
import os
import re
import sys
import tokenize
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

for _extra in (os.path.join(REPO, "src", "python"), HERE):
    if _extra not in sys.path:
        sys.path.insert(0, _extra)

import ms_check  # noqa: E402  -- MAXScript lexer, reused (never reimplemented)

from maxmcp.catalog import MODULE_NAMES  # noqa: E402

SRC_PY = os.path.join(REPO, "src", "python")
SCRIPTS = os.path.join(REPO, "scripts")
EXAMPLES = os.path.join(REPO, "examples")
MS_DIR = os.path.join(REPO, "src", "ms")

#: Directories whose Python files get the full lint (examples/ is user-facing
#: documentation: its sample commands deliberately show Windows path syntax).
PY_LINT_DIRS = (SRC_PY, SCRIPTS, HERE)
#: Directories scanned for syntax / encoding / name problems only.
PY_SCAN_DIRS = PY_LINT_DIRS + (EXAMPLES,)
#: Every .ms file in the repository, wherever it lives.
MS_DIRS = (MS_DIR, os.path.join(EXAMPLES, "maxscript"), HERE)

#: The six JSON schema types the property DSL can emit.
JSON_TYPES = ("string", "number", "integer", "boolean", "array", "object")

#: The eight documented categories (BASE_CATEGORIES + the four named subsets).
KNOWN_CATEGORIES = (
    "system", "scene", "files", "objects",
    "modeling", "shading", "animation", "pipeline",
)

#: Name tokens that make a tool "dangerous" for reporting.  Mirrors
#: ``catalog_contract_test.DANGEROUS_NAME_TOKENS`` (the authority for the
#: gate table); kept as a local copy so gate 7 never depends on gate 6.
DANGEROUS_NAME_TOKENS = frozenset(
    {"delete", "remove", "clear", "collapse", "reset", "cleanup", "optimize"}
)

#: Description text that means "nobody wrote this yet".
PLACEHOLDER_RE = re.compile(
    r"(?i)\b(?:todo|tbd|fixme|wip|placeholder)\b|\bxxx+\b|待补|待定|未完成"
)
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")

#: Hardcoded paths / env-var literals that must never appear in *code*
#: (string literals and comments are masked out before scanning).  Standard
#: install locations (``C:\Program Files``, ``C:\Windows``) are part of the
#: platform contract -- installers and local diagnostics legitimately name
#: them -- so only *author-machine* paths (user profiles, POSIX homes) and
#: ``%ENV%`` literals are violations.
HARDCODE_PATTERNS: Tuple[Tuple["re.Pattern[str]", str], ...] = (
    (re.compile(r"\b[A-Za-z]:[\\/]Users[\\/](?!Public[\\/]|Default[\\/])[A-Za-z0-9._-]+"),
     "hardcoded user-profile path"),
    (re.compile(r"%(?:LOCALAPPDATA|APPDATA|USERPROFILE|PROGRAMFILES|PROGRAMDATA"
                r"|TEMP|TMP|HOMEPATH|HOMEDRIVE)%", re.I),
     "environment-variable literal (use os.environ)"),
    (re.compile(r"(?<![\w.])(?:/home/|/Users/)[A-Za-z0-9._-]+"),
     "hardcoded POSIX home path"),
)

#: Names the interpreter provides without any import or definition.
IMPLICIT_NAMES = frozenset({
    "__file__", "__name__", "__doc__", "__spec__", "__loader__",
    "__package__", "__builtins__", "__debug__", "__path__", "__class__",
    "__qualname__", "__module__", "__dict__", "__annotations__",
})
BUILTIN_NAMES = frozenset(dir(builtins)) | IMPLICIT_NAMES

_MATCH_NODES = tuple(
    getattr(ast, name) for name in ("MatchAs", "MatchStar", "MatchMapping")
    if hasattr(ast, name)
)


# --------------------------------------------------------------------- report
@dataclass
class Report:
    failures: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    stats: Dict[str, int] = field(default_factory=dict)

    @property
    def clean(self) -> bool:
        return not self.failures


class HarnessError(Exception):
    """The helper itself could not run (e.g. the catalog no longer imports)."""


def rel(path: str) -> str:
    return os.path.relpath(path, REPO).replace("\\", "/")


# ------------------------------------------------------------------ discovery
def iter_py_files(dirs) -> List[str]:
    out: List[str] = []
    for base in dirs:
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
            out.extend(os.path.join(dirpath, fn)
                       for fn in sorted(filenames) if fn.endswith(".py"))
    return sorted(out)


def iter_ms_files(dirs) -> List[str]:
    out: List[str] = []
    for base in dirs:
        if not os.path.isdir(base):
            continue
        out.extend(os.path.join(base, fn)
                   for fn in sorted(os.listdir(base)) if fn.endswith(".ms"))
    return sorted(out)


# ------------------------------------------------------------- python checks
def check_python_syntax(path: str, report: Report) -> Optional[ast.AST]:
    """Encoding / BOM / syntax.  Returns the parsed tree, or None on error."""
    name = rel(path)
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        report.warnings.append("%s: UTF-8 BOM (keep .py files BOM-less)" % name)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        report.failures.append("%s: not valid UTF-8 (%s)" % (name, exc))
        return None
    try:
        return ast.parse(text.replace("\r\n", "\n"), filename=name)
    except SyntaxError as exc:
        report.failures.append("%s:%s: syntax error: %s" % (name, exc.lineno, exc.msg))
        return None
    except ValueError as exc:  # e.g. source contains null bytes
        report.failures.append("%s: cannot be parsed (%s)" % (name, exc))
        return None


def _target_names(node) -> Set[str]:
    """Names bound by an assignment / for / with target."""
    out: Set[str] = set()
    if isinstance(node, ast.Name):
        out.add(node.id)
    elif isinstance(node, (ast.Tuple, ast.List)):
        for elt in node.elts:
            out |= _target_names(elt)
    elif isinstance(node, ast.Starred):
        out |= _target_names(node.value)
    return out


def _bindings(tree: ast.AST) -> Tuple[Set[str], bool, Dict[str, int]]:
    """(bound names, uses ``import *``, {imported name: line number}).

    Scope-insensitive on purpose: a name bound in *any* branch counts as
    bound, which is the conservative direction for the undefined-name check.
    """
    bound: Set[str] = set()
    imported: Dict[str, int] = {}
    star = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                name = alias.asname or alias.name.split(".")[0]
                bound.add(name)
                imported[name] = node.lineno
        elif isinstance(node, ast.ImportFrom):
            if node.module == "__future__":
                continue
            for alias in node.names:
                if alias.name == "*":
                    star = True
                    continue
                name = alias.asname or alias.name
                bound.add(name)
                imported[name] = node.lineno
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            bound.add(node.name)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                bound |= _target_names(target)
        elif isinstance(node, ast.AnnAssign):
            if node.target is not None:
                bound |= _target_names(node.target)
        elif isinstance(node, ast.AugAssign):
            bound |= _target_names(node.target)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            bound |= _target_names(node.target)
        elif isinstance(node, ast.NamedExpr):
            bound |= _target_names(node.target)
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            for item in node.items:
                if item.optional_vars is not None:
                    bound |= _target_names(item.optional_vars)
        elif isinstance(node, ast.ExceptHandler):
            if node.name:
                bound.add(node.name)
        elif isinstance(node, ast.arg):
            bound.add(node.arg)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            bound.update(node.names)
        elif _MATCH_NODES and isinstance(node, _MATCH_NODES):
            name = getattr(node, "name", None) or getattr(node, "rest", None)
            if name:
                bound.add(name)
    return bound, star, imported


def _loads(tree: ast.AST) -> Set[str]:
    return {
        node.id for node in ast.walk(tree)
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
    }


def _exported(tree: ast.AST) -> Set[str]:
    """Names listed in a module-level ``__all__``."""
    out: Set[str] = set()
    for node in getattr(tree, "body", []):
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(t, ast.Name) and t.id == "__all__"
                   for t in node.targets):
            continue
        if isinstance(node.value, (ast.List, ast.Tuple, ast.Set)):
            for elt in node.value.elts:
                if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                    out.add(elt.value)
    return out


def check_undefined_names(path: str, tree: ast.AST, report: Report) -> None:
    """A *load* of a name that is never imported, defined or built in."""
    name = rel(path)
    bound, star, imported = _bindings(tree)
    if star:  # ``from x import *`` hides everything: cannot analyse
        return
    loads = _loads(tree)
    for used in sorted(loads):
        if used in bound or used in BUILTIN_NAMES or used.startswith("__"):
            continue
        report.failures.append(
            "%s: name '%s' is used but never imported or defined" % (name, used))


def check_unused_imports(path: str, tree: ast.AST, report: Report) -> None:
    """Imported but never referenced (warning; re-export hubs are exempt)."""
    name = rel(path)
    _, _, imported = _bindings(tree)
    if os.path.basename(path) == "__init__.py":
        return  # re-export hub: every import is the public surface
    loads = _loads(tree)
    exported = _exported(tree)
    for imported_name in sorted(imported):
        if imported_name in loads or imported_name in exported:
            continue
        report.warnings.append("%s:%d: unused import '%s'"
                               % (name, imported[imported_name], imported_name))


def _docstring_spans(tree: ast.AST) -> List[Tuple[Tuple[int, int], Tuple[int, int]]]:
    """Position spans of module / class / function docstrings."""
    spans: List[Tuple[Tuple[int, int], Tuple[int, int]]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef,
                                 ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", [])
        if not body:
            continue
        first = body[0]
        if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            spans.append(((first.lineno, first.col_offset),
                          (first.end_lineno, first.end_col_offset)))
    return spans


def _blank(lines: List[str], start: Tuple[int, int], end: Tuple[int, int]) -> None:
    """Replace a (row, col) span with spaces, preserving newlines."""
    r1, c1 = start
    r2, c2 = end
    for r in range(r1, r2 + 1):
        if r - 1 >= len(lines):
            break
        line = lines[r - 1]
        lo = c1 if r == r1 else 0
        hi = c2 if r == r2 else len(line)
        segment = line[lo:hi]
        blanked = "".join("\n" if ch == "\n" else " " for ch in segment)
        lines[r - 1] = line[:lo] + blanked + line[hi:]


def check_hardcoded_paths(path: str, tree: ast.AST, report: Report) -> None:
    """Drive-letter / env-var / POSIX-home paths in code (docs stay legal)."""
    name = rel(path)
    with open(path, "rb") as fh:
        text = fh.read().decode("utf-8", errors="replace").replace("\r\n", "\n")
    lines = text.splitlines(keepends=True)
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                _blank(lines, tok.start, tok.end)
    except tokenize.TokenError:
        report.warnings.append("%s: tokenizer failed, hardcoded-path scan skipped" % name)
        return
    for start, end in _docstring_spans(tree):
        _blank(lines, start, end)
    masked = "".join(lines)
    for pattern, label in HARDCODE_PATTERNS:
        for match in pattern.finditer(masked):
            line_no = masked.count("\n", 0, match.start()) + 1
            snippet = ""
            if 0 < line_no <= len(text.splitlines()):
                snippet = text.splitlines()[line_no - 1].strip()
            report.failures.append("%s:%d: %s -- %s" % (name, line_no, label, snippet[:90]))


# ----------------------------------------------------------- maxscript checks
def ms_encoding_state(raw: bytes) -> Tuple[str, bool]:
    """(state label, is the file a problem) per the Autodesk fileIn rule."""
    if raw.startswith(b"\xef\xbb\xbf"):
        return "utf-8+bom", False
    if not any(b > 127 for b in raw):
        return "ascii", False
    try:
        raw.decode("gbk")
    except UnicodeDecodeError:
        return "utf-8 without BOM", True
    return "ansi(gbk)", False


def check_ms_encoding(path: str, report: Report) -> str:
    """The Autodesk fileIn rule; returns the text for the structure check."""
    name = rel(path)
    with open(path, "rb") as fh:
        raw = fh.read()
    state, bad = ms_encoding_state(raw)
    if bad:
        report.failures.append(
            "%s: %s + non-ASCII -- MAXScript reads .ms as ANSI; "
            "save the file as UTF-8 with BOM" % (name, state))
    # GBK files keep their ASCII brackets, so errors="replace" is safe here
    # (same approach as ms_check.py).
    return raw.decode("utf-8", errors="replace")


def check_ms_structure(path: str, text: str, report: Report) -> None:
    """Balanced ()/[] and terminated strings, via the ms_check lexer."""
    name = rel(path)
    code, lex_errors = ms_check.strip_code(text)
    for msg, line_no in lex_errors:
        report.failures.append("%s:%d: %s" % (name, line_no, msg))
    for problem in ms_check.check_structure(code, name):
        report.failures.append(problem)


# -------------------------------------------------------------- catalog audit
def load_catalog_modules() -> List[Tuple[str, List[Any]]]:
    """[(module name, its TOOLS list)] for every catalog module on disk."""
    import importlib
    out: List[Tuple[str, List[Any]]] = []
    for mod_name in MODULE_NAMES:
        module = importlib.import_module("maxmcp.catalog." + mod_name)
        out.append((mod_name, list(getattr(module, "TOOLS", []))))
    return out


def is_dangerous(entry: Any) -> bool:
    """Mutating tool whose name carries a destructive token (gate table rule)."""
    return bool(entry.mutating and (set(entry.name.split("_")) & DANGEROUS_NAME_TOKENS))


def _json_type_ok(value: Any, type_name: str) -> bool:
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "array":
        return isinstance(value, (list, tuple))
    if type_name == "object":
        return isinstance(value, dict)
    return False


def check_tool_description(entry: Any, where: str, report: Report) -> None:
    zh = (entry.description_zh or "").strip()
    en = (entry.description_en or "").strip()
    if not zh or not en:
        report.failures.append(
            "%s: missing bilingual description (zh=%r en=%r)" % (where, zh[:24], en[:24]))
        return
    if PLACEHOLDER_RE.search(zh) or PLACEHOLDER_RE.search(en):
        report.failures.append("%s: placeholder text in description (zh=%r)"
                               % (where, zh[:40]))
    if len(zh) < 8 or len(en) < 8:
        report.warnings.append("%s: description shorter than 8 characters" % where)
    if zh == en:
        report.warnings.append("%s: zh and en descriptions are identical" % where)
    if not CJK_RE.search(zh):
        report.warnings.append("%s: description_zh contains no Chinese" % where)
    if CJK_RE.search(en):
        report.warnings.append("%s: description_en contains Chinese" % where)


def check_tool_schema(entry: Any, where: str, report: Report) -> None:
    schema = entry.schema or {}
    if schema.get("type") != "object":
        report.failures.append("%s: schema type must be 'object'" % where)
    props = schema.get("properties") or {}
    required = schema.get("required") or []
    for key in required:
        if key not in props:
            report.failures.append(
                "%s: required parameter '%s' is not declared in properties"
                % (where, key))
    for key, spec in props.items():
        if not isinstance(spec, dict):
            report.failures.append("%s: parameter '%s' is not an object" % (where, key))
            continue
        type_name = spec.get("type")
        if type_name is None:
            report.failures.append("%s: parameter '%s' has no type" % (where, key))
            continue
        if type_name not in JSON_TYPES:
            report.failures.append(
                "%s: parameter '%s' has unknown type '%s' (typo?)"
                % (where, key, type_name))
            continue
        if spec.get("default") is not None and not _json_type_ok(spec["default"], type_name):
            report.failures.append(
                "%s: parameter '%s' default %r does not match type '%s'"
                % (where, key, spec["default"], type_name))
        enum = spec.get("enum")
        if enum is not None:
            if len(enum) == 0:
                report.warnings.append("%s: parameter '%s' has an empty enum"
                                       % (where, key))
            elif type_name in ("string", "number", "integer", "boolean"):
                bad = [v for v in enum if not _json_type_ok(v, type_name)]
                if bad:
                    report.failures.append(
                        "%s: parameter '%s' enum value(s) %r do not match type '%s'"
                        % (where, key, bad[:3], type_name))
        if "minimum" in spec or "maximum" in spec:
            if type_name not in ("number", "integer"):
                report.failures.append(
                    "%s: parameter '%s' uses minimum/maximum on a non-numeric type"
                    % (where, key))
            elif (spec.get("minimum") is not None and spec.get("maximum") is not None
                  and spec["minimum"] > spec["maximum"]):
                report.failures.append(
                    "%s: parameter '%s' has minimum > maximum" % (where, key))
        if "items" in spec and type_name != "array":
            report.warnings.append(
                "%s: parameter '%s' declares items on a non-array type"
                % (where, key))
        if type_name == "array" and "items" not in spec:
            report.warnings.append(
                "%s: parameter '%s' is an array without items" % (where, key))
        if not spec.get("description"):
            report.warnings.append(
                "%s: parameter '%s' has no bilingual description" % (where, key))


def check_catalog(report: Report, modules: List[Tuple[str, List[Any]]]) -> None:
    seen: Dict[str, str] = {}
    total = 0
    for mod_name, tools in modules:
        for entry in tools:
            total += 1
            where = "%s: %s" % (mod_name, entry.name)
            if entry.name in seen:
                report.failures.append(
                    "duplicate tool name '%s' in %s and %s"
                    % (entry.name, seen[entry.name], mod_name))
            seen[entry.name] = mod_name
            if entry.category not in KNOWN_CATEGORIES:
                report.failures.append(
                    "%s: unknown category '%s' (expected one of: %s)"
                    % (where, entry.category, ", ".join(KNOWN_CATEGORIES)))
            check_tool_description(entry, where, report)
            check_tool_schema(entry, where, report)
    report.stats["catalog_tools"] = total
    report.stats["catalog_modules"] = len(modules)


# ---------------------------------------------------------------------- driver
def run_checks(quiet: bool = False) -> Report:
    """Run every offline check.  Raises HarnessError when the tree is broken."""
    report = Report()

    def say(text: str = "") -> None:
        if not quiet:
            print(text)

    def group(title: str) -> Tuple[int, int]:
        say("\n%s" % title)
        return len(report.failures), len(report.warnings)

    def done(label: str, mark: Tuple[int, int]) -> None:
        fails = len(report.failures) - mark[0]
        warns = len(report.warnings) - mark[1]
        state = "ok" if fails == 0 else "%d VIOLATION(S)" % fails
        if warns:
            state += ", %d warning(s)" % warns
        say("  %-26s %s" % (label, state))

    lint_files = iter_py_files(PY_LINT_DIRS)
    scan_files = iter_py_files(PY_SCAN_DIRS)
    ms_files = iter_ms_files(MS_DIRS)
    report.stats["python_files"] = len(scan_files)
    report.stats["maxscript_files"] = len(ms_files)

    say("=== offline lint helper (seventh gate, no 3ds Max required) ===")
    say("python sources    : %d file(s) (src/python, scripts, test, examples)"
        % len(scan_files))
    say("maxscript sources : %d file(s) (src/ms, examples/maxscript, test)"
        % len(ms_files))

    mark = group("1. python syntax / encoding / BOM")
    trees: Dict[str, ast.AST] = {}
    for path in scan_files:
        tree = check_python_syntax(path, report)
        if tree is not None:
            trees[path] = tree
    done("syntax + encoding", mark)

    mark = group("2. python name resolution")
    for path, tree in trees.items():
        check_undefined_names(path, tree, report)
    done("undefined names", mark)

    mark = group("3. unused imports (warning only)")
    for path, tree in trees.items():
        check_unused_imports(path, tree, report)
    done("unused imports", mark)

    mark = group("4. hardcoded paths in code")
    for path in lint_files:
        tree = trees.get(path)
        if tree is not None:
            check_hardcoded_paths(path, tree, report)
    done("system / env / home paths", mark)

    mark = group("5. maxscript encoding")
    ms_texts: List[Tuple[str, str]] = []
    for path in ms_files:
        ms_texts.append((rel(path), check_ms_encoding(path, report)))
    done("ansi / bom rule", mark)

    mark = group("6. maxscript structure")
    for name, text in ms_texts:
        check_ms_structure(name, text, report)
    done("brackets / strings", mark)

    mark = group("7. catalog tool definitions")
    try:
        modules = load_catalog_modules()
    except Exception as exc:  # ImportError, ValueError, ...
        raise HarnessError("the catalog no longer imports: %r" % exc)
    check_catalog(report, modules)
    done("descriptions / types / defaults", mark)

    say("")
    if report.warnings:
        say("%d warning(s):" % len(report.warnings))
        for warning in report.warnings:
            say("  ! %s" % warning)
    if report.failures:
        say("")
        say("%d violation(s):" % len(report.failures))
        for failure in report.failures:
            say("  x %s" % failure)
        say("")
        say("offline lint: FAILED")
    else:
        say("offline lint: clean (%d warning(s))" % len(report.warnings))
    return report


def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(
        description="Offline static analysis for the 3dsmax-mcp repository.")
    parser.add_argument("--json", action="store_true",
                        help="emit a machine-readable report")
    args = parser.parse_args(argv)
    try:
        report = run_checks(quiet=args.json)
    except HarnessError as exc:
        print("harness error: %s" % exc)
        return 2
    if args.json:
        print(json.dumps({
            "clean": report.clean,
            "violations": report.failures,
            "warnings": report.warnings,
            "stats": report.stats,
        }, ensure_ascii=False, indent=2))
    return 0 if report.clean else 1


if __name__ == "__main__":
    raise SystemExit(main())
