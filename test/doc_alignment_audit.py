"""Offline documentation-alignment audit (no 3ds Max required).

Why this exists
---------------
The tool catalog, the MAXScript registry and the Markdown docs are all
maintained by hand, so a rename or a new tool leaves the prose one step
behind: the README still promises the old tool total, the listener banner
example shows a stale command count, ``docs/tools.txt`` misses the newest
names.  None of the existing gates reads the docs, so the drift survives
until a user trips over it.  This audit closes that gap offline: every
published statistic is recomputed from the code and compared with what the
docs claim.  It never starts Max, never touches the registry and never
opens a socket.

Ground truth (always computed from the code, never read from a doc):
  * tool total and per-category counts   -- src/python/maxmcp/catalog
  * per-profile tool counts              -- catalog schema PROFILES
  * registered command total             -- src/ms mcpRegister (parsing
                                            reused from registration_sync_test)
  * MAXScript module totals              -- src/ms files + the loader list
                                            inside mcp_bridge.ms
  * longest tool name                    -- catalog
  * numbered prompt sections             -- examples/prompts.md

Claims audited:
  * README.md -- "N 个工具" / "N tools", "分 N 类", the per-category
    breakdown inside the doctor example, "N 个 MAXScript 模块" /
    "N bridge modules" / "加载 N 个模块", the banner "Commands : N", the
    doctor "handlers=N", "最长的工具名是 N 字符", "N 条 ... 提示词", the
    工具一览 category table and the 工具档位 profile table
  * examples/maxscript/listener_cheatsheet.ms -- the "(N)" that follows
    mcpRegistry.count
  * docs/tools.txt -- every entry resolves to a catalog tool carrying the
    same category, with no extras and no omissions

Deliberately NOT audited:
  * CHANGELOG.md and docs/DELIVERY_* / docs/PLAN_* -- point-in-time records;
    their numbers were true when written
  * the self-test "13 项自检" claim -- mcp_selftest.ms emits one result line
    per mcpStPush call (14) but groups them into 13 numbered checks, so
    neither count is wrong and any automatic rule would be arbitrary
  * mock fixture values in scripts/test_e2e.py / test/mock_bridge.py --
    stand-in data, not published documentation

Usage:
    python test/doc_alignment_audit.py       # full audit
Exit code 0 when every claim aligns, 1 on drift, 2 on harness errors.
"""

from __future__ import annotations

import os
import re
import sys
from typing import Dict, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "src", "python"))
sys.path.insert(0, HERE)  # registration_sync_test lives next to this file

# Reuse the MAXScript registry parsing instead of writing a second copy.
import registration_sync_test as sync_test  # noqa: E402

from maxmcp.catalog import build_catalog  # noqa: E402
from maxmcp.catalog.schema import PROFILES  # noqa: E402

README = os.path.join(REPO, "README.md")
TOOLS_TXT = os.path.join(REPO, "docs", "tools.txt")
CHEATSHEET = os.path.join(REPO, "examples", "maxscript", "listener_cheatsheet.ms")
PROMPTS_MD = os.path.join(REPO, "examples", "prompts.md")
MS_DIR = os.path.join(REPO, "src", "ms")
BRIDGE_MS = os.path.join(MS_DIR, "mcp_bridge.ms")

PROMPT_HEAD_RE = re.compile(r"^## \d+\.", re.M)

# Scalar claims: (pattern, Facts attribute, human description).
README_PATTERNS = (
    (re.compile(r"(\d+)\s*个工具"), "tools", "tool total"),
    (re.compile(r"(\d+)\s*tools"), "tools", "tool total"),
    (re.compile(r"分\s*(\d+)\s*类"), "category_count", "category count"),
    (re.compile(r"(\d+)\s*个 MAXScript 模块"), "modules", "MAXScript module count"),
    (re.compile(r"(\d+)\s*bridge modules"), "modules", "MAXScript module count"),
    (re.compile(r"加载\s*(\d+)\s*个模块"), "modules_loaded", "loaded-module count"),
    (re.compile(r"Commands\s*:\s*(\d+)"), "commands", "registered-command count"),
    (re.compile(r"handlers=(\d+)"), "commands", "registered-command count"),
    (re.compile(r"最长的工具名是\s*(\d+)\s*字符"), "longest_name", "longest tool name"),
    (re.compile(r"(\d+)\s*条可直接"), "prompts", "prompt count"),
)

