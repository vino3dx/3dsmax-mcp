"""Static consistency check: Python catalog <-> MAXScript registry <-> deployed trees.

No 3ds Max instance required.

Checks:
  1. every tool's bridge method is registered by some mcp_*.ms file in src/ms
     (preset-based tools resolve to their `bridge` override, e.g. mod_chamfer -> mod_add)
  2. every command registered on the MAXScript side exists in the Python catalog
  3. every module file in src/ms is listed in mcp_bridge.ms's module list
     (and every listed module exists on disk)
  4. the deployed ENU/CHS script trees (if present) are byte-identical to each
     other AND to src/ms -- the repo is the canonical source, deployment is
     byte-exact, so any drift is a bug

Usage:  python registration_sync_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "src", "python"))

MS_DIR = os.path.join(REPO, "src", "ms")
ENU_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""),
    "Autodesk", "3dsMax", "2020 - 64bit", "ENU", "scripts", "3dsmax-mcp",
)
CHS_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""),
    "Autodesk", "3dsMax", "2020 - 64bit", "CHS", "scripts", "3dsmax-mcp",
)

REGISTER_RE = re.compile(r'mcpRegister\s+"([A-Za-z0-9_]+)"')
LOADER_RE = re.compile(r'"([A-Za-z0-9_]+\.ms)"')


def md5(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


def ms_files(directory: str) -> set:
    if not os.path.isdir(directory):
        return set()
    return {f for f in os.listdir(directory) if f.endswith(".ms")}


def registered_commands(directory: str) -> set:
    commands = set()
    for name in sorted(ms_files(directory)):
        text = open(os.path.join(directory, name), encoding="utf-8", errors="replace").read()
        commands.update(REGISTER_RE.findall(text))
    return commands


def main() -> int:
    from maxmcp.catalog import build_catalog

    problems = []
    catalog = build_catalog()

    repo_files = ms_files(MS_DIR)
    if not repo_files:
        print("src/ms not found; cannot verify")
        return 2

    repo_cmds = registered_commands(MS_DIR)

    # 1. python -> maxscript
    missing = []
    for entry in catalog:
        method = entry.bridge_method
        if method not in repo_cmds:
            missing.append((entry.name, method))
    if missing:
        problems.append("tools whose bridge method is not registered on the MAXScript side: %s"
                        % ", ".join("%s->%s" % m for m in missing[:20]))

    # 2. maxscript -> python
    orphans = sorted(repo_cmds - {e.bridge_method for e in catalog})
    if orphans:
        problems.append("MAXScript commands with no Python tool: %s" % ", ".join(orphans[:20]))

    # 3. module load list: every module on disk is loaded, every loaded module exists
    bridge_path = os.path.join(MS_DIR, "mcp_bridge.ms")
    if not os.path.isfile(bridge_path):
        problems.append("src/ms/mcp_bridge.ms is missing")
    else:
        loader = open(bridge_path, encoding="utf-8", errors="replace").read()
        listed = set(LOADER_RE.findall(loader))
        absent = sorted(listed - repo_files)
        unlisted = sorted(repo_files - listed - {"mcp_bridge.ms"})
        if absent:
            problems.append("mcp_bridge.ms loads missing file(s): %s" % ", ".join(absent))
        if unlisted:
            problems.append("module(s) on disk but not loaded by mcp_bridge.ms: %s" % ", ".join(unlisted))

    # 4. deployed trees: ENU == CHS == repo (byte-exact deployment)
    drift = []
    for label, deployed in (("ENU", ENU_DIR), ("CHS", CHS_DIR)):
        if not os.path.isdir(deployed):
            continue
        dep_files = ms_files(deployed)
        if dep_files != repo_files:
            drift.append("%s file set differs (repo-only=%s deployed-only=%s)"
                         % (label, sorted(repo_files - dep_files), sorted(dep_files - repo_files)))
        for f in sorted(repo_files & dep_files):
            if md5(os.path.join(MS_DIR, f)) != md5(os.path.join(deployed, f)):
                drift.append("%s: %s differs from src/ms" % (label, f))
    if drift:
        problems.append("deployed tree drifted from the repo (edit src/ms and re-run install.py): %s"
                        % "; ".join(drift[:10]))

    print("=== registration sync ===")
    print("python tools          : %d" % len(catalog))
    print("maxscript commands    : %d" % len(repo_cmds))
    print("repo script files     : %d" % len(repo_files))
    for cmd in ("mod_toggle", "mod_collapse", "mod_chamfer", "poly_get_selection", "poly_select",
                "poly_get_elements", "vision_capture", "vision_views", "vision_preview"):
        entry = catalog.get(cmd)
        if entry is not None:
            print("  %-20s -> bridge %-12s registered=%s"
                  % (cmd, entry.bridge_method, entry.bridge_method in repo_cmds))
    if problems:
        print("\n%d problem(s):" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1
    print("\nall consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
