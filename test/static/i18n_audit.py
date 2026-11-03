"""Audit both message tables for keys that are used but not declared.

Two independent i18n layers have the same failure mode: a missing key is not an
error, it is the key itself shown to the user.

* Python - ``i18n.t("tool.unknown")`` returns the literal ``"tool.unknown"``;
* MAXScript - ``mcpMsg "msg.ok"`` returns ``"msg.ok"``.

So a typo or a forgotten entry does not crash anything, it just leaks a
machine identifier into a message a person reads.  This audit reads the call
sites and the tables and requires every key to exist.

Declared-but-unused keys are only reported: a message can be reached through a
variable key (``mcpMsg (mcpObjL ...)``) or reserved for a future handler, and
deleting it would be guessing.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.i18n import MESSAGES  # noqa: E402

PY_CALL = re.compile(r'i18n\.t\(\s*"([\w.]+)"')
#: mcpFail is the other consumer of the same table: its first argument is a key.
MS_CALL = re.compile(r'mcp(?:Msg|Fail)\s+"([\w.]+)"')
#: ``#("key", #("zh text", "en text"))`` entries in the MAXScript table.
MS_ENTRY = re.compile(r'#\(\s*"([\w.]+)"\s*,\s*#\(', re.I)


def _python_calls() -> dict:
    used = {}
    for path in sorted((ROOT / "src" / "python" / "maxmcp").rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        for key in PY_CALL.findall(text):
            used.setdefault(key, set()).add(path.name)
    return used


def _maxscript_table() -> set:
    core = (ROOT / "src" / "ms" / "mcp_core.ms").read_text(encoding="utf-8-sig")
    start = core.index("mcpMessages = #(")
    end = core.index("\n)\n", start)
    return set(MS_ENTRY.findall(core[start:end]))


def _maxscript_calls() -> dict:
    used = {}
    for path in sorted((ROOT / "src" / "ms").glob("*.ms")):
        text = path.read_text(encoding="utf-8-sig")
        for key in MS_CALL.findall(text):
            used.setdefault(key, set()).add(path.name)
    return used


def main() -> None:
    py_used = _python_calls()
    py_missing = sorted(k for k in py_used if k not in MESSAGES)
    py_unused = sorted(k for k in MESSAGES if k not in py_used)

    ms_table = _maxscript_table()
    ms_used = _maxscript_calls()
    ms_missing = sorted(k for k in ms_used if k not in ms_table)
    ms_unused = sorted(k for k in ms_table if k not in ms_used)

    print("i18n audit: python used=%d declared=%d missing=%d unused=%d" % (
        len(py_used), len(MESSAGES), len(py_missing), len(py_unused)))
    print("i18n audit: maxscript used=%d declared=%d missing=%d unused=%d" % (
        len(ms_used), len(ms_table), len(ms_missing), len(ms_unused)))
    for key in py_missing:
        print("  python  missing %-26s %s" % (key, sorted(py_used[key])))
    for key in ms_missing:
        print("  maxscript missing %-22s %s" % (key, sorted(ms_used[key])))
    if py_unused:
        print("  python declared-but-unused: " + ", ".join(py_unused))
    if ms_unused:
        print("  maxscript declared-but-unused: " + ", ".join(ms_unused))

    assert not py_missing, (
        "i18n.t() with an undeclared key shows the key to the user: " + ", ".join(py_missing))
    assert not ms_missing, (
        "mcpMsg with an undeclared key shows the key to the user: " + ", ".join(ms_missing))


if __name__ == "__main__":
    main()
