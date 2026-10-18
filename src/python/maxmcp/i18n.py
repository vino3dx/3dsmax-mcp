"""Bilingual (English / Chinese) message layer for the MCP server.

Two languages are supported: ``en`` and ``zh``. Tool *descriptions* are always
declared bilingually in the catalog; this module handles the runtime strings the
server itself emits, plus the helper that renders a catalog description into the
currently selected language.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Tuple

LANGUAGES: Tuple[str, ...] = ("zh", "en")
LANGUAGE_NAMES: Dict[str, str] = {"zh": "简体中文", "en": "English"}

#: Sentinel meaning "follow whatever the running 3ds Max is set to".
AUTO = "auto"

#: 3ds Max localisation folder -> the language we serve. Max ships one folder per
#: UI language under the user configuration directory, and both Chinese variants
#: are served with our Simplified Chinese strings (Traditional readers get
#: Simplified, which is far closer than falling back to English).
MAX_LANGUAGE_MAP: Dict[str, str] = {
    "CHS": "zh",   # Simplified Chinese
    "CHT": "zh",   # Traditional Chinese
    "ENU": "en",   # English (US)
    "ENA": "en",   # English (legacy code)
    "ENG": "en",
    "JPN": "en",   # Japanese  - no Japanese strings, serve English
    "KOR": "en",
    "DEU": "en",
    "FRA": "en",
    "ESP": "en",
    "ITA": "en",
    "PTB": "en",
    "RUS": "en",
    "PLK": "en",
    "CSY": "en",
    "BRA": "en",
    "CHT_": "zh",
}

#: Languages a client may explicitly request.
EXPLICIT_LANGUAGES: Tuple[str, ...] = LANGUAGES + (AUTO,)

# key -> (zh, en)
MESSAGES: Dict[str, Tuple[str, str]] = {
    "server.ready": (
        "3ds Max MCP 服务已就绪（MCP 版本 {version}）。",
        "3ds Max MCP server ready (MCP version {version}).",
    ),
    "server.language_changed": (
        "语言已切换为简体中文。",
        "Language switched to English.",
    ),
    "server.language_invalid": (
        "不支持的语言：{value}。可选值：zh、en。",
        "Unsupported language: {value}. Allowed: zh, en.",
    ),
    "bridge.not_running": (
        "未连接到 3ds Max。请确认：\n"
        "1) 3ds Max 已启动；\n"
        "2) 桥接已加载（在 MaxScript 侦听器中运行 {bridge_script}，或安装到启动脚本目录后重启 Max）；\n"
        "3) 端口 {port} 未被占用。\n"
        "当前尝试的主机/端口：{host}:{port}。",
        "Not connected to 3ds Max. Please check:\n"
        "1) 3ds Max is running;\n"
        "2) the bridge is loaded (run {bridge_script} in the MAXScript listener, or install it into the "
        "startup scripts folder and restart Max);\n"
        "3) port {port} is free.\n"
        "Tried: {host}:{port}.",
    ),
    "bridge.timeout": (
        "3ds Max 在 {timeout} 秒内未返回结果（命令：{method}）。"
        "如果正在渲染或烘焙，请调大 MAXMCP_TIMEOUT。",
        "3ds Max did not answer within {timeout}s (command: {method}). "
        "Increase MAXMCP_TIMEOUT for long renders or bakes.",
    ),
    "bridge.disconnected": (
        "与 3ds Max 的连接已断开，将在下次调用时重连。",
        "Connection to 3ds Max was lost; it will be re-established on the next call.",
    ),
    "bridge.protocol_error": (
        "桥接返回了无法解析的数据：{detail}",
        "The bridge returned unparsable data: {detail}",
    ),
    "bridge.command_failed": (
        "命令执行失败：{detail}",
        "Command failed: {detail}",
    ),
    "tool.unknown": (
        "未知工具：{name}。可用工具请调用 tools/list。",
        "Unknown tool: {name}. Call tools/list for the available set.",
    ),
    "tool.bad_arguments": (
        "参数不合法：{detail}",
        "Invalid arguments: {detail}",
    ),
    "env.language_help": (
        "当前语言：{current}。使用 set_language 传入 \"zh\" 或 \"en\" 进行切换，"
        "传入 \"auto\" 则跟随 3ds Max 的界面语言。",
        "Current language: {current}. Call set_language with \"zh\" or \"en\" to pin it, "
        "or \"auto\" to follow the 3ds Max UI language.",
    ),
    "language.auto_detected": (
        "已根据 3ds Max 的界面语言（{code}）自动切换为{name}。",
        "Switched to {name} automatically, following the 3ds Max UI language ({code}).",
    ),
    "language.auto_pending": (
        "语言设为自动：3ds Max 尚未运行，暂时使用{name}；连接成功后会跟随 Max 的语言。",
        "Language is set to auto: 3ds Max is not running yet, using {name} for now; "
        "it will follow Max once connected.",
    ),
    "language.pinned": (
        "语言已固定为{name}，不再跟随 3ds Max 的界面语言。",
        "Language pinned to {name}; it will no longer follow the 3ds Max UI language.",
    ),
}


def normalize(language: Any) -> str:
    """Map user input to ``zh``/``en``, or ``""`` when it is not a language."""
    value = str(language or "").strip().lower()
    if value.startswith("zh") or value in ("cn", "chinese", "中文", "简体中文", "汉语"):
        return "zh"
    if value.startswith("en") or value in ("english", "英文", "英语"):
        return "en"
    return ""


def is_auto(language: Any) -> bool:
    """True when the value asks the server to follow 3ds Max's own language."""
    return str(language or "").strip().lower() in (
        "auto", "follow", "max", "default", "自动", "跟随", "跟随max", "跟随 max",
    )


