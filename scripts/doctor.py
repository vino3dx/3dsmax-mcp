"""Diagnose a 3ds Max MCP installation.

Checks every link in the chain and prints an actionable verdict:

    Python  ->  MCP server package  ->  client config  ->  bridge files  ->
    startup autoloader  ->  3ds Max running  ->  TCP port  ->  live handshake

Usage:  python scripts/doctor.py
"""

from __future__ import annotations

import glob
import json
import os
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SRC = ROOT / "src" / "python"
APP = "3dsmax-mcp"

INSTALL_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / APP
MANIFEST = INSTALL_DIR / "install-manifest.json"

OK = "  [ok]   "
WARN = "  [warn] "
FAIL = "  [FAIL] "

results: List[Tuple[str, str, str]] = []


def record(level: str, title: str, detail: str = "") -> None:
    results.append((level, title, detail))
    print("{0}{1}".format({"ok": OK, "warn": WARN, "fail": FAIL}[level], title))
    if detail:
        for line in detail.splitlines():
            print("         " + line)


def check_python() -> None:
    version = "{0}.{1}.{2}".format(*sys.version_info[:3])
    if sys.version_info >= (3, 8):
        record("ok", "Python {0} at {1}".format(version, sys.executable))
    else:
        record("fail", "Python {0} is too old".format(version), "3.8 or newer is required.")


def check_server_package() -> None:
    candidates = []
    if INSTALL_DIR.is_dir():
        candidates.append(INSTALL_DIR)
    candidates.append(SRC)

    working: Optional[Path] = None
    catalog_info = ""
    for base in candidates:
        if not (base / "maxmcp" / "server.py").is_file():
            continue
        saved = list(sys.path)
        sys.path.insert(0, str(base))
        try:
            for mod in [m for m in list(sys.modules) if m.startswith("maxmcp")]:
                del sys.modules[mod]
            from maxmcp.catalog import build_catalog  # noqa: WPS433

            catalog = build_catalog()
            categories = ", ".join("{0}={1}".format(k, v) for k, v in sorted(catalog.categories().items()))
            catalog_info = "{0} tools ({1})".format(len(catalog), categories)
            working = base
            break
        except Exception as exc:  # noqa: BLE001
            catalog_info = "import failed: {0}".format(exc)
        finally:
            sys.path[:] = saved

    if working is None:
        record("fail", "MCP server package not importable", catalog_info or "maxmcp/server.py was not found")
        return
    location = "installed" if working == INSTALL_DIR else "source tree"
    record("ok", "MCP server package ({0})".format(location), "{0}\n{1}".format(working, catalog_info))


def _unescaped_quotes(line: str) -> int:
    """Count double quotes that are not backslash escaped."""
    count = 0
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\":
            index += 2
            continue
        if char == '"':
            count += 1
        index += 1
    return count


def load_manifest() -> Dict[str, Any]:
    try:
        with MANIFEST.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def detect_max_script_dirs() -> List[Dict[str, Any]]:
    found: List[Dict[str, Any]] = []
    roots = []
    for env in ("LOCALAPPDATA", "APPDATA"):
        value = os.environ.get(env)
        if value:
            roots.append(Path(value) / "Autodesk" / "3dsMax")
    for root in roots:
        if not root.is_dir():
            continue
        for version_dir in sorted(root.glob("* - 64bit")):
            for lang_dir in sorted(version_dir.iterdir()):
                scripts = lang_dir / "scripts"
                if scripts.is_dir() and lang_dir.name.isupper():
                    found.append(
                        {
                            "year": version_dir.name.replace(" - 64bit", ""),
                            "language": lang_dir.name,
                            "scripts": scripts,
                            "startup": scripts / "startup",
                            "bridge": scripts / APP,
                        }
                    )
    return found