# "384 tools (animation=59, files=8, ...)" -- the doctor.py example output.
BREAKDOWN_RE = re.compile(r"\d+\s+tools\s*\(([^)]*)\)")
PAIR_RE = re.compile(r"([a-z]+)=(\d+)")

# Table rows: | `system` | 33 | ...   (the profile table bolds its numbers).
ROW_RE = re.compile(r"^\|\s*`([a-z]+)`\s*\|\s*\*{0,2}(\d+)\*{0,2}\s*\|")
SEPARATOR_RE = re.compile(r"^\|[\s:-]+\|")

# docs/tools.txt entries: "bridge_status                [system]".
ENTRY_RE = re.compile(r"^([a-z0-9_]+)\s+\[([a-z]+)\]$")

# The cheatsheet comment "mcpRegistry.count  -- ... (346)".
REGISTRY_COUNT_RE = re.compile(r"mcpRegistry\.count[^\n(]*\((\d+)\)")


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def rel(path: str) -> str:
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def line_of(text: str, pos: int) -> int:
    return text[:pos].count("\n") + 1


class Facts:
    """Every published statistic, recomputed from the code."""

    def __init__(self) -> None:
        catalog = build_catalog()
        tools = list(catalog)
        self.tools = len(tools)
        self.categories: Dict[str, int] = catalog.categories()
        self.category_count = len(self.categories)
        self.profiles: Dict[str, int] = {
            name: sum(catalog.profile_summary(name).values()) for name in PROFILES
        }
        self.commands = len(sync_test.registered_commands(MS_DIR))
        self.modules = len(sync_test.ms_files(MS_DIR))
        with open(BRIDGE_MS, "r", encoding="utf-8", errors="replace") as fh:
            self.modules_loaded = len(set(sync_test.LOADER_RE.findall(fh.read())))
        self.longest_name = max(len(entry.name) for entry in tools)
        self.prompts = len(PROMPT_HEAD_RE.findall(read(PROMPTS_MD)))


def check_scalar_claims(label: str, text: str, patterns, facts: Facts,
                        problems: List[str]) -> int:
    """Every match of every pattern must state the value the code computes."""
    checked = 0
    for pattern, attr, what in patterns:
        for match in pattern.finditer(text):
            checked += 1
            claimed = int(match.group(1))
            actual = getattr(facts, attr)
            if claimed != actual:
                problems.append(
                    "{0}:{1}: {2} claims {3}, the code says {4}".format(
                        label, line_of(text, match.start()), what, claimed, actual
                    )
                )
    return checked


def check_breakdown(label: str, text: str, facts: Facts,
                    problems: List[str]) -> int:
    """The "(animation=59, files=8, ...)" tail of the doctor example."""
    checked = 0
    for match in BREAKDOWN_RE.finditer(text):
        for name, claimed in PAIR_RE.findall(match.group(1)):
            checked += 1
            actual = facts.categories.get(name)
            if actual is None:
                problems.append(
                    "{0}:{1}: unknown category '{2}' in the tools breakdown".format(
                        label, line_of(text, match.start()), name
                    )
                )
            elif int(claimed) != actual:
                problems.append(
                    "{0}:{1}: breakdown claims {2}={3}, the code says {4}".format(
                        label, line_of(text, match.start()), name, claimed, actual
                    )
                )
    return checked