def parse_preference(value: Any) -> str:
    """Normalise a configured language into ``auto``, ``zh``, ``en`` or ``""``."""
    if is_auto(value):
        return AUTO
    return normalize(value)


def from_max_code(code: Any, fallback: str = "zh") -> str:
    """Translate a 3ds Max localisation folder name into a served language.

    Accepts ``CHS``, ``ENU``, ``chinese``-style explicit names, and anything
    else that :func:`normalize` already understands.
    """
    raw = str(code or "").strip()
    if not raw:
        return fallback if fallback in LANGUAGES else "zh"
    explicit = normalize(raw)
    if explicit:
        return explicit
    mapped = MAX_LANGUAGE_MAP.get(raw.upper())
    if mapped:
        return mapped
    return fallback if fallback in LANGUAGES else "zh"


def resolve(configured: Any, detected: Optional[Any], fallback: str = "zh") -> str:
    """Work out which language to serve.

    ``configured`` may be ``auto`` (follow Max), a fixed language, or empty.
    ``detected`` is whatever the bridge reported, or None when Max is unreachable.
    """
    if is_auto(configured) or not configured:
        if detected:
            return from_max_code(detected, fallback)
        return fallback if fallback in LANGUAGES else "zh"
    return normalize(configured) or fallback


def t(key: str, language: str = "zh", **kwargs: Any) -> str:
    """Look up a runtime message in ``language`` and format it."""
    pair = MESSAGES.get(key)
    if pair is None:
        return key
    lang = language if language in LANGUAGES else "zh"
    text = pair[0] if lang == "zh" else pair[1]
    if kwargs:
        try:
            return text.format(**kwargs)
        except (KeyError, IndexError):
            return text
    return text


def render_description(entry: Any, language: str, bilingual: bool = True) -> str:
    """Render a catalog entry's description for the active language.

    ``entry`` is expected to expose ``description_zh`` / ``description_en``.
    When ``bilingual`` is on, the other language is appended after a separator so
    the model can still resolve the tool if it was prompted in the other tongue.
    """
    lang = language if language in LANGUAGES else "zh"
    primary = (getattr(entry, "description_zh" if lang == "zh" else "description_en", "") or "").strip()
    other = (getattr(entry, "description_en" if lang == "zh" else "description_zh", "") or "").strip()
    if not bilingual or not other or other == primary:
        return primary
    marker = "[English]" if lang == "zh" else "[中文]"
    return "{primary}\n{marker}\n{other}".format(primary=primary, marker=marker, other=other)


def render_param_description(zh: str, en: str) -> str:
    """Parameter descriptions are kept bilingual inline (compact + unambiguous)."""
    zh = (zh or "").strip()
    en = (en or "").strip()
    if not zh and not en:
        return ""
    if not en or en == zh:
        return zh
    if not zh:
        return en
    return "{zh} | {en}".format(zh=zh, en=en)
