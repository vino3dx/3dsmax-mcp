"""Configuration for the 3ds Max MCP server.

Precedence (highest first):
    1. Environment variables
    2. User config file  (~/.3dsmax-mcp/config.json)
    3. Built-in defaults
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

APP_NAME = "3dsmax-mcp"
VERSION = "1.0.0"
PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

CONFIG_DIR = Path(os.environ.get("MAXMCP_HOME") or (Path.home() / ".3dsmax-mcp"))
CONFIG_PATH = CONFIG_DIR / "config.json"

DEFAULTS: Dict[str, Any] = {
    "host": "127.0.0.1",
    "port": 8765,
    "port_scan": 10,
    "timeout_s": 120.0,
    "connect_timeout_s": 2.0,
    # "auto" follows the UI language of the running 3ds Max; pin "zh" or "en"
    # to stop following and always serve that language.
    "language": "auto",
    "bilingual": True,
    "auto_launch_hint": True,
    "max_response_chars": 200000,
    "tool_profile": "full",
    # Transport. stdio is what a locally launched client uses; http adds a
    # Streamable HTTP endpoint plus the legacy HTTP+SSE pair so cloud-side
    # agents can reach the server by URL.
    "transport": "stdio",
    "http_host": "127.0.0.1",
    "http_port": 8770,
    "http_token": "",
    "http_path": "/mcp",
}


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 8765
    port_scan: int = 10
    timeout_s: float = 120.0
    connect_timeout_s: float = 2.0
    language: str = "zh"
    bilingual: bool = True
    auto_launch_hint: bool = True
    max_response_chars: int = 200000
    tool_profile: str = "full"
    disabled_categories: List[str] = field(default_factory=list)
    transport: str = "stdio"
    http_host: str = "127.0.0.1"
    http_port: int = 8770
    http_token: str = ""
    http_path: str = "/mcp"

    # ---------------------------------------------------------------- language
    @property
    def effective_language(self) -> str:
        """A concrete language to render with.

        ``language`` may legitimately be ``auto``, which only the running server
        can resolve (by asking the bridge). Everything that just needs something
        to render with - --list-tools, --selftest-python, doctor - uses this.
        """
        value = str(self.language or "").strip().lower()
        if value in ("zh", "en"):
            return value
        return "zh"

    @property
    def language_is_auto(self) -> bool:
        value = str(self.language or "").strip().lower()
        return value in ("", "auto", "follow", "max", "default", "自动", "跟随", "跟随max", "跟随 max")

    # ---------------------------------------------------------------- loading
    @classmethod
    def load(cls) -> "Config":
        raw: Dict[str, Any] = dict(DEFAULTS)
        try:
            if CONFIG_PATH.is_file():
                with CONFIG_PATH.open("r", encoding="utf-8") as fh:
                    user = json.load(fh)
                if isinstance(user, dict):
                    raw.update({k: v for k, v in user.items() if k in DEFAULTS or k == "disabled_categories"})
        except (OSError, ValueError):
            pass

        env_map = {
            "MAXMCP_HOST": ("host", str),
            "MAXMCP_PORT": ("port", int),
            "MAXMCP_TIMEOUT": ("timeout_s", float),
            "MAXMCP_LANGUAGE": ("language", str),
            "MAXMCP_BILINGUAL": ("bilingual", _as_bool),
            "MAXMCP_PROFILE": ("tool_profile", str),
            "MAXMCP_TRANSPORT": ("transport", str),
            "MAXMCP_HTTP_HOST": ("http_host", str),
            "MAXMCP_HTTP_PORT": ("http_port", int),
            "MAXMCP_HTTP_TOKEN": ("http_token", str),
            "MAXMCP_HTTP_PATH": ("http_path", str),
        }
        for env_key, (field_name, caster) in env_map.items():
            value = os.environ.get(env_key)
            if value is None or value == "":
                continue
            try:
                raw[field_name] = caster(value)
            except (TypeError, ValueError):
                pass

        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        cfg = cls(**{k: v for k, v in raw.items() if k in known})
        cfg.language = cfg.language.lower().strip() if isinstance(cfg.language, str) else "auto"
        # Anything that is not a real language and not the auto sentinel is
        # treated as auto: following Max is a better guess than forcing Chinese.
        if cfg.language not in ("zh", "en") and not cfg.language_is_auto:
            cfg.language = "auto"
        if cfg.language_is_auto:
            cfg.language = "auto"
        return cfg

    def save(self, keys: Optional[Iterable[str]] = None) -> None:
        """Persist the config.

        ``keys`` restricts what is written. This matters because the server
        accepts run-scoped overrides on the command line (``--port``,
        ``--profile``); saving the *whole* config would silently bake those
        throwaway values into the user's file and desync the server from the
        bridge on the next launch. Callers that only mean to persist one
        preference - ``set_language`` - pass that key explicitly.
        """
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {k: v for k, v in asdict(self).items()}
        if keys is not None:
            allowed = set(keys)
            data = {k: v for k, v in data.items() if k in allowed}
        existing: Dict[str, Any] = {}
        try:
            if CONFIG_PATH.is_file():
                with CONFIG_PATH.open("r", encoding="utf-8") as fh:
                    loaded = json.load(fh)
                if isinstance(loaded, dict):
                    existing = loaded
        except (OSError, ValueError):
            existing = {}
        existing.update(data)
        tmp = CONFIG_PATH.with_suffix(".json.tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(existing, fh, indent=2, ensure_ascii=False)
        tmp.replace(CONFIG_PATH)

    @property
    def candidate_ports(self) -> List[int]:
        return [self.port + i for i in range(max(1, self.port_scan))]


def _as_bool(value: str) -> bool:
    return str(value).strip().lower() in ("1", "true", "yes", "on", "y")