def check_bridge_files(dirs: List[Dict[str, Any]]) -> int:
    if not dirs:
        record("warn", "No 3ds Max user configuration folder found",
               "Launch 3ds Max once, then run scripts/install.py again.")
        return 0

    installed = 0
    for item in dirs:
        modules = sorted(item["bridge"].glob("*.ms")) if item["bridge"].is_dir() else []
        loader = item["startup"] / (APP + "-bridge.ms")
        label = "3ds Max {0} [{1}]".format(item["year"], item["language"])

        if not modules:
            record("warn", "{0}: bridge not installed".format(label),
                   "Run: python scripts/install.py")
            continue
        if not loader.is_file():
            record("warn", "{0}: autoloader missing".format(label),
                   "Expected {0}\nRun: python scripts/install.py".format(loader))
            continue

        # the autoloader must point at a file that exists
        text = loader.read_text(encoding="utf-8")
        target = ""
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("local bridgeFile = @\""):
                target = line.split('@"', 1)[1].rstrip('"')
        problem = ""
        if not target:
            problem = "could not parse the bridge path out of {0}".format(loader)
        elif not os.path.isfile(target):
            problem = "the autoloader points at {0} which does not exist".format(target)
        else:
            odd = []
            for number, line in enumerate(text.splitlines(), 1):
                code = line.split("--", 1)[0]
                if _unescaped_quotes(code) % 2:
                    odd.append(number)
            if odd:
                problem = ("unterminated string literal on line(s) {0} - MAXScript strings "
                           "cannot span lines half way".format(", ".join(str(n) for n in odd)))

        if problem:
            record("fail", "{0}: broken autoloader".format(label), problem)
        else:
            installed += 1
            record("ok", "{0}: {1} bridge modules + autoloader".format(label, len(modules)),
                   "{0}\n{1}".format(item["bridge"], loader))
    return installed


def check_ports(ports: List[int]) -> Optional[int]:
    open_port = None
    for port in ports:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.4):
                open_port = port
                break
        except OSError:
            continue
    if open_port is None:
        record("warn", "No bridge listening on {0}".format(
            ", ".join(str(p) for p in ports)),
            "Start 3ds Max. The bridge prints a banner in the MAXScript Listener.\n"
            "Manual start:  fileIn @\"...\\3dsmax-mcp\\mcp_bridge.ms\"")
    else:
        record("ok", "Bridge listening on port {0}".format(open_port))
    return open_port


def check_live(port: Optional[int]) -> None:
    if port is None:
        return
    sys.path.insert(0, str(INSTALL_DIR if (INSTALL_DIR / "maxmcp").is_dir() else SRC))
    try:
        from maxmcp.bridge import MaxBridge  # noqa: WPS433
        from maxmcp.config import Config  # noqa: WPS433

        config = Config.load()
        config.port = port
        bridge = MaxBridge(config)
        status = bridge.status()
        if not status.get("connected"):
            record("fail", "Port {0} is open but the bridge did not answer".format(port),
                   str(status.get("message", ""))[:600])
            return
        info = status.get("info") or {}
        max_version = info.get("maxVersion") if isinstance(info.get("maxVersion"), dict) else {}
        record("ok", "Live handshake succeeded",
               "handlers={0}  language={1}  3ds Max year={2}".format(
                   info.get("handlerCount"), info.get("language"), max_version.get("year", "?")))

        # Language auto-detection: the bridge reports the Max UI language it
        # found, and that is what the server mirrors in auto mode.
        detected = info.get("maxLanguage") or "(unknown)"
        pinned = info.get("languagePinned")
        record("ok", "Language: {0} from Max UI '{1}'{2}".format(
            info.get("language"), detected, " (pinned)" if pinned else " (auto)"),
               "The server follows this while its own language is 'auto'.")

        selftest = bridge.call("bridge_selftest", {"echoText": "自检_中文"})
        if isinstance(selftest, dict):
            failures = selftest.get("failures", 0)
            if failures:
                lines = [
                    "  - {0}: {1}".format(c.get("check"), c.get("detail"))
                    for c in selftest.get("checks", [])
                    if not c.get("ok")
                ]
                record("fail", "In-Max self test reported {0} failure(s)".format(failures), "\n".join(lines))
            else:
                record("ok", "In-Max self test passed ({0} checks)".format(len(selftest.get("checks", []))))
        bridge.close()
    except Exception as exc:  # noqa: BLE001
        record("fail", "Live check failed", str(exc)[:600])


