# @vino3dx/3dsmax-mcp

Lightweight npm launcher for the Python `3dsmax-mcp` MCP server. The launcher
does not reimplement MCP or MaxScript; it finds Python and starts
`python -m maxmcp` with stdin/stdout inherited.

```bash
npx -y @vino3dx/3dsmax-mcp
```

The default Python dependency is pinned to the verified PyPI release
`3dsmax-mcp==1.6.8`. Installation happens only when the `maxmcp` Python module
is not already importable. Diagnostics and pip output go to stderr; MCP stdout
is reserved for protocol traffic.

Environment variables:

- `MAXMCP_PYTHON`: explicit Python executable.
- `MAXMCP_PYTHON_PACKAGE_VERSION`: override the pinned Python package version.
- `MAXMCP_PYTHON_PACKAGE`: override the Python distribution name.
- `MAXMCP_SKIP_INSTALL=1`: fail instead of installing a missing package.
- `MAXMCP_PYTHONPATH`: prepend a local source tree for development.

The launcher does not start or control 3ds Max. The Python server and its
existing bridge configuration remain responsible for that connection.
