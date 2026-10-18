"""End-to-end test of the MCP server over real stdio, against a mock bridge.

Nothing here needs 3ds Max.  A tiny TCP server emulates the MAXScript bridge
(including the ANSI byte escaping the real bridge uses) so the whole chain can
be exercised:

    test harness  --stdio JSON-RPC-->  maxmcp server  --TCP-->  mock bridge

Checks: initialize handshake, tools/list size and language switching,
tools/call result decoding, Chinese round trip, error reporting, profiles.

Usage:  python scripts/test_e2e.py
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "python")
# The wire-port (server -> 3ds Max) and the HTTP port (client -> server) are
# different sockets, so every test needs a pair of them.
PORT = 8791                # stdio test: bridge wire port
HTTP_BRIDGE_PORT = 8792    # http test: bridge wire port
HTTP_PORT = 8793           # http test: HTTP listener
HTTP_AUTH_PORT = 8794      # auth test: HTTP listener
AUTO_PORT = 8795           # auto-language test: bridge wire port

try:
    ANSI = "mbcs"
    "".encode(ANSI)
except LookupError:  # pragma: no cover
    ANSI = "utf-8"


def to_ansi(value: Any) -> Any:
    """Emulate MAXScript: latin-1 code points travel as ANSI bytes."""
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
    """Speaks the bridge wire protocol on localhost."""

    daemon = True

    def __init__(self, port: int, language: str = "zh", max_language: str = "CHS") -> None:
        super().__init__()
        self.port = port
        self.language = language
        self.max_language = max_language
        self.calls: List[Dict[str, Any]] = []
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", port))
        self._sock.listen(4)
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
        conn.settimeout(5.0)
        buf = b""
        try:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        request = json.loads(line.decode("ascii"))
                    except (ValueError, UnicodeDecodeError):
                        # A stray connection (a port probe, or an HTTP client
                        # pointed at the wrong socket) must not kill the harness.
                        break
                    raw_params = request.get("params") or {}
                    # What MAXScript would see: ANSI bytes restored.
                    params = from_ansi(raw_params)
                    self.calls.append({"method": request.get("method"), "params": params})
                    reply = self._respond(request.get("id"), request.get("method"), params)
                    conn.sendall((json.dumps(to_ansi(reply), ensure_ascii=True) + "\n").encode("ascii"))
        except OSError:
            pass
        finally:
            conn.close()

    def _respond(self, request_id: Any, method: Optional[str], params: Dict[str, Any]) -> Dict[str, Any]:
        if method == "bridge_status":
            result = {
                "running": True,
                "port": self.port,
                "language": self.language,
                "maxLanguage": self.max_language,
                "handlerCount": 346,
            }
        elif method == "bridge_ping":
            result = {"pong": True, "message": "心跳正常"}
        elif method == "set_language":
            requested = str(params.get("language") or "").lower()
            if requested in ("auto", "follow", "default"):
                self.language = "en" if self.max_language == "ENU" else "zh"
                pinned = False
            else:
                self.language = "en" if requested.startswith("en") else "zh"
                pinned = True
            result = {
                "language": self.language,
                "pinned": pinned,
                "maxLanguage": self.max_language,
                "message": "Language switched to English." if self.language == "en" else "语言已切换为简体中文。",
            }
        elif method == "scene_open":
            # emulate a MAXScript handler raising a localised error
            return {
                "id": request_id,
                "ok": False,
                "error": {"kind": "runtime_error", "message": "文件不存在：D:\\项目\\角色_模型.max"},
            }
        else:
            result = {"ok": True, "method": method, "echo": params}
        return {"id": request_id, "ok": True, "result": result}

    def stop(self) -> None:
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass


TMP_ROOT = os.path.join(ROOT, ".tmp-e2e")


def isolated_env(port: int, language: Optional[str] = None, home: str = "default") -> Dict[str, str]:
    """Environment for a test server process.

    MAXMCP_HOME is redirected into the repo so a test run can never read (or
    worse, rewrite) the developer's real ~/.3dsmax-mcp/config.json.
    """
    env = dict(os.environ)
    env["MAXMCP_PORT"] = str(port)
    env["PYTHONPATH"] = SRC
    env["PYTHONIOENCODING"] = "utf-8"
    env["MAXMCP_HOME"] = os.path.join(TMP_ROOT, home)
    if language is not None:
        env["MAXMCP_LANGUAGE"] = language
    else:
        env.pop("MAXMCP_LANGUAGE", None)
    return env


class McpClient:
    """Minimal stdio MCP client."""

    def __init__(self, port: int, language: Optional[str] = None, home: str = "default") -> None:
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "maxmcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=ROOT,
            env=isolated_env(port, language, home),
        )
        self._id = 0

    def request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        self._id += 1
        message = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}
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
        if self.proc.stderr is None:
            return ""
        try:
            return self.proc.stderr.read().decode("utf-8", "replace")[-4000:]
        except Exception:
            return ""

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def tool_text(reply: Dict[str, Any]) -> str:
    return "\n".join(
        block.get("text", "") for block in reply.get("result", {}).get("content", [])
    )


def check_config_persistence(failures: List[str]) -> None:
    """set_language must persist the language only, never a run-scoped --port.

    The server accepts throwaway overrides on the command line. If saving the
    config wrote those back, a single ``set_language`` call would bake a debug
    port into the user's config and silently desync the server from the bridge
    on the next launch. Regression guard for that.

    Runs in a subprocess so it gets its own MAXMCP_HOME and never touches the
    real user config.
    """
    script = r"""
