"""Installer for the 3ds Max MCP plugin.

Does three things, all idempotent:

1. copies the MAXScript bridge into every detected 3ds Max user script folder
   and drops a one line autoloader into its ``startup`` folder, so the bridge
   comes up with 3ds Max;
2. copies the Python MCP server into ``%LOCALAPPDATA%\\3dsmax-mcp`` so client
   configs do not depend on where this repository lives;
3. registers the server with the MCP clients you ask for (Claude Desktop,
   Cursor, or a printed snippet you can paste anywhere).

    python scripts/install.py                     # interactive, detects everything
    python scripts/install.py --client cursor     # only Cursor
    python scripts/install.py --list              # show what was detected, change nothing
    python scripts/install.py --uninstall         # remove bridge + client entries
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MAX_SRC = ROOT / "src" / "ms"
SERVER_SRC = ROOT / "src" / "python" / "maxmcp"

APP = "3dsmax-mcp"
INSTALL_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / APP
MANIFEST = INSTALL_DIR / "install-manifest.json"

SUPPORTED_YEARS = ("2020", "2021", "2022", "2023", "2024", "2025", "2026", "2027", "2028")
LANG_FOLDERS = ("ENU", "CHS", "CHT", "JPN", "KOR", "DEU", "FRA", "ESP", "ITA", "PTB", "RUS")


# --------------------------------------------------------------------- helpers
def say(text: str = "") -> None:
    print(text, flush=True)


def header(text: str) -> None:
    say("")
    say("=" * 62)
    say("  " + text)
    say("=" * 62)


def load_manifest() -> Dict[str, Any]:
    try:
        with MANIFEST.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {"bridge_dirs": [], "client_configs": [], "install_dir": str(INSTALL_DIR)}


def save_manifest(data: Dict[str, Any]) -> None:
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    with MANIFEST.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)


def copy_tree(src: Path, dst: Path, pattern: str = "*") -> int:
    """Copy files byte for byte.

    The repository is the canonical, field-tested source: ``src/ms`` holds
    exactly the bytes that run inside 3ds Max (line endings included -- the
    tree is deliberately mixed, and both shapes are proven in the field), so
    the installer must not rewrite anything on the way in.  Any normalisation
    here would silently break the "repo == deployed" invariant that
    ``test/static/registration_sync_test.py`` checks.
    """
    if not src.is_dir():
        return 0
    dst.mkdir(parents=True, exist_ok=True)
    count = 0
    for item in sorted(src.glob(pattern)):
        if not item.is_file():
            continue
        shutil.copy2(item, dst / item.name)
        count += 1
    return count


# ------------------------------------------------------------------ discovery
def detect_max_installs() -> List[Dict[str, Any]]:
    """Find every 3ds Max user configuration folder that has a scripts dir.

    This is exactly what ``getDir #userScripts`` resolves to, so anything found
    here will be scanned by Max on the next launch.
    """
    found: List[Dict[str, Any]] = []
    roots: List[Path] = []

    local = os.environ.get("LOCALAPPDATA")
    if local:
        roots.append(Path(local) / "Autodesk" / "3dsMax")
    appdata = os.environ.get("APPDATA")
    if appdata:
        roots.append(Path(appdata) / "Autodesk" / "3dsMax")

    for root in roots:
        if not root.is_dir():
            continue
        for version_dir in sorted(root.glob("* - 64bit")):
            tag = version_dir.name.replace(" - 64bit", "")
            for lang in LANG_FOLDERS:
                scripts = version_dir / lang / "scripts"
                if scripts.is_dir():
                    found.append(
                        {
                            "year": tag,
                            "language": lang,
                            "user_scripts": scripts,
                            "startup": scripts / "startup",
                            "bridge_dir": scripts / APP,
                            "product_dir": Path("C:/Program Files/Autodesk") / ("3ds Max " + tag),
                        }
                    )
    # de-duplicate by resolved user_scripts path
    seen = set()
    unique = []
    for item in found:
        key = str(item["user_scripts"]).lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique


def find_python() -> Optional[str]:
    """Locate a system Python 3 the MCP client can invoke later."""
    candidates: List[str] = []

    local = os.environ.get("LOCALAPPDATA")
    if local:
        candidates += sorted(glob.glob(os.path.join(local, "Programs", "Python", "Python3*", "python.exe")), reverse=True)
    candidates += sorted(glob.glob(r"C:\Python3*\python.exe"), reverse=True)
    candidates += sorted(glob.glob(r"C:\Program Files\Python3*\python.exe"), reverse=True)
    candidates += sorted(glob.glob(r"C:\Program Files (x86)\Python3*\python.exe"), reverse=True)

    for path in candidates:
        if os.path.isfile(path):
            return path

    # The launcher works too, it just needs "-3" as the first argument.
    launcher = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "py.exe")
    if os.path.isfile(launcher):
        return launcher
    return None


def python_invocation(python: Optional[str]) -> tuple:
    if not python:
        return (sys.executable, [])
    if os.path.basename(python).lower() == "py.exe":
        return (python, ["-3"])
    return (python, [])


# ------------------------------------------------------------------ bridge part
# Raw string: the MAXScript ``\n`` escape must reach the generated file as a
# literal backslash-n, not as a real newline (MAXScript string literals cannot
# span lines).
#
# This is the field-tested loader shape (October 2025 debugging round): it is
# deliberately independent of the bridge, because "did the autoloader even
# run?" has to be answerable when the bridge itself is what broke.  It logs to
# <temp>\3dsmax-mcp\loader.log with a userScripts fallback.
STARTUP_TEMPLATE = r"""-- {app} autoloader. Generated by scripts/install.py -- edit with care.
-- Remove this file (or run install.py --uninstall) to disable the bridge.
--
-- This loader is deliberately independent of the bridge: if the bridge itself
-- fails to load, the loader must still be able to say so.  It appends to
--     <temp>\{app}\loader.log      (primary)
--     <userScripts>\{app}\loader.log   (fallback)
-- so that "did the autoloader even run?" is answerable without the Listener.

