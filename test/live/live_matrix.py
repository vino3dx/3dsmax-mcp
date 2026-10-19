#!/usr/bin/env python3
"""Live verification matrix for the 3ds Max MCP bridge (P1 / T4).

The point of this runner: "it works on a real 3ds Max" becomes a
machine-recordable fact instead of a sentence in a chat log.  For every tool
it tracks one of four states:

    未验证      no case written yet
    实机通过    every case passed, including its read-back assertions
    实机失败    a case failed (tool error, step error or assertion mismatch)
    不适用      skipped by policy (dangerous tool, case marked not applicable)

A case is a minimal payload plus read-back steps: after the tool call the
runner queries the real scene state through the bridge and asserts on the
answer.  A bare ``ok: true`` is never accepted as proof.  The scene is reset
(scene_new -> resetMaxFile #noPrompt) before and after every case, and an
empty-scene gate aborts the run when the scene cannot be verified empty.

Case files live in test/live/live_cases/*.json (list of case objects).  Payloads
are merged over the catalog preset exactly like the MCP server does
(server.py _build_payload): declared keys override the preset, unknown keys
are ignored, required keys must be present.

Usage:
    python test/live_matrix.py --list                    # inventory, no Max
    python test/live_matrix.py --list --write-doc docs/LIVE_MATRIX.md
    python test/live_matrix.py --port 8765               # live run
    python test/live_matrix.py --port 8765 --json        # machine report
    python test/live_matrix.py --port 8765 --only objects,modeling
    python test/live_matrix.py --self-test --port 8796   # runner logic vs mock

Exit codes: 0 all pass, 1 failures, 2 usage/harness error, 3 empty-scene gate.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
for _extra in (str(REPO / "src" / "python"), str(HERE)):
    if _extra not in sys.path:
        sys.path.insert(0, _extra)

from maxmcp.catalog import Tool, build_catalog  # noqa: E402
import offline_lint_helper  # noqa: E402  -- dangerous-token rule, shared with gate 7

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_GATE = 3

STATUS_UNVERIFIED = "unverified"      # 未验证
STATUS_PASS = "live-pass"             # 实机通过
STATUS_FAIL = "live-fail"             # 实机失败
STATUS_NA = "not-applicable"          # 不适用

STATUS_LABEL = {
    STATUS_UNVERIFIED: "未验证",
    STATUS_PASS: "实机通过",
    STATUS_FAIL: "实机失败",
    STATUS_NA: "不适用",
}

RESET_METHOD = "scene_new"


class BridgeError(RuntimeError):
    pass


class BridgeClient:
    """Minimal newline-delimited JSON client for the in-Max bridge."""

    def __init__(self, host: str, port: int, timeout: float = 30.0) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: Optional[socket.socket] = None
        self._counter = 0

    def connect(self) -> None:
        try:
            self._sock = socket.create_connection((self.host, self.port),
                                                  timeout=self.timeout)
        except OSError as exc:
            raise BridgeError("cannot connect to {0}:{1}: {2}".format(
                self.host, self.port, exc))
        self._sock.settimeout(self.timeout)

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        if self._sock is None:
            raise BridgeError("not connected")
        self._counter += 1
        line = json.dumps({"id": self._counter, "method": method,
                           "params": params or {}},
                          ensure_ascii=True, separators=(",", ":")) + "\n"
        try:
            self._sock.sendall(line.encode("ascii"))
            buf = b""
            while b"\n" not in buf:
                chunk = self._sock.recv(65536)
                if not chunk:
                    raise BridgeError("bridge closed the connection")
                buf += chunk
            data = json.loads(buf.split(b"\n", 1)[0].decode("ascii", "replace"))
        except (OSError, ValueError) as exc:
            self.close()
            raise BridgeError("{0}: {1}".format(method, exc))
        if data.get("ok"):
            return data.get("result")
        err = data.get("error")
        if isinstance(err, str):
            err = {"message": err}
        raise BridgeError("{0} failed: {1}".format(
            method, (err or {}).get("message", "unknown error")))


# ------------------------------------------------------------------ assertions
def resolve_path(value: Any, path: str) -> Tuple[bool, Any]:
    """Walk a dotted path (dict keys / list indices).  (found, value)."""
    current = value
    for part in path.split("."):
        if isinstance(current, dict):
            if part not in current:
                return False, None
            current = current[part]
        elif isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError):
                return False, None
        else:
            return False, None
    return True, current


def values_match(actual: Any, expected: Any) -> bool:
    """Equality with numeric tolerance (255 == 255.0) and list/dict recursion."""
    if isinstance(actual, bool) or isinstance(expected, bool):
        return actual is expected if isinstance(expected, bool) else actual == expected
    if isinstance(actual, (int, float)) and isinstance(expected, (int, float)):
        return abs(float(actual) - float(expected)) <= 1e-6
    if isinstance(actual, list) and isinstance(expected, list):
        return (len(actual) == len(expected)
                and all(values_match(a, b) for a, b in zip(actual, expected)))
    if isinstance(actual, dict) and isinstance(expected, dict):
        return (set(actual) == set(expected)
                and all(values_match(actual[k], expected[k]) for k in expected))
    return actual == expected


def check_expectations(result: Any, step: Dict[str, Any]) -> List[str]:
    """Evaluate one read-back step; returns a list of failure messages."""
    problems: List[str] = []
    for path, expected in (step.get("expect") or {}).items():
        found, actual = resolve_path(result, path)
        if not found:
            problems.append("{0}: path '{1}' not found in result".format(
                step.get("method"), path))
        elif not values_match(actual, expected):
            problems.append("{0}: '{1}' = {2!r}, want {3!r}".format(
                step.get("method"), path, actual, expected))
    for path, expected in (step.get("expect_gte") or {}).items():
        found, actual = resolve_path(result, path)
        if not found:
            problems.append("{0}: path '{1}' not found in result".format(
                step.get("method"), path))
        elif not (isinstance(actual, (int, float)) and float(actual) >= float(expected)):
            problems.append("{0}: '{1}' = {2!r}, want >= {3!r}".format(
                step.get("method"), path, actual, expected))
    for path, expected in (step.get("expect_gt") or {}).items():
        found, actual = resolve_path(result, path)
        if not found:
            problems.append("{0}: path '{1}' not found in result".format(
                step.get("method"), path))
        elif not (isinstance(actual, (int, float)) and float(actual) > float(expected)):
            problems.append("{0}: '{1}' = {2!r}, want > {3!r}".format(
                step.get("method"), path, actual, expected))
    return problems


# ----------------------------------------------------------------------- cases
def load_cases(cases_dir: Path) -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []
    if not cases_dir.is_dir():
        return cases
    for path in sorted(cases_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise SystemExit("case file {0} is not valid JSON: {1}".format(path, exc))
        if isinstance(data, dict):
            data = [data]
        for entry in data:
            entry["_file"] = path.name
            cases.append(entry)
    return cases


def build_payload(tool: Tool, arguments: Dict[str, Any]) -> Tuple[Dict[str, Any], List[str]]:
    """Mirror server.py _build_payload: preset + declared overrides + required."""
    properties = tool.schema.get("properties") or {}
    payload: Dict[str, Any] = dict(tool.preset)
    for key, value in (arguments or {}).items():
        if key in properties:
            payload[key] = value
    missing = [r for r in (tool.schema.get("required") or [])
               if payload.get(r) is None]
    return payload, missing


# ---------------------------------------------------------------------- runner
def reset_scene(client: BridgeClient) -> Optional[str]:
    try:
        client.call(RESET_METHOD, {})
        return None
    except BridgeError as exc:
        return str(exc)


def run_case(client: BridgeClient, tool: Tool, case: Dict[str, Any],
             verbose: bool = False) -> Dict[str, Any]:
    """Run one case; returns a result record (never raises)."""
    record: Dict[str, Any] = {"tool": tool.name, "title": case.get("title", ""),
                              "file": case.get("_file", "")}
    err = reset_scene(client)
    if err:
        record.update({"status": STATUS_FAIL, "problems": ["reset failed: " + err]})
        return record
    for index, step in enumerate(case.get("steps") or [], 1):
        try:
            client.call(step["method"], step.get("payload") or {})
        except (BridgeError, KeyError) as exc:
            record.update({"status": STATUS_FAIL,
                           "problems": ["step {0} ({1}) failed: {2}".format(
                               index, step.get("method"), exc)]})
            reset_scene(client)
            return record
    payload, missing = build_payload(tool, case.get("payload") or {})
    if missing:
        record.update({"status": STATUS_FAIL,
                       "problems": ["case authoring: missing required {0}".format(missing)]})
        reset_scene(client)
        return record
    tool_error: Optional[str] = None
    try:
        client.call(tool.bridge_method, payload)
    except BridgeError as exc:
        tool_error = str(exc)
    if case.get("expect_error"):
        if tool_error is None:
            record.update({"status": STATUS_FAIL,
                           "problems": ["expected the tool to fail, but it succeeded"]})
        else:
            record.update({"status": STATUS_PASS, "expected_error": tool_error[:200]})
        reset_scene(client)
        return record
    if tool_error is not None:
        record.update({"status": STATUS_FAIL, "problems": ["tool call failed: " + tool_error]})
        reset_scene(client)
        return record
    problems: List[str] = []
    for step in case.get("readback") or []:
        try:
            result = client.call(step["method"], step.get("payload") or {})
        except BridgeError as exc:
            problems.append("readback {0} failed: {1}".format(step.get("method"), exc))
            continue
        problems.extend(check_expectations(result, step))
    reset_scene(client)
    record.update({"status": STATUS_FAIL if problems else STATUS_PASS,
                   "problems": problems})
    if verbose:
        print("  {0:<28} {1:<10} {2}".format(
            tool.name, STATUS_LABEL[record["status"]],
            "; ".join(problems[:2]) if problems else case.get("title", "")))
    return record


def empty_scene_gate(client: BridgeClient) -> Tuple[str, Any]:
    """('ok'|'not_empty'|'unverifiable', detail)."""
    try:
        info = client.call("scene_info", {})
    except BridgeError as exc:
        return "unverifiable", str(exc)
    count = info.get("objectCount") if isinstance(info, dict) else None
    if count is None:
        return "unverifiable", "scene_info has no objectCount"
    if count != 0:
        return "not_empty", count
    return "ok", count


def select_cases(cases: List[Dict[str, Any]], catalog, only: List[str],
                 skip_dangerous: bool) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """(runnable cases, skipped-by-policy cases with reason)."""
    runnable: List[Dict[str, Any]] = []
    skipped: List[Dict[str, Any]] = []
    for case in cases:
        tool = catalog.get(case.get("tool", ""))
        if tool is None:
            skipped.append({"case": case, "tool": case.get("tool", "?"),
                            "reason": "unknown tool name"})
            continue
        if only and tool.category not in only:
            continue
        if case.get("not_applicable"):
            skipped.append({"case": case, "tool": tool.name,
                            "reason": case.get("not_applicable")})
            continue
        if skip_dangerous and offline_lint_helper.is_dangerous(tool):
            skipped.append({"case": case, "tool": tool.name,
                            "reason": "dangerous tool (delete/remove/clear/...), "
                                      "skipped by default"})
            continue
        runnable.append(case)
    return runnable, skipped


def tool_statuses(catalog, cases: List[Dict[str, Any]],
                  results: List[Dict[str, Any]],
                  skipped: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Per-tool status map across the whole catalog."""
    by_tool: Dict[str, List[Dict[str, Any]]] = {}
    for case in cases:
        by_tool.setdefault(case.get("tool", "?"), []).append(case)
    results_by_tool: Dict[str, List[Dict[str, Any]]] = {}
    for record in results:
        results_by_tool.setdefault(record["tool"], []).append(record)
    skipped_tools = {entry["tool"] for entry in skipped}
    out: Dict[str, Dict[str, Any]] = {}
    for tool in catalog:
        entry: Dict[str, Any] = {"category": tool.category, "cases": len(by_tool.get(tool.name, [])),
                                 "status": STATUS_UNVERIFIED, "reason": ""}
        if tool.name in skipped_tools and not by_tool.get(tool.name):
            entry["status"] = STATUS_NA
            entry["reason"] = "no case written"
        elif tool.name in results_by_tool:
            records = results_by_tool[tool.name]
            failed = [r for r in records if r["status"] == STATUS_FAIL]
            entry["status"] = STATUS_FAIL if failed else STATUS_PASS
            entry["case_results"] = [
                {"title": r.get("title"), "status": r["status"],
                 "problems": r.get("problems", [])[:3]} for r in records]
            if failed:
                entry["reason"] = failed[0].get("problems", [""])[0][:160]
        elif tool.name in skipped_tools:
            entry["status"] = STATUS_NA
            entry["reason"] = next((e["reason"] for e in skipped
                                    if e["tool"] == tool.name), "")
        out[tool.name] = entry
    return out