import json, os, shutil
from pathlib import Path

home = Path(os.environ["MAXMCP_HOME"])
cfg_path = home / "config.json"
home.mkdir(parents=True, exist_ok=True)
cfg_path.write_text(json.dumps({"port": 8765, "language": "zh"}), encoding="utf-8")

from maxmcp.config import Config

cfg = Config.load()
assert cfg.language == "zh", "unexpected stored language"

# Simulate `python -m maxmcp --port 8791` followed by a set_language('en').
cfg.port = 8791
cfg.language = "en"
cfg.save(keys=("language",))

saved = json.loads(cfg_path.read_text(encoding="utf-8"))
assert saved["port"] == 8765, "run-scoped --port leaked into the config: %r" % saved["port"]
assert saved["language"] == "en", "language was not persisted"
shutil.rmtree(home, ignore_errors=True)
print("ok")
"""
    env = dict(os.environ)
    env["PYTHONPATH"] = SRC
    env["MAXMCP_HOME"] = os.path.join(ROOT, ".tmp-config-persistence-test")
    try:
        proc = subprocess.run(
            [sys.executable, "-c", script],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        failures.append("config persistence check could not run: {0}".format(exc))
        return

    if proc.returncode != 0 or "ok" not in proc.stdout:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        failures.append(
            "config persistence check failed: {0}".format(detail[-1] if detail else "no output")
        )
        return
    print("set_language persists only the language (no --port leak)")


def wait_for_port(port: int, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        except OSError:
            time.sleep(0.15)
    return False


def http_post(port: int, payload: Any, path: str = "/mcp", token: Optional[str] = None,
              accept: str = "application/json") -> Tuple[int, Dict[str, str], str]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:{0}{1}".format(port, path), data=body, method="POST"
    )
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", accept)
    if token:
        request.add_header("Authorization", "Bearer {0}".format(token))
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, dict(response.headers), response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read().decode("utf-8", "replace")


def http_get(port: int, path: str, token: Optional[str] = None) -> Tuple[int, str]:
    request = urllib.request.Request("http://127.0.0.1:{0}{1}".format(port, path))
    if token:
        request.add_header("Authorization", "Bearer {0}".format(token))
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")


def start_http_server(http_port: int, bridge_port: int, token: Optional[str] = None,
                      home: str = "http") -> subprocess.Popen:
    argv = [sys.executable, "-m", "maxmcp", "--transport", "http", "--http-port", str(http_port)]
    if token:
        argv += ["--http-token", token]
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=ROOT,
        env=isolated_env(bridge_port, home=home),
    )
    if not wait_for_port(http_port):
        try:
            proc.kill()
        except Exception:
            pass
        raise RuntimeError("HTTP server never listened on {0}".format(http_port))
    return proc


def check_http_transport(failures: List[str]) -> None:
    """Streamable HTTP + legacy SSE, exercised over real sockets."""
    port = HTTP_PORT
    bridge = MockBridge(HTTP_BRIDGE_PORT)
    bridge.start()
    time.sleep(0.3)
    server = None
    try:
        server = start_http_server(port, HTTP_BRIDGE_PORT)

        status, body = http_get(port, "/health")
        if status != 200 or '"status": "ok"' not in body and '"status":"ok"' not in body:
            failures.append("GET /health returned {0}: {1}".format(status, body[:200]))
        else:
            print("http: /health ok")

        # ---------------------------------------------------- initialize + session
        status, headers, body = http_post(port, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "http-e2e", "version": "0.1"}},
        })
        session_id = headers.get("Mcp-Session-Id") or headers.get("mcpsession-id")
        if status != 200:
            failures.append("POST /mcp initialize returned {0}: {1}".format(status, body[:200]))
        else:
            parsed = json.loads(body)
            if parsed.get("result", {}).get("serverInfo", {}).get("name") != "3dsmax-mcp":
                failures.append("http initialize returned an unexpected serverInfo: {0}".format(body[:200]))
            elif not session_id:
                failures.append("http initialize did not hand out an Mcp-Session-Id")
            else:
                print("http: initialize ok (session {0}...)".format(session_id[:8]))

        # --------------------------------------------------------------- tools/list
        status, _, body = http_post(port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        count = 0
        if status == 200:
            count = len(json.loads(body).get("result", {}).get("tools", []))
        if count < 160:
            failures.append("http tools/list returned {0} tools (status {1})".format(count, status))
        else:
            print("http: tools/list -> {0} tools".format(count))

        # ------------------------------------------- tools/call with a Chinese name
        status, _, body = http_post(port, {
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "create_box", "arguments": {"name": "角色_头部模型", "length": 10}},
        })
        if status != 200 or "角色_头部模型" not in body:
            failures.append("http tools/call lost the Chinese round trip: {0}".format(body[:200]))
        else:
            print("http: Chinese round trip over POST /mcp")

        # ------------------------------------------------ notification -> empty 202
        status, _, body = http_post(port, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        if status != 202:
            failures.append("a notification should answer 202, got {0}".format(status))
        elif body.strip():
            failures.append("a notification should return an empty body, got {0}".format(body[:120]))
        else:
            print("http: notification -> 202 empty")

        # ---------------------------------------------------------------- batch
        status, _, body = http_post(port, [
            {"jsonrpc": "2.0", "id": 10, "method": "ping", "params": {}},
            {"jsonrpc": "2.0", "id": 11, "method": "tools/list", "params": {}},
        ])
        if status != 200:
            failures.append("a batch request returned {0}".format(status))
        else:
            parsed = json.loads(body)
            if not isinstance(parsed, list) or len(parsed) != 2:
                failures.append("a batch of 2 should answer with a 2-element array, got {0}".format(body[:160]))
            else:
                print("http: batch of 2 -> 2 replies")

        # ------------------------------------------------------ legacy HTTP + SSE
        check_legacy_sse(port, failures)

        # -------------------------------------------------------------- auth gate
        check_http_auth(failures)

    except Exception as exc:  # noqa: BLE001
        failures.append("http transport check raised: {0}".format(exc))
    finally:
        if server is not None:
            try:
                server.kill()
                server.wait(timeout=10)
            except Exception:
                pass
        bridge.stop()


def check_legacy_sse(port: int, failures: List[str]) -> None:
    """GET /sse hands back an endpoint, POST /messages pushes the reply back."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        conn.request("GET", "/sse", headers={"Accept": "text/event-stream"})
        response = conn.getresponse()
        if response.status != 200:
            failures.append("GET /sse returned {0}".format(response.status))
            return

        endpoint = ""
        deadline = time.time() + 10
        while time.time() < deadline and not endpoint:
            line = response.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if text.startswith("data:"):
                endpoint = text[5:].strip()
        if not endpoint.startswith("/messages"):
            failures.append("the SSE endpoint event was not an /messages path: {0!r}".format(endpoint))
            return

        status, _, _ = http_post(port, {
            "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {},
        }, path=endpoint)
        if status != 202:
            failures.append("POST {0} should answer 202, got {1}".format(endpoint, status))
            return

        # The actual reply arrives on the stream we already have open.
        payload = ""
        deadline = time.time() + 20
        while time.time() < deadline and not payload:
            line = response.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if text.startswith("data:") and "result" in text:
                payload = text[5:].strip()
        if not payload:
            failures.append("no JSON-RPC reply arrived over the SSE stream")
            return
        tools = json.loads(payload).get("result", {}).get("tools", [])
        if len(tools) < 160:
            failures.append("SSE reply carried {0} tools".format(len(tools)))
        else:
            print("http: legacy SSE /sse + /messages -> {0} tools".format(len(tools)))
    finally:
        conn.close()


