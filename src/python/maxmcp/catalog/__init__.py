"""Tool catalog aggregation.

Tool definitions live in per-area modules so each source file carries a rich,
cohesive domain surface:

    core.py       bridge / system, scene session, files, introspection, context
    objects.py    primitives, splines, transforms, hierarchy, selection, placement
    modeling.py   editable poly editing, modifier stack, spline-driven geometry
    shading.py    materials, maps, UVW, lights, cameras, environment
    animation.py  keyframes, controllers, constraints, bones, skin, IK, morph
    pipeline.py   rendering, vision feedback, texture baking, export/import
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