def _client_registry() -> List[Tuple[str, str, Any, str]]:
    """Reuse the installer's client table so the two can never drift apart.

    Returns (client id, label, config path, top-level JSON key).
    """
    try:
        if HERE not in sys.path:
            sys.path.insert(0, str(HERE))
        from install import CLIENTS  # noqa: WPS433
        return [(key, spec["label"], spec["path"](), spec["key"]) for key, spec in CLIENTS.items()]
    except Exception:  # noqa: BLE001 - doctor must work even if install.py moves
        return [
            ("workbuddy", "WorkBuddy", Path.home() / ".workbuddy" / "mcp.json", "mcpServers"),
            ("cursor", "Cursor", Path.home() / ".cursor" / "mcp.json", "mcpServers"),
        ]


def check_clients() -> None:
    registered = 0
    missing: List[str] = []
    for client_id, name, path, key in _client_registry():
        if path is None:
            continue

        # A client that is not installed is not a problem worth reporting; only
        # mention one that exists on disk but has not been registered with yet.
        # The home directory itself does not count as evidence of installation
        # (Claude Code's config sits directly in ~).
        if not path.is_file():
            parent = path.parent
            if parent.is_dir() and parent != Path.home():
                missing.append(client_id)
            continue

        try:
            with path.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            record("fail", "{0}: config is not valid JSON".format(name), "{0}\n{1}".format(path, exc))
            continue

        servers = (data or {}).get(key) or {}
        if not isinstance(servers, dict) or APP not in servers:
            missing.append(client_id)
            continue

        entry = servers[APP] or {}
        if entry.get("url"):
            record("ok", "{0}: {1} registered (http)".format(name, APP), entry["url"])
        else:
            record("ok", "{0}: {1} registered".format(name, APP),
                   "command: {0}\nargs: {1}".format(entry.get("command"), " ".join(entry.get("args", []))))
        registered += 1

    if missing:
        record("warn", "{0} installed client(s) not registered: {1}".format(len(missing), ", ".join(missing)),
               "Register them with: python scripts/install.py --client " + " ".join(missing))
    elif registered:
        record("ok", "Registered with {0} MCP client(s)".format(registered))


def check_max_running() -> None:
    if os.name != "nt":
        return
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq 3dsmax.exe", "/NH"],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:  # noqa: BLE001
        return
    if "3dsmax.exe" in out.lower():
        record("ok", "3ds Max is running")
    else:
        record("warn", "3ds Max is not running", "Start it so the bridge can listen.")


def main() -> int:
    print("")
    print("=" * 62)
    print("  3ds Max MCP doctor")
    print("=" * 62)

    manifest = load_manifest()
    ports = [8765]
    ini_ports = []
    for item in detect_max_script_dirs():
        ini = item["bridge"] / (APP + ".ini")
        if ini.is_file():
            for line in ini.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.strip().lower().startswith("port"):
                    try:
                        ini_ports.append(int(line.split("=", 1)[1].strip()))
                    except (IndexError, ValueError):
                        pass
    for port in ini_ports:
        for candidate in range(port, port + 10):
            if candidate not in ports:
                ports.append(candidate)

    print("\n-- environment")
    check_python()
    check_server_package()

    print("\n-- 3ds Max side")
    dirs = detect_max_script_dirs()
    check_bridge_files(dirs)
    check_max_running()

    print("\n-- connectivity")
    live = check_ports(ports)
    check_live(live)

    print("\n-- MCP clients")
    check_clients()

    failures = [r for r in results if r[0] == "fail"]
    warnings = [r for r in results if r[0] == "warn"]
    print("")
    print("=" * 62)
    if failures:
        print("  {0} problem(s), {1} warning(s)".format(len(failures), len(warnings)))
        for _, title, detail in failures:
            print("   x {0}".format(title))
    elif warnings:
        print("  Everything essential is in place ({0} warning(s))".format(len(warnings)))
    else:
        print("  All checks passed")
    print("=" * 62)
    print("")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
