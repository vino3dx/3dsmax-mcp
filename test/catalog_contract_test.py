"""Python-layer contract test for the tool catalog (the sixth static gate).

Why this exists
---------------
``test/modeling_ext_test.py`` talks straight to the MAXScript bridge on port
8765, so it never exercises the Python MCP server: required-parameter
validation, preset merging, type coercion and the ``collapse_stack`` ->
``mod_collapse`` alias were therefore untested.  This module closes that gap
with a MockBridge: the real ``maxmcp`` server process is driven over stdio
exactly like an MCP client would, while a tiny TCP stand-in records every
bridge request.  No 3ds Max instance, no port 8765, no external network.

What it checks
--------------
A. static contract, tool by tool (all tools in the catalog):
   1. unique names; name prefix consistent with the category
      (whitelisted exceptions carry a written reason)
   2. bilingual descriptions present and not placeholders
   3. schema legality: type whitelist, required subset of properties, enum
      and default types match, minimum <= maximum
   4. preset keys limited to bridge-recognised keys; the bridge method is
      registered on the MAXScript side (parsing reused from
      registration_sync_test.py -- never reimplemented here)
   5. mutating flag matches the name heuristic (whitelist + reasons)
B. dangerous-tool gate table (output only, no behaviour change): mutating
   tools whose name contains delete/remove/clear/collapse/reset/cleanup/
   optimize, with confirm-gate and undo-protection status
C. MockBridge payload assertions through the real server:
   1. minimal legal arguments per tool -> exact method and preset merge
   2. a missing required parameter -> Python-layer rejection, no bridge call
   3. type coercion ("5" -> integer, true -> boolean, "a,b" -> array, ...)
   4. key regressions: collapse_stack confirm gate, mod_collapse alias and
      unchanged behaviour, mod_toggle / mod_chamfer / poly_select /
      poly_get_elements payload shapes, preset/argument precedence
D. run modes: human-readable output by default (non-zero exit on failure),
   --list (case inventory, starts nothing), --json (machine report);
   bridge port 8796 (never 8765 and never the 8791-8795 e2e range); scratch
   files live in .tmp-contract/ and are removed unless --keep-tmp is given.

Usage:
    python test/catalog_contract_test.py             # full run
    python test/catalog_contract_test.py --list      # case inventory only
    python test/catalog_contract_test.py --json      # machine readable report
Exit code 0 when the contract holds, 1 on violations, 2 on harness errors.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "src", "python"))
sys.path.insert(0, HERE)  # registration_sync_test lives next to this file

# Reuse the MAXScript registry parsing instead of writing a second copy.
import registration_sync_test as sync_test  # noqa: E402

from maxmcp.catalog import build_catalog  # noqa: E402
from maxmcp.catalog.schema import Tool  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

BRIDGE_PORT = 8796  # dedicated range: never 8765, never the 8791-8795 e2e block
TMP_DIR = os.path.join(REPO, ".tmp-contract")
CATALOG_GLOB = os.path.join(REPO, "src", "python", "maxmcp", "catalog", "*.py")

# --------------------------------------------------------------- contract data

#: Domain prefixes every category uses for its "noun-first" tool names.
CATEGORY_DOMAIN_PREFIXES: Dict[str, set] = {
    "animation": {"anim", "rig", "constraint", "ctrl"},
    "files": {"file"},
    "modeling": {"poly", "mod"},
    "objects": {"create"},
    "pipeline": {"render", "export", "import", "bake", "viewport", "vision"},
    "scene": {"scene"},
    "shading": {"mat", "light", "map", "cam", "env", "uvw"},
    "system": {"bridge"},
}

#: Verb-led names are a second, equally valid convention (mostly in the
#: verb-driven categories files / objects / system / scene).
GENERIC_VERB_PREFIXES: set = {
    "align", "array", "attach", "assign", "begin", "boolean", "cancel",
    "clone", "close", "copy", "count", "create", "delete", "deselect",
    "detach", "does", "end", "execute", "fetch", "find", "freeze", "get",
    "group", "hide", "hold", "list", "make", "mirror", "move", "open",
    "parent", "proboolean", "read", "redo", "release", "relink", "rename",
    "reset", "scatter", "select", "set", "snap", "transform", "undo",
    "unfreeze", "ungroup", "unhide", "unparent", "write",
}

#: Prefix exceptions, each with the reason it stays.  Anything not listed
#: here is a contract violation (A1).
PREFIX_WHITELIST: Dict[str, str] = {
    "spline_get_points": "spline is a geometry noun, but the tool reads point "
                         "data of spline *objects* by name -> objects category",
    "spline_set_points": "same as spline_get_points: writes points of named "
                         "spline objects -> objects category",
    "convert_to_editable_poly": "verb-led conversion utility; convert_to_* is "
                                "the documented modelling conversion family",
    "convert_to_editable_mesh": "verb-led conversion utility (see "
                                "convert_to_editable_poly)",
    "convert_to_nurbs": "verb-led conversion utility (see "
                        "convert_to_editable_poly)",
    "collapse_stack": "D4 compatibility alias of mod_collapse; the collapse_ "
                      "prefix mirrors the mod_* stack family on purpose",
    "model_extrude_spline": "model_ prefix marks spline-to-surface modelling "
                            "operations (extrude/lathe/loft/sweep)",
    "model_lathe_spline": "model_ prefix marks spline-to-surface modelling "
                          "operations",
    "model_loft": "model_ prefix marks spline-to-surface modelling operations",
    "model_sweep": "model_ prefix marks spline-to-surface modelling operations",
}

#: mutating-flag exceptions, each with a reason (A5).
MUTATING_WHITELIST: Dict[str, str] = {
    "set_language": "changes a server preference, not scene content; no Max "
                    "undo semantics apply to it",
    "ctrl_add_list": "'list' is a noun here (Max list controller), not the "
                     "verb; adding a controller is a real mutation",
}

#: Preset keys the bridge layer knows how to read, with the consumer site.
KNOWN_PRESET_KEYS: Dict[str, str] = {
    "class": "mcp_objects.ms mcpH_create_primitive / mcpH_create_spline "
             "(mcpStr params \"class\")",
    "modifier": "mcp_modeling_ext.ms mcpH_mod_add (mcpReqStr params \"modifier\")",
    "className": "mcp_shading.ms mcpH_mat_create_guarded "
                 "(mcpReqStr params \"className\")",
    "type": "mcp_lights.ms mcpH_light_create (mcpStr params \"type\")",
}

#: Name tokens that make a tool "dangerous" for the gate table (part B).
DANGEROUS_NAME_TOKENS = {"delete", "remove", "clear", "collapse", "reset",
                         "cleanup", "optimize"}

#: Name tokens behind the mutating-flag heuristic (A5).
READ_NAME_TOKENS = {"list", "get", "info", "stats", "query", "find"}
WRITE_NAME_TOKENS = {"add", "create", "set", "delete", "remove", "collapse",
                     "convert"}

ALLOWED_PROP_TYPES = {"string", "number", "integer", "boolean", "array",
                      "object"}

#: mcpRegister "method" mcpH_handler [undoable:true|false]
REGISTER_RE = re.compile(
    r'mcpRegister\s+"([A-Za-z0-9_]+)"\s+mcpH_[A-Za-z0-9_]+'
    r'(?:\s+undoable:(true|false))?'
)
#: A tool declaration line inside the catalog modules: "name", "category",
TOOL_LINE_RE = re.compile(r'^\s*"([a-z0-9_]+)",\s*"([a-z]+)",\s*$')


# ---------------------------------------------------------------- small utils
def tool_locations() -> Dict[str, Tuple[str, Optional[int]]]:
    """Map tool name -> (catalog file, line) for precise violation reports."""
    locations: Dict[str, Tuple[str, Optional[int]]] = {}
    for path in sorted(glob.glob(CATALOG_GLOB)):
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                match = TOOL_LINE_RE.match(line)
                if match:
                    locations.setdefault(match.group(1), (rel, lineno))
    return locations


def registrations() -> Dict[str, Dict[str, Any]]:
    """bridge method -> {file, undoable} from the MAXScript registrations."""
    out: Dict[str, Dict[str, Any]] = {}
    for name in sorted(sync_test.ms_files(sync_test.MS_DIR)):
        path = os.path.join(sync_test.MS_DIR, name)
        text = open(path, encoding="utf-8", errors="replace").read()
        for method, undoable in REGISTER_RE.findall(text):
            out[method] = {
                "file": "src/ms/" + name,
                # absent flag means the mcpRegister default: undoable:true
                "undoable": (undoable != "false"),
            }
    return out


def minimal_argument(spec: Dict[str, Any]) -> Any:
    """Smallest legal value for one property, per the contract rules."""
    type_name = spec.get("type")
    if type_name == "string":
        enum = spec.get("enum")
        return enum[0] if enum else "x"
    if type_name == "integer":
        minimum = spec.get("minimum")
        if minimum is not None and minimum > 1:
            return int(minimum)
        return 1
    if type_name == "number":
        minimum = spec.get("minimum")
        if minimum is not None and minimum > 1.0:
            return float(minimum)
        return 1.0
    if type_name == "boolean":
        return False
    if type_name == "array":
        items = spec.get("items") or {}
        if spec.get("minItems") == 3 and items.get("type") == "number":
            return [0, 0, 0]  # num3
        return []
    if type_name == "object":
        return {}
    return None


# ------------------------------------------------------------- static checks
def static_contract(catalog, locations, regs, repo_cmds) -> Dict[str, Any]:
    """Part A: per-tool contract checks.  Never raises, always reports."""
    violations: List[Dict[str, str]] = []
    advisory: List[Dict[str, str]] = []

    def where(name: str) -> str:
        file_name, line = locations.get(name, ("catalog", None))
        return "%s:%s" % (file_name, line) if line else file_name

    # A1 ------------------------------------------------------------------ names
    seen: Dict[str, int] = {}
    for entry in catalog:
        seen[entry.name] = seen.get(entry.name, 0) + 1
    for name, count in sorted(seen.items()):
        if count > 1:
            violations.append({"check": "A1", "tool": name, "where": where(name),
                               "detail": "name declared %d times" % count})

    for entry in catalog:
        prefix = entry.name.split("_")[0]
        domain = CATEGORY_DOMAIN_PREFIXES.get(entry.category, set())
        if prefix in domain or prefix in GENERIC_VERB_PREFIXES:
            continue
        reason = PREFIX_WHITELIST.get(entry.name)
        if reason is None:
            violations.append({
                "check": "A1", "tool": entry.name, "where": where(entry.name),
                "detail": "prefix %r not in the %s convention and not "
                          "whitelisted" % (prefix, entry.category),
            })

    for name in sorted(PREFIX_WHITELIST):
        if catalog.get(name) is None:
            advisory.append({"check": "A1", "tool": name, "where": "test",
                             "detail": "stale whitelist entry (tool gone)"})

    # A2 ------------------------------------------------------------ descriptions
    for entry in catalog:
        for attr in ("description_zh", "description_en"):
            text = (getattr(entry, attr) or "").strip()
            if not text:
                violations.append({"check": "A2", "tool": entry.name,
                                   "where": where(entry.name),
                                   "detail": "%s is empty" % attr})
            elif text.upper() in ("TODO", "TBD", "FIXME", "XXX"):
                violations.append({"check": "A2", "tool": entry.name,
                                   "where": where(entry.name),
                                   "detail": "%s is a placeholder" % attr})
        if entry.description_zh.strip() == entry.description_en.strip():
            advisory.append({"check": "A2", "tool": entry.name,
                             "where": where(entry.name),
                             "detail": "zh and en descriptions are identical"})

    # A3 ------------------------------------------------------------------ schema
    for entry in catalog:
        props = entry.schema.get("properties", {})
        required = entry.schema.get("required", [])
        for key, spec in props.items():
            type_name = spec.get("type")
            if type_name not in ALLOWED_PROP_TYPES:
                violations.append({
                    "check": "A3", "tool": entry.name, "where": where(entry.name),
                    "detail": "property %s has type %r (allowed: %s)"
                              % (key, type_name, sorted(ALLOWED_PROP_TYPES)),
                })
                continue
            enum = spec.get("enum")
            if enum is not None:
                if type_name == "string" and not all(isinstance(v, str) for v in enum):
                    violations.append({"check": "A3", "tool": entry.name,
                                       "where": where(entry.name),
                                       "detail": "property %s: enum has non-string values" % key})
                if type_name in ("number", "integer") and not all(
                        isinstance(v, (int, float)) and not isinstance(v, bool) for v in enum):
                    violations.append({"check": "A3", "tool": entry.name,
                                       "where": where(entry.name),
                                       "detail": "property %s: enum has non-numeric values" % key})
            default = spec.get("default")
            if default is not None:
                expected = {"string": str, "number": (int, float),
                            "integer": int, "boolean": bool,
                            "array": (list, tuple), "object": dict}[type_name]
                if not isinstance(default, expected) or isinstance(default, bool) != (type_name == "boolean"):
                    violations.append({
                        "check": "A3", "tool": entry.name, "where": where(entry.name),
                        "detail": "property %s: default %r does not match type %s"
                                  % (key, default, type_name),
                    })
            minimum, maximum = spec.get("minimum"), spec.get("maximum")
            if minimum is not None and maximum is not None and minimum > maximum:
                violations.append({
                    "check": "A3", "tool": entry.name, "where": where(entry.name),
                    "detail": "property %s: minimum %s > maximum %s"
                              % (key, minimum, maximum),
                })
        for key in required:
            if key not in props:
                violations.append({
                    "check": "A3", "tool": entry.name, "where": where(entry.name),
                    "detail": "required parameter %r is not a declared property" % key,
                })

    # A4 ------------------------------------------------- preset keys + bridge
    for entry in catalog:
        for key in entry.preset:
            if key not in KNOWN_PRESET_KEYS:
                violations.append({
                    "check": "A4", "tool": entry.name, "where": where(entry.name),
                    "detail": "preset key %r is not bridge-recognised (known: %s)"
                              % (key, sorted(KNOWN_PRESET_KEYS)),
                })
        method = entry.bridge_method
        if method not in repo_cmds:
            violations.append({
                "check": "A4", "tool": entry.name, "where": where(entry.name),
                "detail": "bridge method %r has no mcpRegister in src/ms" % method,
            })

    # A5 ----------------------------------------------------------- mutating flag
    for entry in catalog:
        tokens = set(entry.name.split("_"))
        reason = MUTATING_WHITELIST.get(entry.name)
        if tokens & READ_NAME_TOKENS and entry.mutating:
            if reason is None:
                violations.append({
                    "check": "A5", "tool": entry.name, "where": where(entry.name),
                    "detail": "read-only name but mutating=True",
                })
            else:
                advisory.append({"check": "A5", "tool": entry.name,
                                 "where": where(entry.name),
                                 "detail": "whitelisted: " + reason})
        if tokens & WRITE_NAME_TOKENS and not entry.mutating:
            if reason is None:
                violations.append({
                    "check": "A5", "tool": entry.name, "where": where(entry.name),
                    "detail": "mutating name but mutating=False",
                })
            else:
                advisory.append({"check": "A5", "tool": entry.name,
                                 "where": where(entry.name),
                                 "detail": "whitelisted: " + reason})
    for name in sorted(MUTATING_WHITELIST):
        if catalog.get(name) is None:
            advisory.append({"check": "A5", "tool": name, "where": "test",
                             "detail": "stale whitelist entry (tool gone)"})

    # cross-check: whitelisted mutating reasons must still match the rule they
    # excuse, otherwise the whitelist silently stops making sense
    for name, reason in MUTATING_WHITELIST.items():
        entry = catalog.get(name)
        if entry is None:
            continue
        tokens = set(entry.name.split("_"))
        if not ((tokens & READ_NAME_TOKENS and entry.mutating)
                or (tokens & WRITE_NAME_TOKENS and not entry.mutating)):
            advisory.append({"check": "A5", "tool": name, "where": "test",
                             "detail": "whitelist entry no longer needed: " + reason})

    return {"violations": violations, "advisory": advisory}


def dangerous_gate(catalog, regs) -> List[Dict[str, Any]]:
    """Part B: dangerous mutating tools with their protection status."""
    rows: List[Dict[str, Any]] = []
    for entry in catalog:
        tokens = set(entry.name.split("_"))
        if not (entry.mutating and (tokens & DANGEROUS_NAME_TOKENS)):
            continue
        method = entry.bridge_method
        reg = regs.get(method, {})
        rows.append({
            "tool": entry.name,
            "bridge": method,
            "confirm_prop": "confirm" in entry.schema["properties"],
            "confirm_required": "confirm" in entry.schema.get("required", []),
            "undoable": reg.get("undoable"),
            "registered_in": reg.get("file", "?"),
        })
    return sorted(rows, key=lambda r: r["tool"])


# ------------------------------------------------------------ mock bridge/MS
try:
    ANSI = "mbcs"
    "".encode(ANSI)
except LookupError:  # pragma: no cover
    ANSI = "utf-8"


def to_ansi(value: Any) -> Any:
    if isinstance(value, str):
        return value.encode(ANSI, "replace").decode("latin-1")
    if isinstance(value, dict):
        return {k: to_ansi(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_ansi(v) for v in value]
    return value


def from_ansi(value: Any) -> Any:
    if isinstance(value, str):
        return value.encode("latin-1", "backslashreplace").decode(ANSI, "replace")
    if isinstance(value, dict):
        return {k: from_ansi(v) for k, v in value.items()}
    if isinstance(value, list):
        return [from_ansi(v) for v in value]
    return value


class MockBridge(threading.Thread):
    """Records every bridge request; speaks the real wire protocol."""

    daemon = True

    def __init__(self, port: int) -> None:
        super().__init__()
        self.port = port
        self.calls: List[Dict[str, Any]] = []
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", port))
        self._sock.listen(8)
        self._stop = threading.Event()

    def run(self) -> None:
        self._sock.settimeout(0.4)
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        conn.settimeout(10.0)
        buf = b""
        try:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        request = json.loads(line.decode("ascii"))
                    except (ValueError, UnicodeDecodeError):
                        break
                    params = from_ansi(request.get("params") or {})
                    self.calls.append({"method": request.get("method"), "params": params})
                    reply = self._respond(request.get("id"), request.get("method"))
                    conn.sendall((json.dumps(to_ansi(reply), ensure_ascii=True) + "\n").encode("ascii"))
        except OSError:
            pass
        finally:
            conn.close()

    def _respond(self, request_id: Any, method: Optional[str]) -> Dict[str, Any]:
        if method == "bridge_status":
            result = {"running": True, "port": self.port, "language": "zh",
                      "maxLanguage": "CHS", "handlerCount": 353}
        else:
            result = {"ok": True, "method": method, "mock": True}
        return {"id": request_id, "ok": True, "result": result}

    def stop(self) -> None:
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass

    def since(self, mark: int, method: Optional[str] = None) -> List[Dict[str, Any]]:
        """Bridge calls recorded after `mark`, optionally filtered by method."""
        return [c for c in self.calls[mark:]
                if method is None or c["method"] == method]


class McpClient:
    """Minimal stdio MCP client for the real server process."""

    def __init__(self, port: int, log_path: str) -> None:
        env = dict(os.environ)
        env["MAXMCP_PORT"] = str(port)
        env["PYTHONPATH"] = os.path.join(REPO, "src", "python")
        env["PYTHONIOENCODING"] = "utf-8"
        env["MAXMCP_HOME"] = os.path.join(TMP_DIR, "home")
        env.pop("MAXMCP_LANGUAGE", None)
        # stderr goes to a file, never a pipe: a full pipe would deadlock a
        # long run (554+ requests) the moment the server logs.
        self._log = open(log_path, "wb")
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "maxmcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._log,
            cwd=REPO, env=env,
        )
        self._id = 0

    def request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        self._id += 1
        message = {"jsonrpc": "2.0", "id": self._id, "method": method,
                   "params": params or {}}
        payload = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.proc.stdin.write(payload)
        self.proc.stdin.flush()
        deadline = time.time() + 30
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout: {0}".format(self.stderr()))
            text = line.decode("utf-8").strip()
            if not text:
                continue
            reply = json.loads(text)
            if reply.get("id") == self._id:
                return reply
        raise TimeoutError("no reply for {0}".format(method))

    def notify(self, method: str, params: Optional[Dict[str, Any]] = None) -> None:
        message = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        assert self.proc.stdin is not None
        self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def stderr(self) -> str:
        try:
            with open(self._log.name, "rb") as fh:
                return fh.read().decode("utf-8", "replace")[-2000:]
        except OSError:
            return ""

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        finally:
            self._log.close()


def tool_text(reply: Dict[str, Any]) -> str:
    return "\n".join(
        block.get("text", "") for block in reply.get("result", {}).get("content", [])
    )


# --------------------------------------------------------------- payload phase
#: --json switches the whole run to a pure-JSON channel.
_QUIET = False


def say(message: str) -> None:
    if not _QUIET:
        print(message)
class Reporter:
    """Collects cases (name / expect / actual / PASS|FAIL) without aborting."""

    def __init__(self, quiet: bool = False) -> None:
        self.cases: List[Dict[str, Any]] = []
        self.passed = 0
        self.failed = 0
        self.quiet = quiet

    def case(self, group: str, name: str, expect: str, actual: str,
             ok: bool, verbose: bool = True) -> bool:
        self.cases.append({"group": group, "name": name, "expect": expect,
                           "actual": actual, "ok": ok})
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        if not self.quiet and (verbose or not ok):
            print("  [%s] %-34s expect=%-46s actual=%s"
                  % ("PASS" if ok else "FAIL", name, expect[:46], actual[:90]))
        return ok

    def quiet_case(self, group: str, name: str, expect: str, actual: str,
                   ok: bool) -> bool:
        return self.case(group, name, expect, actual, ok, verbose=False)


def call_tool(client: McpClient, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    return client.request("tools/call", {"name": name, "arguments": arguments})


def phase_c1(client: McpClient, bridge: MockBridge, catalog, rep: Reporter) -> None:
    """Minimal legal arguments -> exact method and preset merge, per tool."""
    say("C1 minimal payload per tool (%d tools)" % len(catalog))
    for index, entry in enumerate(catalog):
        args = {key: minimal_argument(entry.schema["properties"][key])
                for key in entry.schema.get("required", [])}
        expected = dict(entry.preset)
        expected.update(args)
        mark = len(bridge.calls)
        reply = call_tool(client, entry.name, args)
        if reply.get("error") is not None:
            rep.quiet_case("C1", entry.name, "bridge call " + entry.bridge_method,
                           "jsonrpc error: %s" % reply["error"], False)
            continue
        recorded = bridge.since(mark, entry.bridge_method)
        if len(recorded) != 1:
            rep.quiet_case("C1", entry.name, "exactly one bridge call",
                           "%d calls recorded" % len(recorded), False)
            continue
        params = recorded[0]["params"]
        ok = params == expected
        detail = "method ok, params %s" % (
            "match" if ok else "mismatch: %r != %r" % (params, expected))
        if not ok:
            detail = "params mismatch: got %r want %r" % (params, expected)
        rep.quiet_case("C1", entry.name,
                       "method=%s params=%s" % (entry.bridge_method, expected),
                       detail, ok)
        if (index + 1) % 40 == 0:
            say("    ... %d/%d" % (index + 1, len(catalog)))


def phase_c2(client: McpClient, bridge: MockBridge, catalog, rep: Reporter) -> None:
    """Missing required parameter -> Python-layer rejection, no bridge call."""
    required_tools = [e for e in catalog if e.schema.get("required")]
    say("C2 required-parameter rejection (%d tools with required params)"
        % len(required_tools))
    for entry in required_tools:
        dropped = entry.schema["required"][0]
        args = {key: minimal_argument(entry.schema["properties"][key])
                for key in entry.schema["required"][1:]}
        mark = len(bridge.calls)
        reply = call_tool(client, entry.name, args)
        result = reply.get("result") or {}
        is_error = bool(result.get("isError"))
        text = tool_text(reply)
        # a language re-sync (bridge_status) may interleave; it is not a tool
        # payload, so only count calls of other methods
        stray = [c for c in bridge.since(mark) if c["method"] != "bridge_status"]
        ok = is_error and "missing required parameter" in text and not stray
        actual = "isError=%s text=%r bridge_calls=%d" % (
            is_error, text[:60], len(stray))
        rep.quiet_case("C2", entry.name,
                       "rejected without %s, no bridge call" % dropped,
                       actual, ok)


def phase_c3(client: McpClient, bridge: MockBridge, rep: Reporter) -> None:
    """Type coercion through the real server."""
    say("C3 type coercion")
    cases: List[Tuple[str, Dict[str, Any], Dict[str, Any]]] = [
        ("undo_last", {"steps": "5"}, {"steps": 5}),
        ("undo_last", {"steps": 2}, {"steps": 2}),
        ("create_box", {"length": "2.5"}, {"class": "Box", "length": 2.5}),
        ("create_teapot", {"smooth": "true"}, {"class": "Teapot", "smooth": True}),
        ("create_teapot", {"smooth": "false"}, {"class": "Teapot", "smooth": False}),
        ("create_teapot", {"smooth": 1}, {"class": "Teapot", "smooth": True}),
        ("mod_toggle", {"modifier": "TurboSmooth", "objects": "Box001,Box002"},
         {"modifier": "TurboSmooth", "objects": ["Box001", "Box002"]}),
        ("mod_toggle", {"modifier": "TurboSmooth", "objects": "Box001"},
         {"modifier": "TurboSmooth", "objects": ["Box001"]}),
        ("mod_toggle", {"modifier": "TurboSmooth", "objects": 5},
         {"modifier": "TurboSmooth", "objects": [5]}),
        ("find_objects", {"name": 5}, {"name": "5"}),
        ("find_objects", {"name": ["a", "b"]}, {"name": '["a", "b"]'}),
        ("create_box", {"position": [1, 2, 3]}, {"class": "Box", "position": [1, 2, 3]}),
        ("poly_get_elements", {"limit": "7", "objects": ["Box001"]},
         {"limit": 7, "objects": ["Box001"]}),
    ]
    for name, args, expected in cases:
        mark = len(bridge.calls)
        reply = call_tool(client, name, args)
        recorded = bridge.since(mark, name)
        if len(recorded) != 1:
            rep.case("C3", "%s %s" % (name, args), str(expected),
                     "%d bridge calls" % len(recorded), False)
            continue
        params = recorded[0]["params"]
        ok = params == expected and _types_match(params, expected)
        rep.case("C3", "%s(%s)" % (name, json.dumps(args, ensure_ascii=False)),
                 json.dumps(expected, ensure_ascii=False),
                 json.dumps(params, ensure_ascii=False), ok)


def _types_match(got: Any, want: Any) -> bool:
    """JSON round trips keep int/float apart; the contract cares."""
    if isinstance(want, bool) or isinstance(got, bool):
        return isinstance(got, bool) and isinstance(want, bool)
    if isinstance(want, float):
        return isinstance(got, float)
    if isinstance(want, int):
        return isinstance(got, int) and not isinstance(got, bool)
    if isinstance(want, list) and isinstance(got, list):
        return len(got) == len(want) and all(
            _types_match(g, w) for g, w in zip(got, want))
    return True


def phase_c4(client: McpClient, bridge: MockBridge, rep: Reporter) -> None:
    """Key regressions around the collapse gate, aliases and payload shapes."""
    say("C4 key regressions")

    def expect_call(name: str, args: Dict[str, Any], method: str,
                    expected_params: Dict[str, Any], label: str) -> None:
        mark = len(bridge.calls)
        reply = call_tool(client, name, args)
        recorded = bridge.since(mark, method)
        if len(recorded) != 1:
            rep.case("C4", label, "one %s call" % method,
                     "%d calls" % len(recorded), False)
            return
        params = recorded[0]["params"]
        ok = params == expected_params
        rep.case("C4", label,
                 "method=%s params=%s" % (method, json.dumps(expected_params, ensure_ascii=False)),
                 "params=%s" % json.dumps(params, ensure_ascii=False), ok)

    def expect_reject(name: str, args: Dict[str, Any], needle: str, label: str) -> None:
        mark = len(bridge.calls)
        reply = call_tool(client, name, args)
        result = reply.get("result") or {}
        text = tool_text(reply)
        stray = [c for c in bridge.since(mark) if c["method"] != "bridge_status"]
        ok = bool(result.get("isError")) and needle in text and not stray
        rep.case("C4", label, "rejected (%s), no bridge call" % needle,
                 "isError=%s text=%r calls=%d" % (bool(result.get("isError")),
                                                  text[:60], len(stray)), ok)

    # collapse_stack: the confirm gate lives in the Python catalog layer
    expect_reject("collapse_stack", {"objects": ["Box001"]},
                  "missing required parameter",
                  "collapse_stack without confirm is rejected")
    expect_call("collapse_stack", {"objects": ["Box001"], "confirm": True},
                "mod_collapse", {"objects": ["Box001"], "confirm": True},
                "collapse_stack with confirm reaches mod_collapse")
    # mod_collapse itself: behaviour unchanged (D4 alias must not have moved it)
    expect_call("mod_collapse", {"objects": ["Box001"], "confirm": True},
                "mod_collapse", {"objects": ["Box001"], "confirm": True},
                "mod_collapse collapses with confirm")
    expect_call("mod_collapse",
                {"objects": ["Box001"], "confirm": True, "modifier": "TurboSmooth"},
                "mod_collapse",
                {"objects": ["Box001"], "confirm": True, "modifier": "TurboSmooth"},
                "mod_collapse honours the modifier filter")
    # shared handler payload shapes
    expect_call("mod_toggle", {"modifier": "TurboSmooth"},
                "mod_toggle", {"modifier": "TurboSmooth"},
                "mod_toggle payload shape")
    expect_call("mod_chamfer", {}, "mod_add", {"modifier": "Chamfer"},
                "mod_chamfer preset merge (empty args)")
    expect_call("mod_chamfer", {"objects": ["Box001"], "amount": 2},
                "mod_add", {"modifier": "Chamfer", "objects": ["Box001"], "amount": 2.0},
                "mod_chamfer preset + args merge")
    expect_call("poly_select", {"objects": ["Box001"], "faces": [1, 2, 3]},
                "poly_select", {"objects": ["Box001"], "faces": [1, 2, 3]},
                "poly_select payload shape")
    expect_call("poly_get_elements", {"objects": ["Box001"], "limit": 5},
                "poly_get_elements", {"objects": ["Box001"], "limit": 5},
                "poly_get_elements payload shape")
    # preset vs argument precedence
    expect_call("light_create_omni", {"name": "L1", "type": "spot"},
                "light_create", {"type": "omni", "name": "L1"},
                "preset survives an undeclared same-name argument")

    # A declared property wins over the preset of the same name.  No catalog
    # tool currently overlaps preset keys with properties (checked below), so
    # the semantics are pinned with a synthetic tool through the real
    # _build_payload code path.
    synthetic = Tool(
        name="synthetic_preset_probe", category="system",
        description_zh="探针", description_en="probe",
        schema={"type": "object",
                "properties": {"class": {"type": "string"},
                               "name": {"type": "string"}},
                "required": [], "additionalProperties": False},
        preset={"class": "FromPreset"},
    )
    server = MaxMcpServer.__new__(MaxMcpServer)
    payload = server._build_payload(synthetic, {"class": "FromArgument", "name": "N"})
    ok = payload.get("class") == "FromArgument" and payload.get("name") == "N"
    rep.case("C4", "declared argument overrides preset value",
             "class=FromArgument", "class=%s" % payload.get("class"), ok)


def phase_c4b(catalog, rep: Reporter) -> None:
    """Static companion to the precedence probe: no catalog tool overlaps."""
    overlap = [e.name for e in catalog
               if set(e.preset) & set(e.schema["properties"])]
    rep.case("C4b", "no catalog tool overlaps preset keys with properties",
             "0 overlapping tools", "%d: %s" % (len(overlap), overlap[:5]),
             not overlap)


# --------------------------------------------------------------------- output
def print_static_summary(static: Dict[str, Any]) -> None:
    violations = static["violations"]
    advisory = static["advisory"]
    say("\nA. static contract: %d violation(s), %d advisory note(s)"
        % (len(violations), len(advisory)))
    for item in violations:
        say("  [VIOLATION] %s %s (%s): %s"
              % (item["check"], item["tool"], item["where"], item["detail"]))
    for item in advisory:
        say("  [advisory]   %s %s (%s): %s"
              % (item["check"], item["tool"], item["where"], item["detail"]))


def print_dangerous_table(rows: List[Dict[str, Any]]) -> None:
    say("\nB. dangerous tools (output only): %d" % len(rows))
    say("  %-26s %-22s %-8s %-9s %-9s %s"
        % ("tool", "bridge", "confirm", "confirm", "undoable", "registered in"))
    say("  %-26s %-22s %-8s %-9s %-9s %s"
        % ("", "", "prop", "required", "", ""))
    for row in rows:
        say("  %-26s %-22s %-8s %-9s %-9s %s"
            % (row["tool"], row["bridge"],
                 "yes" if row["confirm_prop"] else "-",
                 "yes" if row["confirm_required"] else "-",
                 "yes" if row["undoable"] else ("no" if row["undoable"] is False else "?"),
                 row["registered_in"]))


def case_inventory(catalog, regs, repo_cmds) -> None:
    """--list: what a full run would check, without starting anything."""
    required_tools = [e for e in catalog if e.schema.get("required")]
    dangerous = dangerous_gate(catalog, regs)
    print("=== catalog contract test: case inventory (no services started) ===")
    print("catalog tools            : %d" % len(catalog))
    print("maxscript commands       : %d (parsed by registration_sync_test)"
          % len(repo_cmds))
    print("bridge port (mock)       : %d   scratch: %s" % (BRIDGE_PORT, TMP_DIR))
    print()
    print("A. static contract, per tool")
    print("   A1 unique names + category prefix convention .. %d checks, "
          "%d whitelisted exceptions" % (len(catalog), len(PREFIX_WHITELIST)))
    print("   A2 bilingual descriptions ...................... %d checks" % len(catalog))
    print("   A3 schema legality ............................. %d checks" % len(catalog))
    print("   A4 preset keys + bridge registration .......... %d checks" % len(catalog))
    print("   A5 mutating flag heuristic ..................... %d checks, "
          "%d whitelisted" % (len(catalog), len(MUTATING_WHITELIST)))
    print("B. dangerous tool gate table (output only) ....... %d tools" % len(dangerous))
    print("C. MockBridge payload assertions (real server over stdio)")
    print("   C1 minimal payload per tool .................... %d cases" % len(catalog))
    print("   C2 required-parameter rejection ................ %d cases"
          % len(required_tools))
    print("   C3 type coercion ............................... 13 cases")
    print("   C4 key regressions ............................. 11 cases")
    print("   C4b preset/property overlap (static) ........... 1 case")
    print()
    print("run without --list to execute everything; --json prints the "
          "machine-readable report.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Python-layer contract test for the 3ds Max MCP catalog.")
    parser.add_argument("--list", action="store_true",
                        help="print the case inventory and exit (starts nothing)")
    parser.add_argument("--json", action="store_true",
                        help="print the machine-readable report as JSON")
    parser.add_argument("--keep-tmp", action="store_true",
                        help="keep the .tmp-contract/ scratch directory")
    args = parser.parse_args()

    try:
        catalog = build_catalog()
    except Exception as exc:  # noqa: BLE001
        print("cannot build the catalog: %s" % exc)
        return 2

    locations = tool_locations()
    regs = registrations()
    repo_cmds = sync_test.registered_commands(sync_test.MS_DIR)

    if args.list:
        case_inventory(catalog, regs, repo_cmds)
        return 0

    static = static_contract(catalog, locations, regs, repo_cmds)
    dangerous = dangerous_gate(catalog, regs)
    global _QUIET
    _QUIET = bool(args.json)
    rep = Reporter(quiet=_QUIET)

    say("=== catalog contract test (port %d, scratch %s) ==="
        % (BRIDGE_PORT, TMP_DIR))
    print_static_summary(static)
    print_dangerous_table(dangerous)

    # ---------------------------------------------------------- payload phases
    if os.path.isdir(TMP_DIR):
        shutil.rmtree(TMP_DIR, ignore_errors=True)
    os.makedirs(os.path.join(TMP_DIR, "home"), exist_ok=True)
    bridge = MockBridge(BRIDGE_PORT)
    bridge.start()
    time.sleep(0.3)
    client = McpClient(BRIDGE_PORT, os.path.join(TMP_DIR, "server.stderr.log"))
    harness_error: Optional[str] = None
    try:
        init = client.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "catalog-contract-test", "version": "1.0"},
        })
        if init.get("error") is not None:
            raise RuntimeError("initialize failed: %s" % init["error"])
        client.notify("notifications/initialized")

        listing = client.request("tools/list")
        tools = (listing.get("result") or {}).get("tools") or []
        rep.case("C0", "server exposes the full catalog",
                 "%d tools" % len(catalog), "%d tools" % len(tools),
                 len(tools) == len(catalog))

        phase_c4b(catalog, rep)
        phase_c1(client, bridge, catalog, rep)
        phase_c2(client, bridge, catalog, rep)
        phase_c3(client, bridge, rep)
        phase_c4(client, bridge, rep)
    except Exception as exc:  # noqa: BLE001
        harness_error = "%s: %s" % (type(exc).__name__, exc)
        say("\nHARNESS ERROR: %s" % harness_error)
        say("server stderr tail:\n%s" % client.stderr())
    finally:
        client.close()
        bridge.stop()

    # ------------------------------------------------------------------ report
    failed_cases = [c for c in rep.cases if not c["ok"]]
    say("\n=== summary ===")
    say("tools checked (A)        : %d" % len(catalog))
    say("static violations        : %d" % len(static["violations"]))
    say("advisory notes           : %d" % len(static["advisory"]))
    say("dangerous tools (B)      : %d (output only)" % len(dangerous))
    say("payload cases (C)        : %d passed, %d failed"
        % (rep.passed, rep.failed))
    if failed_cases:
        say("failed cases:")
        for case in failed_cases[:40]:
            say("  [%s] %s -- expect %s -- actual %s"
                % (case["group"], case["name"], case["expect"], case["actual"]))

    report = {
        "tool": "catalog_contract_test",
        "port": BRIDGE_PORT,
        "totals": {
            "tools": len(catalog),
            "static_violations": len(static["violations"]),
            "advisory": len(static["advisory"]),
            "dangerous_tools": len(dangerous),
            "payload_cases": len(rep.cases),
            "payload_passed": rep.passed,
            "payload_failed": rep.failed,
        },
        "static": static,
        "dangerous": dangerous,
        "cases": rep.cases,
        "harness_error": harness_error,
    }
    report_path = os.path.join(TMP_DIR, "contract_report.json")
    try:
        with open(report_path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
        say("report: %s" % report_path)
    except OSError:
        pass
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))

    if not args.keep_tmp and os.path.isdir(TMP_DIR):
        shutil.rmtree(TMP_DIR, ignore_errors=True)

    if harness_error:
        return 2
    if static["violations"] or rep.failed:
        return 1
    say("\ncatalog contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
