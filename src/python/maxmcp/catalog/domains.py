"""Which scene-context domains a tool invalidates.

This module is the **declaration** side of the context ledger.  Until now the
dispatcher inferred "did this write anything?" from the *undo* flag, which is a
different question: 49 registered commands change the scene without being
undoable (``render_set_*``, ``render_element_*``, ``bake_*``, ``poly_select``,
``set_time_config``, ``set_units``, ``export_*``, ``viewport_*`` ...).  Those
writes reached the scene but never reached the ledger, so ``context_get(since:)``
kept serving a snapshot that no longer matched Max.  That is the failure mode
this table exists to remove.

Rules
-----
* ``mutates`` is declared per tool, expressed as a tuple of domain names.
* ``()`` is a *declaration*, not a blank: "this tool changes nothing the nine
  context domains describe" (viewport state, files on disk, bridge config).
* ``None`` from :func:`domains_for` means **undeclared**.  The dispatcher falls
  back to the legacy prefix heuristic so a half-installed bridge keeps working,
  and ``test/static/tool_domain_contract_test.py`` fails the build so it is
  never the state we ship.
* The undo flag is never consulted.  ``undoable`` answers "can the user take
  this back?", ``mutates`` answers "does the scene snapshot go stale?".
* A field that lives in a *different* domain from the tool's name prefix is
  declared in :data:`CROSS_DOMAIN_FIELDS` and asserted by the contract test, so
  the mapping is a reviewable fact instead of an inference (``select_*`` moves
  ``scene.selectionCount``; ``mat_assign`` changes ``selection[].material``).

The same table is compiled into ``src/ms/mcp_domains.ms`` by
``scripts/gen_tool_domains.py``; that file is what the dispatcher reads at run
time.  Regenerate it with ``python scripts/gen_tool_domains.py`` and check it
with ``python scripts/gen_tool_domains.py --check``.
"""

from __future__ import annotations

from typing import Dict, Optional, Tuple

#: The nine domains ``mcp_context.ms`` builds.  Order is the wire order.
DOMAIN_NAMES: Tuple[str, ...] = (
    "scene",
    "selection",
    "objects",
    "materials",
    "assets",
    "animation",
    "rigging",
    "render",
    "project",
)

KNOWN_DOMAINS = frozenset(DOMAIN_NAMES)

#: Everything.  Only for tools that can genuinely touch anything.
ALL_DOMAINS: Tuple[str, ...] = DOMAIN_NAMES

#: Object-level edits: the object list, its counts and the selection rows.
OBJECTS: Tuple[str, ...] = ("objects", "selection")

#: Anything that adds, removes or renames objects also moves scene.objectCount
#: and (for layers) layerCount / currentLayer.
OBJECTS_AND_SCENE: Tuple[str, ...] = ("scene", "objects", "selection")

#: Moving, selecting or creating a selection also moves scene.selectionCount.
#: This is F4's first confirmed mismatch: `select_*` used to declare `selection`
#: alone, so `scene.selectionCount` kept the value it had when the scene section
#: was last built while `selection.count` moved on the very next call.
SELECTION_AND_SCENE: Tuple[str, ...] = ("scene", "selection")


# ------------------------------------------------------------- field ownership
#: Cross-domain fields: which domain *owns* the field, and which tool families
#: write it.  Recorded here because the prefix heuristic cannot express it -- a
#: tool named `select_*` moves a number that lives in the `scene` section, and a
#: name-prefix table cannot say so.
#:
#: ``test/static/tool_domain_contract_test.py`` walks this table and fails when
#: a listed writer does not declare the owning domain, so the next tool added to
#: one of these families cannot silently reintroduce the mismatch.
#:
#: This is the "explicit category and targets" step for the mappings that are
#: *confirmed*; the rest of the prefix table is unchanged on purpose.
CROSS_DOMAIN_FIELDS: Dict[str, Dict[str, object]] = {
    # field path -> owner domain + the tools known to write it
    "scene.selectionCount": {
        "owner": "scene",
        "writers": (
            "select_objects", "select_all", "select_by_superclass", "deselect_all",
        ),
        "readers": ("get_selection",),
    },
    "selection[].material": {
        "owner": "selection",
        # Only the three that actually change a selected node's material (or the
        # name the row prints): assign swaps the material, delete clears it,
        # rename changes the string.  mat_duplicate / mat_set_property touch a
        # material no selection row points at.
        "writers": ("mat_assign", "mat_delete", "mat_rename"),
        "readers": ("mat_get_for_object",),
    },
    "scene.systemUnits / scene.unitScale": {
        "owner": "scene",
        "writers": ("set_units",),
        "readers": ("get_units",),
    },
    "animation.frameRate / startFrame / endFrame": {
        "owner": "animation",
        "writers": ("set_time_config",),
        "readers": ("get_time_config",),
    },
    "scene.currentFrame": {
        "owner": "scene",
        "writers": ("anim_goto_frame", "anim_play", "anim_play_preview"),
        "readers": ("anim_get_frame",),
    },
}



