"use strict";

const assert = require("node:assert");
const { execFileSync, spawnSync } = require("node:child_process");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");
const launcher = path.join(root, "npm", "bin", "3dsmax-mcp.js");
const pythonPath = path.join(root, "src", "python");

function run(args, extraEnv = {}, input = undefined) {
  return spawnSync(process.execPath, [launcher, ...args], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, MAXMCP_PYTHONPATH: pythonPath, ...extraEnv },
    input,
  });
}

assert.doesNotThrow(() => execFileSync(process.execPath, ["--check", launcher]));

const help = run(["--help"]);
assert.strictEqual(help.status, 0);
assert.match(help.stdout, /Usage:/);
assert.match(help.stderr, /starting Python MCP server/);
assert.ok(!help.stdout.includes("[3dsmax-mcp]"));

const version = run(["--version"]);
assert.strictEqual(version.status, 0);
assert.match(version.stdout, /^3dsmax-mcp /);

const protocol = run(["--no-stdio"], { MAXMCP_PYTHON: "python" },
  JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
    protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" },
  } }) + "\n");
// The server may exit cleanly or after EOF depending on the Python runtime;
// the important contract is that the JSON-RPC reply is on stdout only.
assert.match(protocol.stdout, /"jsonrpc"/);
assert.ok(!protocol.stdout.includes("[3dsmax-mcp]"));

const missing = run(["--help"], {
  MAXMCP_PYTHON: path.join(root, "npm", "test", "does-not-exist-python.exe"),
  MAXMCP_SKIP_INSTALL: "1",
});
assert.notStrictEqual(missing.status, 0);
assert.match(missing.stderr, /Python 3 was not found/);

const noInstall = run(["--help"], {
  MAXMCP_PYTHONPATH: path.join(root, "npm", "test", "missing-python-path"),
  MAXMCP_SKIP_INSTALL: "1",
});
assert.notStrictEqual(noInstall.status, 0);
assert.match(noInstall.stderr, /Python package .* is not installed/);

console.log("npm launcher tests: all checks passed");
