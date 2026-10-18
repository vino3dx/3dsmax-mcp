"""Tool catalog aggregation.

Tool definitions live in per-area modules so the catalog stays readable:

    core.py       bridge / system, scene session, files, introspection
    objects.py    primitives, splines, transforms, hierarchy, selection
    modeling.py   editable poly editing and modifiers
    shading.py    materials, maps, UVW, lights, cameras, environment
    animation.py  keyframes, controllers, constraints, bones, skin, IK
    pipeline.py   rendering, texture baking, export/import to game engines
"""

from __future__ import annotations

import importlib

from .schema import Catalog, Tool, arr, b, i, n, num3, s, tool

MODULE_NAMES = ("core", "objects", "modeling", "shading", "animation", "pipeline")

__all__ = ["Catalog", "Tool", "build_catalog", "MODULE_NAMES", "tool", "s", "n", "i", "b", "arr", "num3"]


def build_catalog() -> Catalog:
    """Import every catalog module and merge the tools into one registry."""
    catalog = Catalog()
    for name in MODULE_NAMES:
        try:
            module = importlib.import_module("." + name, __package__)
        except ImportError:
            continue
        catalog.add_all(getattr(module, "TOOLS", []))
    return catalog