def check_http_auth(failures: List[str]) -> None:
    """--http-token must reject anonymous callers."""
    port = HTTP_AUTH_PORT
    token = "s3cret-token"
    server = None
    try:
        server = start_http_server(port, HTTP_BRIDGE_PORT, token=token, home="http-auth")

        status, _ = http_get(port, "/health")
        if status != 200:
            failures.append("the health probe should stay open, got {0}".format(status))

        status, _, _ = http_post(port, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
        if status != 401:
            failures.append("an anonymous POST should be rejected with 401, got {0}".format(status))

        status, _, body = http_post(
            port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, token=token
        )
        if status != 200 or "bridge_status" not in body:
            failures.append("an authenticated POST should succeed, got {0}".format(status))
        else:
            print("http: --http-token gate works (401 anonymous / 200 bearer)")
    except Exception as exc:  # noqa: BLE001
        failures.append("http auth check raised: {0}".format(exc))
    finally:
        if server is not None:
            try:
                server.kill()
                server.wait(timeout=10)
            except Exception:
                pass


def check_language_auto(failures: List[str]) -> None:
    """With language=auto the server must mirror the running Max UI language."""
    cases = (
        ("en", "ENU", "English"),
        ("zh", "CHS", "中文"),
    )
    for bridge_language, max_code, expected in cases:
        bridge = MockBridge(AUTO_PORT, language=bridge_language, max_language=max_code)
        bridge.start()
        time.sleep(0.3)
        client = McpClient(AUTO_PORT, language="auto", home="auto-" + max_code.lower())
        try:
            reply = client.request("initialize", {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "auto-lang", "version": "0.1"},
            })
            instructions = reply.get("result", {}).get("instructions", "")
            if expected not in instructions:
                failures.append(
                    "auto language: a Max UI in {0} should give {1} instructions, got: {2}".format(
                        max_code, expected, instructions[:120]
                    )
                )
            else:
                print("auto language: Max {0} -> {1} instructions".format(max_code, bridge_language))

            # A pinned language must win over auto. Compare how the same tool is
            # rendered before and after pinning: the bilingual marker flips
            # between [English] (Chinese primary) and [中文] (English primary).
            def marker() -> str:
                listing = client.request("tools/list")
                tools = listing.get("result", {}).get("tools", [])
                description = next(
                    (t.get("description", "") for t in tools if t["name"] == "bridge_status"), ""
                )
                if "[中文]" in description:
                    return "en"
                if "[English]" in description:
                    return "zh"
                return "?"

            before = marker()
            client.request("tools/call", {"name": "set_language", "arguments": {"language": "en"}})
            client.request("tools/call", {"name": "bridge_status", "arguments": {}})
            after = marker()

            if before != bridge_language:
                failures.append(
                    "auto language: expected {0} after detecting Max {1}, got {2}".format(
                        bridge_language, max_code, before
                    )
                )
            elif after != "en":
                failures.append("a pinned set_language('en') did not override auto (ended on {0})".format(after))
            else:
                print("auto language: pinned 'en' overrode auto ({0} -> en)".format(before))
        except Exception as exc:  # noqa: BLE001
            failures.append("auto language check raised for {0}: {1}".format(max_code, exc))
        finally:
            client.close()
            bridge.stop()