def check_table(label: str, text: str, header: str, expected: Dict[str, int],
                problems: List[str]) -> int:
    """A two-column markdown table introduced by ``header``."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if header in line:
            start = index + 1
            break
    if start is None:
        problems.append("{0}: table introduced by '{1}' not found".format(label, header))
        return 0
    checked = 0
    seen: List[str] = []
    for line in lines[start:]:
        if SEPARATOR_RE.match(line):
            continue
        match = ROW_RE.match(line)
        if not match:
            break
        checked += 1
        name, claimed = match.group(1), int(match.group(2))
        seen.append(name)
        actual = expected.get(name)
        if actual is None:
            problems.append(
                "{0}: table row '{1}' does not exist in the code".format(label, name)
            )
        elif claimed != actual:
            problems.append(
                "{0}: table row '{1}' claims {2}, the code says {3}".format(
                    label, name, claimed, actual
                )
            )
    missing = [name for name in expected if name not in seen]
    if missing:
        problems.append(
            "{0}: table is missing row(s): {1}".format(label, ", ".join(missing))
        )
    return checked


def check_tools_txt(facts: Facts, problems: List[str]) -> List[str]:
    """docs/tools.txt must be the catalog's name list, one entry per line."""
    lines = read(TOOLS_TXT).splitlines()
    entries: List[Tuple[str, str]] = []
    for index, line in enumerate(lines, 1):
        match = ENTRY_RE.match(line)
        if not match:
            problems.append(
                "docs/tools.txt:{0}: unrecognized line: {1!r}".format(index, line[:60])
            )
            continue
        entries.append((match.group(1), match.group(2)))

    names = [name for name, _ in entries]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        problems.append(
            "docs/tools.txt: duplicate entries: {0}".format(", ".join(duplicates[:10]))
        )

    catalog = build_catalog()
    listed = set(names)
    actual = set(catalog.names())
    extra = sorted(listed - actual)
    missing = sorted(actual - listed)
    if extra:
        problems.append(
            "docs/tools.txt lists tool(s) absent from the catalog: {0}".format(
                ", ".join(extra[:20])
            )
        )
    if missing:
        problems.append(
            "docs/tools.txt misses catalog tool(s): {0}".format(", ".join(missing[:20]))
        )

    for name, category in entries:
        entry = catalog.get(name)
        if entry is not None and entry.category != category:
            problems.append(
                "docs/tools.txt: {0} tagged [{1}], the catalog says [{2}]".format(
                    name, category, entry.category
                )
            )

    report = ["docs/tools.txt: {0} entries, every name resolves to the catalog".format(
        len(entries))]
    if len(names) != facts.tools:
        report.append("  ! {0} entries but the catalog holds {1} tools".format(
            len(names), facts.tools))
    return report


def audit() -> Tuple[List[str], List[str]]:
    """Run every check.

    Returns ``(problems, report)``; ``problems`` is empty when the docs and
    the code agree.
    """
    facts = Facts()
    problems: List[str] = []
    report: List[str] = ["=== doc alignment audit ===",
                         "ground truth (recomputed from the code)"]
    report.append("  catalog tools        : {0} in {1} categories".format(
        facts.tools, facts.category_count))
    report.append("  profile tool counts  : {0}".format(
        " ".join("{0}={1}".format(name, count)
                 for name, count in sorted(facts.profiles.items()))))
    report.append("  registered commands  : {0}".format(facts.commands))
    report.append("  MAXScript modules    : {0} files ({1} in the mcp_bridge.ms loader)".format(
        facts.modules, facts.modules_loaded))
    report.append("  longest tool name    : {0} characters".format(facts.longest_name))
    report.append("  prompt sections      : {0}".format(facts.prompts))

    readme = read(README)
    checked = check_scalar_claims(rel(README), readme, README_PATTERNS, facts, problems)
    checked += check_breakdown(rel(README), readme, facts, problems)
    rows = check_table(rel(README), readme, "| 分类 | 数量 |", facts.categories, problems)
    rows += check_table(rel(README), readme, "| 档位 | 工具数 |", facts.profiles, problems)
    report.append("")
    report.append("README.md: {0} scalar claims, {1} table rows checked".format(checked, rows))

    cheatsheet = read(CHEATSHEET)
    checked = check_scalar_claims(
        rel(CHEATSHEET), cheatsheet,
        ((REGISTRY_COUNT_RE, "commands", "registered-command count"),), facts, problems)
    report.append("{0}: {1} scalar claim checked".format(rel(CHEATSHEET), checked))

    report.extend(check_tools_txt(facts, problems))
    return problems, report


def main() -> int:
    try:
        problems, report = audit()
    except Exception as exc:  # unreadable repo, broken catalog: harness error
        print("doc alignment audit could not run: {0}".format(exc))
        return 2
    for line in report:
        print(line)
    if problems:
        print("\n{0} alignment problem(s):".format(len(problems)))
        for problem in problems:
            print("  x {0}".format(problem))
        return 1
    print("\ndocs and code are aligned")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