global mcpLoaderLogPath, mcpLoaderLog, mcpLoaderBridgeFile

-- The loader has to answer "is the bridge already up?" before the bridge
-- exists, so these are declared here instead of being read as unknown
-- identifiers.
global mcpRunning, mcpListener

mcpLoaderBridgeFile = @"{bridge}"

fn mcpLoaderLogPath =
(
    local cands = #()
    try ( append cands ((getDir #temp) + "\\{app}") ) catch()
    try ( append cands ((getDir #userScripts) + "\\{app}") ) catch()

    local found = undefined
    for d in cands while found == undefined do
    (
        local ok = false
        local f = d + "\\loader.log"
        try ( makeDir d all:true ) catch()
        try ( (dotNetClass "System.IO.File").AppendAllText f ""; ok = true )
        catch ( ok = false )
        if ok do found = f
    )
    found
)

fn mcpLoaderLog msg =
(
    local text = if msg == undefined then "undefined" else (msg as string)
    format "{app}[loader] %\n" text
    local p = mcpLoaderLogPath()
    if p != undefined do
    (
        try ( (dotNetClass "System.IO.File").AppendAllText p ((timestamp() as string) + "  " + text + "\r\n") )
        catch()
    )
    ok
)

(
    local already = false
    local raised = false
    local state = "unknown"

    mcpLoaderLog "autoloader executed"

    -- Reading a global that the bridge never created must not raise here.
    try ( already = ((mcpRunning == true) and (mcpListener != undefined)) )
    catch ( already = false )

    if not (doesFileExist mcpLoaderBridgeFile) then
        mcpLoaderLog ("bridge file not found: " + mcpLoaderBridgeFile)
    else if already then
        mcpLoaderLog "bridge already running, load skipped"
    else
    (
        try ( fileIn mcpLoaderBridgeFile )
        catch ( raised = true; mcpLoaderLog ("fileIn raised: " + (getCurrentException() as string)) )

        try ( state = if mcpRunning == true then "LISTENING" else "NOT_LISTENING" ) catch ( state = "unknown" )
        mcpLoaderLog ("autoload finished: raised=" + (raised as string) + " state=" + state)
    )
)
"""

INI_TEMPLATE = """; Generated by scripts/install.py -- edits here are overwritten on reinstall.
; Change them by re-running the installer with --port / --language.
[bridge]
port={port}
; Language of messages produced inside 3ds Max.
;   auto = follow this Max installation's UI language (recommended)
;   zh   = always Simplified Chinese
;   en   = always English
language={language}
; Set to 0 to load the modules without starting the listener automatically.
autostart=1
"""


def install_bridge(installs: List[Dict[str, Any]], port: int, language: str) -> List[str]:
    touched: List[str] = []
    for item in installs:
        count = copy_tree(MAX_SRC, item["bridge_dir"], "*.ms")
        if count == 0:
            say("  ! no .ms modules found in {0}".format(MAX_SRC))
            continue

        item["startup"].mkdir(parents=True, exist_ok=True)
        loader = item["startup"] / (APP + "-bridge.ms")
        loader.write_text(
            STARTUP_TEMPLATE.format(app=APP, bridge=str(item["bridge_dir"] / "mcp_bridge.ms")),
            encoding="utf-8",
        )

        # The ini sits next to the bridge so the location is predictable, and it
        # is rewritten every time: port and language have to agree with what the
        # server and the client configs were just given, or the two sides hunt
        # on different ports.
        ini = item["bridge_dir"] / (APP + ".ini")
        ini.write_text(INI_TEMPLATE.format(port=port, language=language), encoding="utf-8")

        say("  - 3ds Max {0} ({1}): {2} modules -> {3}".format(
            item["year"], item["language"], count, item["bridge_dir"]))
        say("    autoloader: {0}".format(loader))
        touched.append(str(item["bridge_dir"]))
    return touched


def uninstall_bridge(installs: List[Dict[str, Any]], manifest: Dict[str, Any]) -> None:
    targets = {Path(p) for p in manifest.get("bridge_dirs", [])}
    targets |= {item["bridge_dir"] for item in installs}

    for bridge_dir in sorted(targets):
        scripts = bridge_dir.parent
        loader = scripts / "startup" / (APP + "-bridge.ms")
        if loader.exists():
            loader.unlink()
            say("  - removed autoloader {0}".format(loader))
        if bridge_dir.exists():
            shutil.rmtree(bridge_dir, ignore_errors=True)
            say("  - removed {0}".format(bridge_dir))


# ------------------------------------------------------------------ client part
#
# MCP is a client-side capability: the model behind the client (Claude, GLM,
# DeepSeek, Kimi, ...) is irrelevant, because the client is what mounts servers.
# So rather than special-casing vendors we just register with every MCP client
# we know how to write a config for, and print a snippet for the rest.
#
# `key` in the table is the top-level JSON key that client expects. Almost all
# of them use "mcpServers"; VS Code uses "servers" (handled separately below
# because its entry shape also differs).
CLIENTS: Dict[str, Dict[str, Any]] = {
    "workbuddy": {
        "label": "WorkBuddy",
        "path": lambda: Path.home() / ".workbuddy" / "mcp.json",
        "key": "mcpServers",
    },
    "cursor": {
        "label": "Cursor",
        "path": lambda: Path.home() / ".cursor" / "mcp.json",
        "key": "mcpServers",
    },
    "claude": {
        "label": "Claude Desktop",
        "path": lambda: (Path(os.environ["APPDATA"]) / "Claude" / "claude_desktop_config.json")
        if os.environ.get("APPDATA") else None,
        "key": "mcpServers",
    },
    "claude-code": {
        "label": "Claude Code",
        "path": lambda: Path.home() / ".claude.json",
        "key": "mcpServers",
    },
    "windsurf": {
        "label": "Windsurf",
        "path": lambda: Path.home() / ".codeium" / "windsurf" / "mcp_config.json",
        "key": "mcpServers",
    },
    "cline": {
        "label": "Cline (VS Code)",
        "path": lambda: _vscode_storage() / "saoudrizwan.claude-dev" / "settings" / "cline_mcp_settings.json",
        "key": "mcpServers",
    },
    "roo-cline": {
        "label": "Roo Code (VS Code)",
        "path": lambda: _vscode_storage() / "rooveterinaryinc.roo-cline" / "settings" / "mcp_settings.json",
        "key": "mcpServers",
    },
}

CLIENT_ALIASES: Dict[str, str] = {
    "claude-desktop": "claude",
    "roo": "roo-cline",
    "roocode": "roo-cline",
    "wb": "workbuddy",
}


def _vscode_storage() -> Path:
    appdata = os.environ.get("APPDATA") or str(Path.home())
    return Path(appdata) / "Code" / "User" / "globalStorage"


def client_config_path(name: str) -> Optional[Path]:
    spec = CLIENTS.get(CLIENT_ALIASES.get(name, name))
    if spec is None:
        return None
    return spec["path"]()


def claude_config_path() -> Optional[Path]:
    return client_config_path("claude")


def cursor_config_path() -> Path:
    return client_config_path("cursor") or (Path.home() / ".cursor" / "mcp.json")


def server_entry(python: Optional[str], port: int, language: str, profile: str) -> Dict[str, Any]:
    command, prefix = python_invocation(python)
    entry: Dict[str, Any] = {
        "command": command,
        "args": prefix + ["-m", "maxmcp", "--port", str(port), "--language", language, "--profile", profile],
        "env": {"PYTHONPATH": str(INSTALL_DIR), "MAXMCP_PORT": str(port), "MAXMCP_LANGUAGE": language},
    }
    return entry


def merge_json_config(path: Path, entry: Dict[str, Any], key: str) -> bool:
    data: Dict[str, Any] = {}
    if path.exists():
        # These files belong to other applications and live outside the project,
        # so keep a copy before the first write of each run.
        backup = path.with_suffix(path.suffix + ".bak")
        try:
            shutil.copy2(path, backup)
        except OSError:
            pass
        try:
            with path.open("r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                data = loaded
        except (OSError, ValueError):
            say("  ! {0} was not valid JSON, backed up to {1}".format(path.name, backup.name))

    servers = data.setdefault(key, {})
    if not isinstance(servers, dict):
        servers = {}
        data[key] = servers
    servers[APP] = entry

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    tmp.replace(path)
    return True


def remove_json_config(path: Path, key: str) -> bool:
    if not path.exists():
        return False
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    servers = data.get(key)
    if isinstance(servers, dict) and APP in servers:
        del servers[APP]
        with path.open("w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
        return True
    return False


def http_entry(port: int) -> Dict[str, Any]:
    """Config shape for clients that reach the server by URL.

    Cloud-side agents (智谱 BigModel, 阿里云百炼, any web console) cannot spawn a
    process on your workstation, so they are handed an HTTP endpoint instead of
    a command line. The server has to be running for this to resolve; the
    installer writes a launcher next to it.
    """
    return {
        "type": "http",
        "url": "http://127.0.0.1:{0}/mcp".format(port),
    }


def write_http_launcher(port: int, python: Optional[str]) -> Path:
    """A double-clickable way to keep the HTTP endpoint alive."""
    command, _ = python_invocation(python)
    launcher = INSTALL_DIR / "start-http.bat"
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        "@echo off\r\n"
        "rem {app} - keep the Streamable HTTP endpoint alive for URL-based clients.\r\n"
        "rem The endpoint is {url}. Leave this window open while you use it.\r\n"
        "set PYTHONPATH={install}\r\n"
        "\"{python}\" -m maxmcp --transport http --http-port {port}\r\n"
        "pause\r\n".format(
            app=APP,
            url="http://127.0.0.1:{0}/mcp".format(port),
            install=INSTALL_DIR,
            python=command,
            port=port,
        ),
        encoding="utf-8",
    )
    return launcher


def configure_clients(clients: List[str], python: Optional[str], port: int, language: str,
                      profile: str, http_port: int = 0) -> List[str]:
    written: List[str] = []
    entry = http_entry(http_port) if http_port else server_entry(python, port, language, profile)

    for client in clients:
        name = CLIENT_ALIASES.get(client, client)

        if name == "print":
            say("")
            say("  Paste this into any MCP client that takes JSON config")
            say("  (Cherry Studio, Chatbox, LobeChat, 智谱清言, DeepSeek Harness, ...):")
            say("")
            say(json.dumps({"mcpServers": {APP: entry}}, indent=2, ensure_ascii=False))
            say("")
            continue

        spec = CLIENTS.get(name)
        if spec is None:
            say("  ! unknown client: {0}".format(client))
            say("    known: {0}, print".format(", ".join(sorted(CLIENTS))))
            continue

        path = spec["path"]()
        if path is None:
            say("  ! {0}: could not resolve its config path on this machine".format(spec["label"]))
            continue

        merge_json_config(path, entry, spec["key"])
        say("  - {0}: {1}".format(spec["label"], path))
        written.append(str(path))
    return written


# ---------------------------------------------------------------------- server
def install_server() -> int:
    if not SERVER_SRC.is_dir():
        say("  ! server source not found at {0}".format(SERVER_SRC))
        return 0
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    target = INSTALL_DIR / "maxmcp"
    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(SERVER_SRC, target)
    # drop caches so a stale __pycache__ can never shadow an update
    for cache in target.rglob("__pycache__"):
        shutil.rmtree(cache, ignore_errors=True)
    count = len(list(target.rglob("*.py")))
    say("  - server: {0} python files -> {1}".format(count, target))
    return count


def uninstall_server() -> None:
    if INSTALL_DIR.exists():
        shutil.rmtree(INSTALL_DIR, ignore_errors=True)
        say("  - removed {0}".format(INSTALL_DIR))


# --------------------------------------------------------------- user config
def user_config_path() -> Path:
    """Mirror maxmcp.config so the installer and the server agree on one file."""
    home = os.environ.get("MAXMCP_HOME")
    return (Path(home) if home else Path.home() / ".{0}".format(APP)) / "config.json"


def sync_user_config(port: int, language: str, profile: str) -> Optional[Path]:
    """Align port / language / profile across the bridge .ini and the server.

    The bridge reads its port from ``3dsmax-mcp.ini`` while the server reads
    ``~/.3dsmax-mcp/config.json``. If the two disagree the server hunts on the
    wrong port and every call fails with "no bridge listening". The installer is
    the one place that knows both, so it writes the server side here.

    Only these three keys are touched; anything else the user added survives.
    """
    path = user_config_path()
    existing: Dict[str, Any] = {}
    try:
        if path.is_file():
            with path.open("r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                existing = loaded
    except (OSError, ValueError):
        existing = {}

    merged = dict(existing)
    merged.update({"port": port, "language": language, "tool_profile": profile})
    merged.setdefault("port_scan", 10)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(merged, fh, indent=2, ensure_ascii=False)
        tmp.replace(path)
    except OSError as exc:
        say("  ! could not write {0}: {1}".format(path, exc))
        return None
    say("  - server config: port={0} language={1} profile={2} -> {3}".format(
        port, language, profile, path))
    return path


# -------------------------------------------------------------------------- CLI
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="install.py",
        description="Install the 3ds Max MCP plugin (bridge + server + client config).",
    )
    parser.add_argument("--client", nargs="*", default=None,
                        choices=sorted(CLIENTS) + ["claude-desktop", "roo", "roocode", "wb", "print", "none"],
                        help="which MCP clients to configure (default: prompt)")
    parser.add_argument("--port", type=int, default=8765, help="bridge port (default 8765)")
    parser.add_argument("--language", choices=["auto", "zh", "en"], default="auto",
                        help="bridge language: auto follows the 3ds Max UI language (default auto)")
    parser.add_argument("--profile", default="full",
                        choices=["full", "core", "modeling", "lookdev", "animation", "pipeline"],
                        help="how many tools to advertise (default full: all 384)")
    parser.add_argument("--http-port", type=int, default=0,
                        help="also register a Streamable HTTP endpoint on this port. "
                             "Needed by cloud-side agents that cannot launch a local process. "
                             "The client config then points at http://127.0.0.1:<port>/mcp "
                             "instead of a command line.")
    parser.add_argument("--list", action="store_true", help="report detection results and exit")
    parser.add_argument("--uninstall", action="store_true", help="remove the bridge and client entries")
    parser.add_argument("--yes", action="store_true", help="do not ask anything")
    args = parser.parse_args(argv)

    installs = detect_max_installs()
    python = find_python()
    manifest = load_manifest()

    header("{0} installer".format(APP))

    if args.list:
        say("3ds Max installations found: {0}".format(len(installs)))
        for item in installs:
            say("  - {0} [{1}]".format(item["year"], item["language"]))
            say("      scripts : {0}".format(item["user_scripts"]))
            say("      startup : {0}".format(item["startup"]))
            product = item.get("product_dir")
            if product and product.is_dir():
                say("      program : {0}".format(product))
        say("")
        say("Python for the MCP server: {0}".format(python or "(not found, will use {0})".format(sys.executable)))
        say("Server install dir       : {0}".format(INSTALL_DIR))
        say("")
        say("MCP client configs:")
        for key in sorted(CLIENTS):
            spec = CLIENTS[key]
            path = spec["path"]()
            if path is None:
                say("  {0:<16} path unknown on this machine".format(spec["label"]))
                continue
            state = "found" if path.exists() else "not present"
            say("  {0:<16} {1:<12} {2}".format(spec["label"], state, path))
        return 0

    if args.uninstall:
        say("Removing the bridge from 3ds Max...")
        uninstall_bridge(installs, manifest)
        say("Removing client entries...")
        for key in sorted(CLIENTS):
            spec = CLIENTS[key]
            path = spec["path"]()
            if path and remove_json_config(path, spec["key"]):
                say("  - cleaned {0}".format(path))
        say("Removing the server...")
        uninstall_server()
        say("")
        say("Done. Restart 3ds Max and your AI client.")
        return 0

    # ------------------------------------------------------------- detection
    if not installs:
        say("! No 3ds Max user configuration folder was found.")
        say("  Launch 3ds Max once so it creates one, then run this again.")
        say("  You can still install the server only, with --client.")
    else:
        say("Found {0} 3ds Max installation(s):".format(len(installs)))
        for item in installs:
            say("  - 3ds Max {0} [{1}]".format(item["year"], item["language"]))
    say("Python for the server: {0}".format(python or sys.executable))

    clients = args.client
    if clients is None:
        detected = [key for key in sorted(CLIENTS) if (CLIENTS[key]["path"]() or Path("/nonexistent")).exists()]
        if args.yes:
            clients = detected + [k for k in ("claude", "cursor") if k not in detected]
        else:
            say("")
            say("Detected MCP clients: {0}".format(", ".join(detected) if detected else "(none)"))
            say("Which MCP clients should be configured?")
            say("  1) every client detected on this machine")
            say("  2) {0}".format(detected[0] if detected else "workbuddy"))
            say("  3) WorkBuddy + Cursor + Claude Desktop")
            say("  4) just print the JSON snippet (for anything else)")
            try:
                choice = input("  choice [1]: ").strip() or "1"
            except EOFError:
                choice = "1"
            clients = {
                "1": detected,
                "2": [detected[0]] if detected else ["workbuddy"],
                "3": ["workbuddy", "cursor", "claude"],
                "4": ["print"],
            }.get(choice, detected)

    if clients == ["none"]:
        clients = []

    # -------------------------------------------------------------- install
    header("Installing the MAXScript bridge")
    if installs:
        manifest["bridge_dirs"] = install_bridge(installs, args.port, args.language)
    else:
        say("  (skipped: no 3ds Max found)")

    header("Installing the MCP server")
    install_server()
    sync_user_config(args.port, args.language, args.profile)

    if args.http_port:
        header("Preparing the HTTP endpoint")
        say("  Streamable HTTP : http://127.0.0.1:{0}/mcp".format(args.http_port))
        say("  legacy SSE      : http://127.0.0.1:{0}/sse".format(args.http_port))
        say("  health probe    : http://127.0.0.1:{0}/health".format(args.http_port))
        launcher = write_http_launcher(args.http_port, python)
        say("  launcher        : {0}".format(launcher))
        say("  ! Run that launcher (or the command inside it) and leave it open.")
        say("    URL-based clients cannot start a process on this machine.")

    if clients:
        header("Configuring MCP clients")
        manifest["client_configs"] = configure_clients(
            clients, python, args.port, args.language, args.profile, args.http_port
        )

    save_manifest(manifest)

    header("Next steps")
    say("  1. Close 3ds Max completely, then start it again.")
    say("     The bridge prints a banner in the MAXScript Listener when it is up.")
    say("  2. Restart your AI client so it picks up the new MCP server.")
    say("  3. Ask the model to run  bridge_status  and then  bridge_selftest .")
    say("")
    say("  Bridge folder : {0}".format(installs[0]["bridge_dir"] if installs else "(none)"))
    say("  Server folder : {0}".format(INSTALL_DIR))
    if str(args.language) == "auto":
        say("  Language      : auto (follows the 3ds Max UI language)")
    else:
        say("  Language      : {0} (pinned)".format(args.language))
    say("                  switch at runtime with the set_language tool, incl. \"auto\"")
    say("  Tool profile  : {0}".format(args.profile))
    say("")
    say("  If something fails: python scripts/doctor.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