def main() -> int:
    failures: List[str] = []
    bridge = MockBridge(PORT)
    bridge.start()
    time.sleep(0.3)

    client = McpClient(PORT)
    try:
        # ---------------------------------------------------------- initialize
        init = client.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "e2e-test", "version": "0.1"},
            },
        )
        info = init.get("result", {}).get("serverInfo", {})
        print("initialize -> {0} {1}, protocol {2}".format(
            info.get("name"), info.get("version"), init.get("result", {}).get("protocolVersion")
        ))
        if info.get("name") != "3dsmax-mcp":
            failures.append("unexpected serverInfo: {0}".format(info))
        client.notify("notifications/initialized")

        # ----------------------------------------------------------- tools/list
        listing = client.request("tools/list")
        tools = listing.get("result", {}).get("tools", [])
        print("tools/list -> {0} tools".format(len(tools)))
        if len(tools) < 160:
            failures.append("expected 160+ tools, got {0}".format(len(tools)))
        names = {t["name"] for t in tools}
        for expected in ("bridge_status", "create_box", "poly_extrude_faces", "export_fbx", "anim_bake"):
            if expected not in names:
                failures.append("missing tool: {0}".format(expected))
        for tool in tools:
            if not tool.get("description"):
                failures.append("tool without description: {0}".format(tool["name"]))
            if tool.get("inputSchema", {}).get("type") != "object":
                failures.append("tool without object schema: {0}".format(tool["name"]))
        # default language is Chinese, so descriptions lead with Chinese
        status = next(t for t in tools if t["name"] == "bridge_status")
        if "[English]" not in status["description"]:
            failures.append("bilingual marker missing from bridge_status description")

        # ------------------------------------------------------------- ping
        pong = client.request("ping")
        if "result" not in pong:
            failures.append("ping did not return a result")

        # ------------------------------------------------- tool call round trip
        call = client.request("tools/call", {"name": "bridge_status", "arguments": {}})
        text = tool_text(call)
        if '"running"' not in text or "true" not in text:
            failures.append("bridge_status result unexpected: {0}".format(text[:200]))
        print("tools/call bridge_status -> ok")

        # ------------------------------------- Chinese round trip end to end
        chinese = "角色_头部模型"
        call = client.request(
            "tools/call", {"name": "bridge_ping", "arguments": {}}
        )
        if "心跳正常" not in tool_text(call):
            failures.append("Chinese text did not survive the round trip on bridge_ping")

        # the mock echoes params back, so this proves the request direction too
        call = client.request(
            "tools/call",
            {"name": "create_primitive", "arguments": {"class": "Box", "name": chinese, "length": 12.5}},
        )
        text = tool_text(call)
        if chinese not in text:
            failures.append("Chinese request parameter was mangled: {0}".format(text[:300]))
        else:
            print("Chinese round trip -> {0}".format(chinese))

        # the mock records what MAXScript would have received
        echo = [c for c in bridge.calls if c["method"] == "create_primitive"]
        if echo and echo[-1]["params"].get("name") != chinese:
            failures.append("bridge received {0!r} instead of {1!r}".format(
                echo[-1]["params"].get("name"), chinese))
        if echo and echo[-1]["params"].get("length") != 12.5:
            failures.append("numeric coercion failed: {0}".format(echo[-1]["params"].get("length")))

        # ------------------------------------------------------- error paths
        call = client.request("tools/call", {"name": "no_such_tool", "arguments": {}})
        if not call.get("result", {}).get("isError"):
            failures.append("unknown tool should be reported as an error")
        else:
            print("unknown tool -> error surfaced")

        call = client.request(
            "tools/call", {"name": "execute_maxscript", "arguments": {}}
        )
        if not call.get("result", {}).get("isError"):
            failures.append("missing required parameter should be an error")
        else:
            print("missing required parameter -> error surfaced")

        call = client.request(
            "tools/call",
            {"name": "bridge_selftest", "arguments": {}},
        )
        # bridge_selftest has no required params; the mock returns its echo
        if call.get("result", {}).get("isError"):
            failures.append("bridge_selftest failed against the mock")

        # ------------------------------------------------ language switching
        call = client.request("tools/call", {"name": "set_language", "arguments": {"language": "en"}})
        if "language" not in tool_text(call):
            failures.append("set_language did not report the new language")
        listing = client.request("tools/list")
        tools_en = listing.get("result", {}).get("tools", [])
        status_en = next(t for t in tools_en if t["name"] == "bridge_status")
        if "[中文]" not in status_en["description"]:
            failures.append("after switching to English the Chinese description should be the secondary one")
        else:
            print("set_language('en') -> descriptions flipped")

        client.request("tools/call", {"name": "set_language", "arguments": {"language": "zh"}})

        # --------------------------------------------- bridge error reporting
        call = client.request(
            "tools/call", {"name": "scene_open", "arguments": {"path": "D:/项目/角色_模型.max"}}
        )
        if call.get("result", {}).get("isError"):
            message = tool_text(call)
            if "角色_模型" not in message:
                failures.append("bridge error message did not survive decoding: {0}".format(message[:200]))
            else:
                print("bridge error message preserved (incl. Chinese)")
        else:
            failures.append("a bridge error should surface as isError")

        # ----------------------------------------------------- notifications
        client.request("tools/list")  # still healthy after everything
    finally:
        client.close()
        bridge.stop()

    # ------------------------------------------------- outside the live chain
    check_config_persistence(failures)
    check_http_transport(failures)
    check_language_auto(failures)

    shutil.rmtree(TMP_ROOT, ignore_errors=True)

    if failures:
        print("\n{0} FAILURE(S):".format(len(failures)))
        for failure in failures:
            print("  x {0}".format(failure))
        return 1
    print("\nend to end: all checks passed ({0} bridge calls observed)".format(len(bridge.calls)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