# --------------------------------------------------------------------- prefixes
#: Longest matching prefix wins (``render_element`` beats ``render``).  A prefix
#: matches either the whole name or ``prefix + "_"``, so ``urn`` never matches
#: ``urn_field`` by accident.
PREFIX_MUTATES: Dict[str, Tuple[str, ...]] = {
    # -- escape hatches: arbitrary code can touch everything --------------------
    "execute": ALL_DOMAINS,

    # -- scene session ---------------------------------------------------------
    # new / open / reset / merge replace the whole scene, so every domain is
    # stale, including render settings that came from the opened file.
    "scene": ALL_DOMAINS,
    "file": ("scene", "project", "assets"),
    "units": ("scene",),
    "time": ("scene", "animation", "render"),
    "unit": ("scene",),

    # -- objects ---------------------------------------------------------------
    # scene is listed wherever the *count of objects* moves, because
    # mcpCtxBuildScene publishes objectCount and layerCount.  F4's confirmed
    # mismatch was scene.selectionCount; objectCount is the same field in the
    # same section, so the same rule applies to every family that adds or
    # removes nodes.
    "create": OBJECTS_AND_SCENE,
    "delete": ("scene", "objects", "selection", "assets"),
    "clone": OBJECTS_AND_SCENE,
    "array": OBJECTS_AND_SCENE,
    "attach": OBJECTS_AND_SCENE,
    "detach": OBJECTS_AND_SCENE,
    "boolean": OBJECTS_AND_SCENE,
    "proboolean": OBJECTS_AND_SCENE,
    "collapse": OBJECTS,
    "convert": OBJECTS,
    "group": OBJECTS_AND_SCENE,
    "ungroup": OBJECTS_AND_SCENE,
    "open": OBJECTS,
    "close": OBJECTS,
    "parent": OBJECTS,
    "unparent": OBJECTS,
    "rename": OBJECTS,
    "layer": OBJECTS,
    "assign": OBJECTS,
    "move": OBJECTS,
    "transform": OBJECTS,
    "mirror": OBJECTS,
    "snap": OBJECTS,
    "scatter": OBJECTS_AND_SCENE,
    "align": ("objects", "selection"),
    "reset": OBJECTS,
    "hide": OBJECTS,
    "unhide": OBJECTS,
    "freeze": OBJECTS,
    "unfreeze": OBJECTS,
    # A selection change is not an object change: the objects domain holds
    # counts and classification, neither of which moves when you click.  It is a
    # *scene* change though -- scene.selectionCount is published there.
    "select": SELECTION_AND_SCENE,
    "deselect": SELECTION_AND_SCENE,

    # -- modelling -------------------------------------------------------------
    "mod": OBJECTS,
    "poly": OBJECTS,
    # model_* (extrude / lathe / loft / sweep) produces a new object.
    "model": OBJECTS_AND_SCENE,
    "spline": OBJECTS,
    "uvw": OBJECTS,

    # -- shading ---------------------------------------------------------------
    # mat_* writes can introduce a BitmapTexture, which shows up in the assets
    # domain's file list, not only in materials.
    "mat": ("materials", "assets"),
    "map": ("materials", "assets"),
    "tex": ("materials", "assets"),
    "bake": ("materials", "assets"),
    "relink": ("assets", "materials"),
    "asset": ("assets",),
    "env": ("render", "materials"),

    # -- animation / rigging ---------------------------------------------------
    "anim": ("animation",),
    "key": ("animation",),
    "track": ("animation",),
    # ctrl_set_value moves a controller, which is also a transform change.
    "ctrl": ("animation", "objects", "selection"),
    "rig": ("rigging", "objects", "selection"),
    "skin": ("rigging",),
    "bone": ("rigging", "objects"),
    "biped": ("rigging", "objects"),
    "constraint": ("rigging", "objects", "selection"),

    # -- lighting / rendering --------------------------------------------------
    "light": ("objects", "render", "selection"),
    "cam": ("objects", "render", "selection"),
    # render_run settings do not move the project domain: project holds the
    # scene path, project folder and xrefs.  Declaring project here made every
    # render-set call invalidate it for nothing.
    "render": ("render",),
    # Explicit second entry on purpose: the requirement is that an element
    # edit invalidates render and nothing else.
    "render_element": ("render",),
    "import": ("scene", "objects", "selection", "materials", "assets", "project"),
    "export": ("project", "assets"),

    # -- undo / redo -----------------------------------------------------------
    # These fire #sceneUndo / #sceneRedo as well; declaring them is what keeps
    # the ledger correct on a build where that notification failed to bind.
    "undo": ("objects", "selection", "materials", "assets", "animation", "rigging"),
    "redo": ("objects", "selection", "materials", "assets", "animation", "rigging"),

    # -- outside the ledger ----------------------------------------------------
    # Declared empty: they change the viewport, the file system or the bridge,
    # none of which any context domain describes.  Recording them would bump
    # the revision the client uses as `since` for nothing.
    "viewport": (),
    "vision": (),
    "write": (),
    "make": (),
    "hold": (),
    "release": (),
    "begin": (),
    "end": (),
    "cancel": (),
    "bridge": (),
    "client": (),
    "context": (),
    "copy": (),
    "get": (),
    "list": (),
    "find": (),
    "count": (),
    "does": (),
    "read": (),
    "fetch": (),
    "set": OBJECTS,
}