def category_stats(catalog, statuses: Dict[str, Dict[str, Any]]) -> Dict[str, Dict[str, int]]:
    stats: Dict[str, Dict[str, int]] = {}
    for tool in catalog:
        row = stats.setdefault(tool.category, {"total": 0, "cases": 0, "pass": 0,
                                               "fail": 0, "na": 0, "unverified": 0})
        row["total"] += 1
        row["cases"] += statuses[tool.name]["cases"]
        status = statuses[tool.name]["status"]
        row[{"live-pass": "pass", "live-fail": "fail",
             "not-applicable": "na", "unverified": "unverified"}[status]] += 1
    return stats


# ------------------------------------------------------------------ doc output
def write_doc(path: Path, statuses: Dict[str, Dict[str, Any]],
              stats: Dict[str, Dict[str, int]], live: bool, meta: str) -> None:
    lines: List[str] = []
    lines.append("# Live Verification Matrix (P1)")
    lines.append("")
    lines.append("Machine-recorded status of every catalog tool against a real "
                 "3ds Max bridge. Generated by `test/live_matrix.py`; do not "
                 "hand-edit - regenerate instead.")
    lines.append("")
    lines.append("- generated: {0}".format(meta))
    lines.append("- mode: {0}".format("live run against 3ds Max" if live
                                      else "offline snapshot (no 3ds Max contacted)"))
    lines.append("- statuses: 未验证 (no case) / 实机通过 / 实机失败 / 不适用 "
                 "(dangerous or marked not applicable)")
    lines.append("- every case asserts on real scene state read back through the "
                 "bridge; a bare success flag is not proof")
    lines.append("")
    lines.append("## Coverage by category")
    lines.append("")
    lines.append("| category | tools | cases written | live pass | live fail | "
                 "not applicable | unverified |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for category in sorted(stats):
        row = stats[category]
        lines.append("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |".format(
            category, row["total"], row["cases"], row["pass"], row["fail"],
            row["na"], row["unverified"]))
    totals = {key: sum(row[key] for row in stats.values())
              for key in ("total", "cases", "pass", "fail", "na", "unverified")}
    lines.append("| **total** | **{0}** | **{1}** | **{2}** | **{3}** | **{4}** | "
                 "**{5}** |".format(totals["total"], totals["cases"], totals["pass"],
                                    totals["fail"], totals["na"], totals["unverified"]))
    lines.append("")
    lines.append("## Tools with cases")
    lines.append("")
    lines.append("| tool | category | cases | status | note |")
    lines.append("| --- | --- | --- | --- | --- |")
    for name in sorted(statuses):
        entry = statuses[name]
        if not entry["cases"]:
            continue
        note = entry.get("reason", "")
        lines.append("| {0} | {1} | {2} | {3} | {4} |".format(
            name, entry["category"], entry["cases"],
            STATUS_LABEL[entry["status"]], note.replace("|", "/")))
    lines.append("")
    lines.append("## Unverified tools (no case yet)")
    lines.append("")
    for category in sorted(stats):
        names = [n for n, e in statuses.items()
                 if e["category"] == category and e["status"] == STATUS_UNVERIFIED]
        if names:
            lines.append("- **{0}** ({1}): {2}".format(category, len(names),
                                                       ", ".join(sorted(names))))
    lines.append("")
    lines.append("## How to reproduce")
    lines.append("")
    lines.append("```")
    lines.append("python test/live_matrix.py --list                      # inventory, no Max")
    lines.append("python test/live_matrix.py --port 8765 --write-doc docs/LIVE_MATRIX.md")
    lines.append("python test/live_matrix.py --port 8765 --only objects,modeling")
    lines.append("python test/live_matrix.py --self-test --port 8796      # runner logic vs mock bridge")
    lines.append("```")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


# ------------------------------------------------------------------ self-test
SYNTHETIC_CASES: List[Dict[str, Any]] = [
    {"tool": "bridge_status", "title": "echo: bridge_status.running is true",
     "payload": {},
     "readback": [{"method": "bridge_status", "expect": {"running": True}}]},
    {"tool": "bridge_ping", "title": "echo: method name comes back",
     "payload": {},
     "readback": [{"method": "bridge_ping", "expect": {"method": "bridge_ping"}}]},
    {"tool": "bridge_status", "title": "mismatch must be reported as failure",
     "payload": {},
     "readback": [{"method": "bridge_status", "expect": {"running": False}}]},
    {"tool": "delete_objects", "title": "dangerous tool must be skipped",
     "payload": {}},
    {"tool": "create_box", "title": "other category for the --only filter",
     "payload": {}},
]


def self_test(client: BridgeClient, catalog) -> int:
    problems: List[str] = []

    # Phase A: without --assume-empty the gate must abort (the mock's
    # scene_info carries no objectCount, so emptiness is unverifiable).
    state, detail = empty_scene_gate(client)
    if state != "unverifiable":
        problems.append("phase A: gate returned {0} ({1!r}), want 'unverifiable' "
                        "against the mock bridge".format(state, detail))
    else:
        print("self-test phase A: empty-scene gate correctly refuses to run "
              "against an unverifiable scene")

    # Phase B: with --assume-empty the synthetic cases must classify correctly.
    runnable, skipped = select_cases(SYNTHETIC_CASES, catalog, [], True)
    results = [run_case(client, catalog.get(c["tool"]), c) for c in runnable]
    by_title = {r["title"]: r for r in results}
    want_pass = ["echo: bridge_status.running is true",
                 "echo: method name comes back"]
    for title in want_pass:
        record = by_title.get(title)
        if record is None or record["status"] != STATUS_PASS:
            problems.append("phase B: '{0}' should pass, got {1}".format(
                title, record and record["status"]))
    mismatch = by_title.get("mismatch must be reported as failure")
    if mismatch is None or mismatch["status"] != STATUS_FAIL:
        problems.append("phase B: assertion mismatch must be reported as 实机失败, "
                        "got {0}".format(mismatch and mismatch["status"]))
    else:
        print("self-test phase B: assertion mismatch correctly reported as 实机失败 "
              "({0})".format(mismatch["problems"][0][:80]))
    if not any(entry["tool"] == "delete_objects" for entry in skipped):
        problems.append("phase B: dangerous tool delete_objects must be skipped "
                        "under --skip-dangerous")
    else:
        print("self-test phase B: dangerous tool correctly skipped")

    # Phase C: --only must filter by category (create_box is 'objects').
    runnable_c, _ = select_cases(SYNTHETIC_CASES, catalog, ["system"], True)
    names = [c["tool"] for c in runnable_c]
    if "create_box" in names:
        problems.append("phase C: --only system must exclude the objects case")
    elif "bridge_status" not in names:
        problems.append("phase C: --only system dropped the system cases too")
    else:
        print("self-test phase C: --only filter works ({0})".format(names))

    if problems:
        print("\nSELF-TEST FAILED:")
        for problem in problems:
            print("  x {0}".format(problem))
        return EXIT_FAIL
    print("\nSELF-TEST PASSED: runner logic verified against the mock bridge")
    return EXIT_OK


# ----------------------------------------------------------------------- main
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Live verification matrix for the bridge.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--cases-dir", default=str(HERE / "live_cases"))
    parser.add_argument("--only", default="",
                        help="comma-separated categories to run")
    parser.add_argument("--include-dangerous", action="store_true",
                        help="also run dangerous tools (default: skip them)")
    parser.add_argument("--assume-empty", action="store_true",
                        help="skip the empty-scene gate (mock/self-test only)")
    parser.add_argument("--list", action="store_true",
                        help="inventory only, do not connect")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test", action="store_true",
                        help="verify the runner itself against a mock bridge")
    parser.add_argument("--write-doc", default="",
                        help="write the coverage matrix to this markdown file")
    args = parser.parse_args(argv)

    catalog = build_catalog()
    only = [c.strip() for c in args.only.split(",") if c.strip()]

    if args.self_test:
        cases = SYNTHETIC_CASES
    else:
        cases = load_cases(Path(args.cases_dir))
        if not cases:
            print("no cases found in {0}".format(args.cases_dir))
            return EXIT_USAGE

    if args.list:
        runnable, skipped = select_cases(cases, catalog, only,
                                         not args.include_dangerous)
        print("case inventory: {0} case(s) for {1} tool(s), {2} skipped".format(
            len(runnable), len({c["tool"] for c in runnable}), len(skipped)))
        for case in runnable:
            print("  {0:<28} {1}".format(case["tool"], case.get("title", "")))
        if args.write_doc:
            statuses = tool_statuses(catalog, cases, [], [])
            stats = category_stats(catalog, statuses)
            write_doc(Path(args.write_doc), statuses, stats, False,
                      time.strftime("%Y-%m-%d %H:%M:%S"))
            print("wrote {0}".format(args.write_doc))
        return EXIT_OK

    client = BridgeClient(args.host, args.port)
    try:
        client.connect()
    except BridgeError as exc:
        print("cannot reach the bridge: {0}".format(exc))
        print("start 3ds Max (bridge listens on {0}), or use --list / "
              "--self-test with a mock bridge".format(args.port))
        return EXIT_USAGE

    try:
        if args.self_test:
            return self_test(client, catalog)

        if not args.assume_empty:
            state, detail = empty_scene_gate(client)
            if state == "not_empty":
                print("empty-scene gate: scene holds {0} object(s); reset it "
                      "first (scene_new)".format(detail))
                return EXIT_GATE
            if state == "unverifiable":
                print("empty-scene gate: cannot verify the scene is empty "
                      "({0})".format(detail))
                return EXIT_GATE
            print("empty-scene gate: ok (objectCount=0)")

        runnable, skipped = select_cases(cases, catalog, only,
                                         not args.include_dangerous)
        print("running {0} case(s) ({1} skipped by policy)".format(
            len(runnable), len(skipped)))
        results = [run_case(client, catalog.get(c["tool"]), c, verbose=True)
                   for c in runnable]
        statuses = tool_statuses(catalog, cases, results, skipped)
        stats = category_stats(catalog, statuses)
        failures = [r for r in results if r["status"] == STATUS_FAIL]
        print("\n{0} case(s): {1} pass, {2} fail, {3} skipped".format(
            len(results), len(results) - len(failures), len(failures), len(skipped)))
        print("{0:<14} {1:>5} {2:>6} {3:>6} {4:>6} {5:>6} {6:>9}".format(
            "category", "tools", "cases", "pass", "fail", "na", "unverified"))
        for category in sorted(stats):
            row = stats[category]
            print("{0:<14} {1:>5} {2:>6} {3:>6} {4:>6} {5:>6} {6:>9}".format(
                category, row["total"], row["cases"], row["pass"], row["fail"],
                row["na"], row["unverified"]))
        if args.json:
            print(json.dumps({
                "port": args.port, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
                "cases": len(results), "pass": len(results) - len(failures),
                "fail": len(failures), "skipped": len(skipped),
                "categories": stats,
                "tools": {name: {"status": entry["status"],
                                 "category": entry["category"],
                                 "reason": entry.get("reason", "")}
                          for name, entry in statuses.items()},
                "failures": [{"tool": r["tool"], "title": r.get("title"),
                              "problems": r.get("problems", [])}
                             for r in failures],
            }, ensure_ascii=False, indent=2))
        if args.write_doc:
            write_doc(Path(args.write_doc), statuses, stats, True,
                      time.strftime("%Y-%m-%d %H:%M:%S"))
            print("wrote {0}".format(args.write_doc))
        return EXIT_FAIL if failures else EXIT_OK
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
