"""3ds Max MCP server.

Drives Autodesk 3ds Max from any MCP capable AI client (GPT, Claude, Cursor, ...)
through an MCP plugin that works on 3ds Max 2020 and every later release.
"""

from .config import APP_NAME, VERSION, PROTOCOL_VERSION, Config

__all__ = ["APP_NAME", "VERSION", "PROTOCOL_VERSION", "Config", "__version__"]
__version__ = VERSION
