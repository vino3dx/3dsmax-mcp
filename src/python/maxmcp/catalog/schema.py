"""Compact DSL for declaring MCP tool schemas.

Every tool carries a Chinese and an English description; parameter descriptions
are stored bilingually and rendered inline (``中文 | English``) so that a model
prompted in either language can still resolve the argument correctly.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence

from .. import i18n


@dataclass
class Tool:
    name: str
    category: str
    description_zh: str
    description_en: str
    schema: Dict[str, Any] = field(default_factory=dict)
    bridge: Optional[str] = None
    #: when True the bridge call is flagged as destructive/mutating
    mutating: bool = True
    #: optional preset merged into the arguments before the call
    preset: Dict[str, Any] = field(default_factory=dict)

    @property
    def bridge_method(self) -> str:
        return self.bridge or self.name

    def to_mcp(self, language: str, bilingual: bool = True) -> Dict[str, Any]:
        description = i18n.render_description(self, language, bilingual)
        # i18n.render_description reads attributes via getattr on zh/en pairs
        return {
            "name": self.name,
            "description": description,
            "inputSchema": self.schema,
        }


# --------------------------------------------------------------- property DSL
def _prop(type_name: str, zh: str, en: str, **extra: Any) -> Dict[str, Any]:
    desc = i18n.render_param_description(zh, en)
    prop: Dict[str, Any] = {"type": type_name}
    if desc:
        prop["description"] = desc
    for key, value in extra.items():
        if value is not None:
            prop[key] = value
    return prop


def s(zh: str, en: str, default: Any = None, enum: Optional[Sequence[str]] = None,
      examples: Optional[Sequence[str]] = None) -> Dict[str, Any]:
    return _prop("string", zh, en, default=default, enum=list(enum) if enum else None,
                 examples=list(examples) if examples else None)


def n(zh: str, en: str, default: Any = None, minimum: Optional[float] = None,
      maximum: Optional[float] = None) -> Dict[str, Any]:
    return _prop("number", zh, en, default=default, minimum=minimum, maximum=maximum)


def i(zh: str, en: str, default: Any = None, minimum: Optional[float] = None,
      maximum: Optional[float] = None) -> Dict[str, Any]:
    return _prop("integer", zh, en, default=default, minimum=minimum, maximum=maximum)


def b(zh: str, en: str, default: Any = None) -> Dict[str, Any]:
    return _prop("boolean", zh, en, default=default)


def arr(zh: str, en: str, items: str = "string", default: Any = None) -> Dict[str, Any]:
    return _prop("array", zh, en, items={"type": items}, default=default)


def num3(zh: str, en: str, default: Any = None) -> Dict[str, Any]:
    return _prop("array", zh, en, items={"type": "number"}, minItems=3, maxItems=3, default=default)


def obj_schema(name: str = "object", desc_zh: str = "", desc_en: str = "") -> Dict[str, Any]:
    return _prop("object", desc_zh, desc_en)


def tool(
    name: str,
    category: str,
    zh: str,
    en: str,
    props: Optional[Dict[str, Any]] = None,
    required: Optional[Sequence[str]] = None,
    bridge: Optional[str] = None,
    mutating: bool = True,
    preset: Optional[Dict[str, Any]] = None,
) -> Tool:
    properties = props or {}
    schema: Dict[str, Any] = {"type": "object", "properties": properties}
    if required:
        schema["required"] = list(required)
    schema["additionalProperties"] = False
    return Tool(
        name=name,
        category=category,
        description_zh=zh.strip(),
        description_en=en.strip(),
        schema=schema,
        bridge=bridge,
        mutating=mutating,
        preset=preset or {},
    )


# ------------------------------------------------------------------ registry
#: Categories every profile keeps: connection, scene management, object
#: handling, file IO and introspection.
BASE_CATEGORIES = ("system", "scene", "objects", "files")

#: Named subsets, so a client does not have to carry all 375 tool descriptions.
PROFILES: Dict[str, Optional[set]] = {
    "full": None,
    "core": set(BASE_CATEGORIES),
    "modeling": set(BASE_CATEGORIES) | {"modeling"},
    "lookdev": set(BASE_CATEGORIES) | {"shading"},
    "animation": set(BASE_CATEGORIES) | {"animation"},
    "pipeline": set(BASE_CATEGORIES) | {"pipeline"},
}


class Catalog:
    """Holds every declared tool and exposes lookup helpers."""

    def __init__(self) -> None:
        self._tools: Dict[str, Tool] = {}
        self._order: List[str] = []

    def add(self, *tools: Tool) -> None:
        for entry in tools:
            if entry.name in self._tools:
                raise ValueError("duplicate tool name: {0}".format(entry.name))
            self._tools[entry.name] = entry
            self._order.append(entry.name)

    def add_all(self, tools: Sequence[Tool]) -> None:
        self.add(*tools)

    def get(self, name: str) -> Optional[Tool]:
        return self._tools.get(name)

    def names(self) -> List[str]:
        return list(self._order)

    def __len__(self) -> int:
        return len(self._tools)

    def __iter__(self):
        for name in self._order:
            yield self._tools[name]

    def categories(self) -> Dict[str, int]:
        stats: Dict[str, int] = {}
        for entry in self:
            stats[entry.category] = stats.get(entry.category, 0) + 1
        return stats

    def to_mcp(self, language: str, bilingual: bool = True,
               profile: str = "full", disabled_categories: Sequence[str] = ()) -> List[Dict[str, Any]]:
        allowed = PROFILES.get(profile, None) if profile != "full" else None
        blocked = set(disabled_categories)
        out: List[Dict[str, Any]] = []
        for entry in self:
            if allowed is not None and entry.category not in allowed:
                continue
            if entry.category in blocked:
                continue
            item = entry.to_mcp(language, bilingual)
            item["annotations"] = {
                "title": entry.name,
                "readOnlyHint": not entry.mutating,
                "destructiveHint": entry.mutating,
            }
            out.append(item)
        return out

    def profile_summary(self, profile: str) -> Dict[str, int]:
        allowed = PROFILES.get(profile, None) if profile != "full" else None
        stats: Dict[str, int] = {}
        for entry in self:
            if allowed is not None and entry.category not in allowed:
                continue
            stats[entry.category] = stats.get(entry.category, 0) + 1
        return stats
