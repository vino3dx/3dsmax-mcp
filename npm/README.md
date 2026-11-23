# vino-3dsmax-mcp

Lightweight npm launcher for the Python `3dsmax-mcp` MCP server. The launcher
does not reimplement MCP or MaxScript; it finds Python and starts
`python -m maxmcp` with stdin/stdout inherited.

```bash
npx -y vino-3dsmax-mcp
```

The default Python dependency is pinned to the verified PyPI release
`vino3dx-3dsmax-mcp==0.1.0`. The launcher verifies the installed distribution
metadata before reuse, so an unrelated package that happens to expose a `maxmcp`
module is not treated as this project. Local source mode is supported through
`MAXMCP_PYTHONPATH`. Diagnostics and pip output go to stderr; MCP stdout
is reserved for protocol traffic.

Environment variables:

- `MAXMCP_PYTHON`: explicit Python executable.
- `MAXMCP_PYTHON_PACKAGE_VERSION`: override this project's Python distribution version.
- `MAXMCP_SKIP_INSTALL=1`: fail instead of installing a missing package.
- `MAXMCP_PYTHONPATH`: prepend a local source tree for development.

The launcher does not start or control 3ds Max. The Python server and its
existing bridge configuration remain responsible for that connection.