# ------------------------------------------------------------------ overrides
#: Per-tool declarations.  Consulted before the prefix table, so these win.
TOOL_MUTATES: Dict[str, Tuple[str, ...]] = {
    # -- filesystem writes with no scene effect --------------------------------
    "write_text_file": (),
    "make_directory": (),
    # Bakes render to disk; the element list itself is untouched.
    "bake_set_output": (),
    # Writes a preset file, does not change the current render settings.
    "render_save_preset": (),
    # Grabs an image of the viewport; the viewport is not a context domain.
    "viewport_capture": (),
    "viewport_capture_all": (),
    "vision_capture": (),
    "vision_preview": (),
    # Saving flips scene.modified (mcpCtxBuildScene reads it) and can change the
    # project folder when the file has never been saved.
    "scene_save": ("scene", "project"),
    # fetchMaxFile() restores a held snapshot: every domain is stale, not just
    # the ones the hold happened to touch.
    "fetch_scene": ALL_DOMAINS,

    # -- file operations that can invalidate the asset existence view ----------
    "copy_file": ("assets",),
    "delete_file": ("assets",),

    # -- configuration writes --------------------------------------------------
    "set_units": ("scene",),
    # Frame rate and range live in scene, animation and render at once.
    "set_time_config": ("scene", "animation", "render"),
    "set_pivot": OBJECTS,
    "set_layer_properties": OBJECTS,
    # Arbitrary property on an arbitrary object, material or controller.
    "set_property_value": ALL_DOMAINS,

    # -- single-domain writes that share a writing prefix ----------------------
    "poly_select": ("selection",),
    "poly_select_faces": ("selection",),
    "poly_loop_select": ("selection",),
    "poly_ring_select": ("selection",),
    # These four move the object selection, which the scene section reports as
    # selectionCount (F4).  poly_* moves sub-object selection and leaves it
    # alone, which is why they stay on `selection` only.
    "deselect_all": SELECTION_AND_SCENE,
    "select_objects": SELECTION_AND_SCENE,
    "select_all": SELECTION_AND_SCENE,
    "select_by_superclass": SELECTION_AND_SCENE,
    # Assigning a material also changes the selection rows' material column.
    "mat_assign": ("materials", "assets", "selection"),
    "mat_delete": ("materials", "assets", "selection"),
    # Renaming a material changes the name every selection row prints.
    "mat_rename": ("materials", "assets", "selection"),
    "export_selection": ("project", "assets"),
    # Moving the time slider changes scene.currentFrame, which the scene section
    # publishes next to the animation section's identical field.
    "anim_goto_frame": ("scene", "animation"),
    "anim_play": ("scene", "animation"),
    "anim_play_preview": ("scene", "animation"),
}


def domains_for(name: str) -> Optional[Tuple[str, ...]]:
    """Declared domains for a tool name, or ``None`` when undeclared.

    ``None`` is a build error, not a runtime answer: the contract test refuses
    to pass while any non-read-only tool lacks a declaration.
    """
    key = (name or "").strip().lower()
    if not key:
        return None
    if key in TOOL_MUTATES:
        return TOOL_MUTATES[key]
    best: Optional[str] = None
    for prefix in PREFIX_MUTATES:
        if key == prefix or key.startswith(prefix + "_"):
            if best is None or len(prefix) > len(best):
                best = prefix
    if best is None:
        return None
    return PREFIX_MUTATES[best]


def is_known_domains(domains) -> bool:
    return all(d in KNOWN_DOMAINS for d in domains)
