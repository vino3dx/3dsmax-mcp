#!/usr/bin/env node

"use strict";

const { spawnSync, spawn } = require("node:child_process");

const PACKAGE_NAME = "vino3dx-3dsmax-mcp";
const PACKAGE_VERSION = process.env.MAXMCP_PYTHON_PACKAGE_VERSION || "0.1.0";
const PACKAGE_SPEC = `${PACKAGE_NAME}==${PACKAGE_VERSION}`;

function diagnostic(message) {
  process.stderr.write(`[3dsmax-mcp] ${message}\n`);
}

function fail(message, code = 1) {
  diagnostic(`error: ${message}`);
  process.exitCode = code;
  return false;
}

function runChecked(command, args) {
  return spawnSync(command, args, {
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "utf8",
    windowsHide: true,
  });
}

function findPython() {
  const configured = process.env.MAXMCP_PYTHON || process.env.PYTHON;
  const candidates = configured ? [configured] : (process.platform === "win32"
    ? ["python", "py"]
    : ["python3", "python"]);
  for (const candidate of candidates) {
    const args = candidate === "py" ? ["-3", "--version"] : ["--version"];
    const result = runChecked(candidate, args);
    if (result.status === 0) {
      const version = (result.stdout || result.stderr || "").trim().replace(/\s+/g, " ");
      return { command: candidate, prefix: candidate === "py" ? ["-3"] : [], version };
    }
  }
  return null;
}

function packageInstalled(python) {
  const code = [
    "import importlib.util, os",
    "from importlib.metadata import PackageNotFoundError, version",
    "try:",
    "    installed = version('vino3dx-3dsmax-mcp') == " + JSON.stringify(PACKAGE_VERSION)",
    "except PackageNotFoundError:",
    "    installed = False",
    "spec = importlib.util.find_spec('maxmcp')",
    "source_mode = False",
    "roots = [os.path.realpath(p) for p in os.environ.get('MAXMCP_PYTHONPATH', '').split(os.pathsep) if p]",
    "if spec and spec.origin and roots:",
    "    actual = os.path.realpath(spec.origin)",
    "    for root in roots:",
    "        try:",
    "            if os.path.commonpath([actual, root]) == root:",
    "                source_mode = True",
    "                break",
    "        except ValueError:",
    "            pass",
    "raise SystemExit(0 if installed or source_mode else 1)",
  ].join("\n");
  const env = { ...process.env };
  if (process.env.MAXMCP_PYTHONPATH) env.PYTHONPATH = process.env.MAXMCP_PYTHONPATH;
  const result = spawnSync(python.command, [...python.prefix, "-c", code], {
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "utf8",
    windowsHide: true,
    env,
  });
  return result.status === 0;
}

function installPackage(python) {
  if (process.env.MAXMCP_SKIP_INSTALL === "1") {
    return fail(`Python package ${PACKAGE_SPEC} is not installed; MAXMCP_SKIP_INSTALL=1 prevents installation`);
  }
  diagnostic(`Python package not found; installing ${PACKAGE_SPEC} with pip --user`);
  const result = spawnSync(python.command, [...python.prefix, "-m", "pip", "install", "--user", "--upgrade", PACKAGE_SPEC], {
    stdio: "inherit",
    windowsHide: true,
  });
  if (result.status !== 0) {
    return fail(`pip installation failed for ${PACKAGE_SPEC}`, result.status || 1);
  }
  return true;
}

function main() {
  const python = findPython();
  if (!python) {
    return fail("Python 3 was not found. Install Python 3.8+ or set MAXMCP_PYTHON to its executable.");
  }
  if (!packageInstalled(python) && !installPackage(python)) {
    return false;
  }

  diagnostic(`starting Python MCP server with ${python.version}`);
  const childEnv = { ...process.env };
  if (process.env.MAXMCP_PYTHONPATH) {
    childEnv.PYTHONPATH = process.env.MAXMCP_PYTHONPATH;
  }
  const child = spawn(python.command, [...python.prefix, "-m", "maxmcp", ...process.argv.slice(2)], {
    stdio: "inherit",
    env: childEnv,
    windowsHide: true,
  });

  let forwarding = false;
  const forward = (signal) => {
    if (forwarding || child.exitCode !== null) return;
    forwarding = true;
    try { child.kill(signal); } catch (_) { /* child may have exited */ }
  };
  process.once("SIGINT", () => forward("SIGINT"));
  process.once("SIGTERM", () => forward("SIGTERM"));
  child.on("error", (error) => fail(`could not start Python MCP server: ${error.message}`));
  child.on("exit", (code, signal) => {
    if (signal) process.exitCode = 128 + (signal === "SIGINT" ? 2 : 15);
    else process.exitCode = code === null ? 1 : code;
  });
}

main();
