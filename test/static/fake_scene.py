"""A small, honest stand-in for the 3ds Max bridge.

It implements the handful of bridge commands the batch/verification layer uses,
against an in-memory scene, and it fails the way the real handlers fail: unknown
names raise ``BridgeCommandError`` with ``kind="err.node_not_found"``, transport
problems raise ``BridgeNotRunning`` / ``BridgeTimeout``.

This is deliberately *not* a mock of the Python layer: every method below
corresponds to a real MAXScript handler (``find_objects``, ``get_object_info``,
``transform_object``, ``delete_objects``, ``clone_objects``, ``select_objects``,
``mat_assign``, ``mod_add``), and it mutates its own state so read-back
verification is exercised for real - only Max itself is missing.

Stage 3 added the handlers the workflow layer needs (``list_objects``, the
``create_*`` primitives, ``convert_to_editable_poly``, ``poly_*``,
``mat_create_standard`` / ``mat_list`` / ``mat_get_for_object``,
``rename_object`` and ``vision_capture``).  They follow the same rule: the
signature and the reply shape follow the MAXScript handler, and the state change
is real inside this object, so a workflow can be executed and verified offline
without ever claiming a 3ds Max result.

Stage 4 added the organisation and file handlers (``create_layer`` /
``list_layers`` / ``assign_to_layer`` / ``group_objects`` / ``ungroup_objects`` /
``scene_save_as`` / ``export_fbx``) and made ``rename_object`` match Max's real
behaviour: a name collision does **not** raise, it silently keeps the old name
and reports ``renamed: false``.  The stub is deliberately not kinder than Max,
because a stub that is easier to satisfy makes the tests lie.
"""

from __future__ import annotations

import base64
import copy
import math
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.bridge import BridgeCommandError, BridgeNotRunning, BridgeTimeout  # noqa: E402

#: ``create_*`` catalog entries -> the class the MAXScript handler instantiates.
PRIMITIVE_CLASSES: Dict[str, str] = {
    "create_box": "Box",
    "create_plane": "Plane",
    "create_sphere": "Sphere",
    "create_cylinder": "Cylinder",
    "create_cone": "Cone",
    "create_teapot": "Teapot",
    "create_torus": "Torus",
    "create_tube": "Tube",
    "create_pyramid": "Pyramid",
    "create_geosphere": "GeoSphere",
    "create_line": "Line",
    "create_rectangle": "Rectangle",
    "create_circle": "Circle",
    "create_ngon": "NGon",
    "create_ellipse": "Ellipse",
    "create_arc": "Arc",
    "create_donut": "Donut",
    "create_helix": "Helix",
    "create_capsule": "Capsule",
    "create_chamferbox": "ChamferBox",
    "create_text": "Text",
}

#: Classes whose real superclass is Shape rather than Geometry.  attach only
#: works on these, so the stub has to know which is which.
SHAPE_CLASSES = {
    "Line", "SplineShape", "Circle", "Rectangle", "Ellipse", "NGon",
    "Donut", "Arc", "Helix", "Text",
}

#: Smallest possible valid PNG header + payload; enough for the server's sniff.
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def _coerce(value: Any) -> Any:
    """Mirror mcpCoerceValue: mod_set_param takes its value as a string."""
    if not isinstance(value, str):
        return value
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    try:
        return float(value)
    except ValueError:
        return value


def _sync_bounds(node: Dict[str, Any]) -> Dict[str, Any]:
    """Compute world AABB ``boundingBox`` from position, dimensions and scale."""
    pos = [float(x) for x in (node.get("position") or [0.0, 0.0, 0.0])]
    scale = [float(x) for x in (node.get("scale") or [1.0, 1.0, 1.0])]
    klass = str(node.get("class") or "Box")
    if klass in ("Plane",):
        w = float(node.get("width") if node.get("width") is not None else 100.0) * abs(scale[0])
        l = float(node.get("length") if node.get("length") is not None else 100.0) * abs(scale[1])
        bmin = [pos[0] - w * 0.5, pos[1] - l * 0.5, pos[2]]
        bmax = [pos[0] + w * 0.5, pos[1] + l * 0.5, pos[2]]
    elif klass in ("Sphere", "GeoSphere"):
        r = float(node.get("radius") if node.get("radius") is not None else 10.0)
        rx, ry, rz = r * abs(scale[0]), r * abs(scale[1]), r * abs(scale[2])
        bmin = [pos[0] - rx, pos[1] - ry, pos[2] - rz]
        bmax = [pos[0] + rx, pos[1] + ry, pos[2] + rz]
    else:
        r = node.get("radius")
        default_xy = float(r) * 2.0 if isinstance(r, (int, float)) else 20.0
        w = float(node.get("width") if node.get("width") is not None else default_xy) * abs(scale[0])
        l = float(node.get("length") if node.get("length") is not None else default_xy) * abs(scale[1])
        h = float(node.get("height") if node.get("height") is not None else 20.0) * abs(scale[2])
        # Centered pivot along Z when center_pivot is set, otherwise base-pivot (Max Box/Cylinder default)
        if node.get("center_pivot"):
            bmin = [pos[0] - w * 0.5, pos[1] - l * 0.5, pos[2] - h * 0.5]
            bmax = [pos[0] + w * 0.5, pos[1] + l * 0.5, pos[2] + h * 0.5]
        else:
            bmin = [pos[0] - w * 0.5, pos[1] - l * 0.5, pos[2]]
            bmax = [pos[0] + w * 0.5, pos[1] + l * 0.5, pos[2] + h]
    node["boundingBox"] = {
        "min": bmin,
        "max": bmax,
        "size": [bmax[0] - bmin[0], bmax[1] - bmin[1], bmax[2] - bmin[2]],
    }
    return node


def _node(name: str, handle: int, klass: str = "Box") -> Dict[str, Any]:
    return {
        "name": name,
        "handle": handle,
        "class": klass,
        "baseClass": klass,
        "superClass": "GeometryClass",
        "position": [0.0, 0.0, 0.0],
        "rotation": [0.0, 0.0, 0.0],
        "scale": [1.0, 1.0, 1.0],
        "isHidden": False,
        "isFrozen": False,
        "parent": "",
        "childCount": 0,
        "material": "",
        "layer": "0",
        "modifiers": [],
        "vertexCount": 8,
        "faceCount": 6,
    }


class FakeScene:
    def __init__(self) -> None:
        self.nodes: Dict[str, List[Dict[str, Any]]] = {}
        self.selection: List[str] = []
        self.calls: List[str] = []
        self.materials: Dict[str, Dict[str, Any]] = {}
        #: per-object face selection kept between poly_select_faces/extrude
        self.selected_faces: Dict[str, List[int]] = {}
        #: layer name -> its properties; Max always starts with layer "0"
        self.layers: Dict[str, Dict[str, Any]] = {
            "0": {"name": "0", "hidden": False, "frozen": False, "wireColor": None},
        }
        #: group name -> member names
        self.groups: Dict[str, List[str]] = {}
        #: last path handed to scene_save_as / export_fbx (no bytes are written)
        self.saved_path = ""
        self.exported_path = ""
        #: paths that already exist, so the overwrite guard can be exercised
        self.existing_files: set = set()
        self._handle = 100
        #: names Max will refuse to delete (simulates a locked/referenced node)
        self.undeletable: set = set()
        #: names the material/modifier handlers will silently skip
        self.skip_assign: set = set()
        #: names that refuse state changes (locked nodes), so partial success and
        #: honest failure lists can be exercised offline
        self.reject_ops: set = set()
        #: dimension properties the scene silently keeps instead of the request
        self.clamp_props: Dict[str, float] = {}
        #: modifier properties the scene refuses to change (read-back mismatch)
        self.clamp_mod_props: Dict[str, float] = {}
        #: when True, the boolean sequence completes but nothing is consumed
        self.boolean_noop = False
        #: when True, polyops return without changing the topology
        self.poly_noop = False
        #: session settings scene_new may keep (units, frame rate, render size)
        self.session: Dict[str, Any] = {
            "units": "in", "scale": 1.0, "frameRate": 30,
            "resolution": [1280, 720],
        }
        #: set to a transport exception to make the next call fail at that layer
        self.transport_failure: Optional[BaseException] = None
        #: when True, transform_object silently ignores the request (no change)
        self.ignore_transform = False
        #: when True, delete_objects returns success without deleting
        self.fake_delete = False
        #: when True, vision_capture returns a result with no image bytes
        self.vision_without_image = False
        #: raise ``transport_failure`` once this many calls have been served
        #: (``None`` = never).  Lets a test kill the bridge mid-workflow.
        self.fail_after: Optional[int] = None

    # ------------------------------------------------------------------ helpers
    def add(self, name: str, klass: str = "Box", position: Optional[List[float]] = None) -> Dict[str, Any]:
        self._handle += 1
        node = _node(name, self._handle, klass)
        if klass in SHAPE_CLASSES:
            node["superClass"] = "ShapeClass"
            node["vertexCount"] = 0
            node["faceCount"] = 0
            node["splines"] = 1
        if position:
            node["position"] = list(position)
        _sync_bounds(node)
        self.nodes.setdefault(name, []).append(node)
        return node

    def node(self, name: str) -> Optional[Dict[str, Any]]:
        entries = self.nodes.get(name) or []
        return entries[0] if entries else None

    def _find(self, name: str) -> List[Dict[str, Any]]:
        return list(self.nodes.get(name) or [])

    def _require(self, name: str) -> Dict[str, Any]:
        found = self._find(name)
        if not found:
            raise BridgeCommandError(
                "Object not found: {0}".format(name),
                detail={"kind": "err.node_not_found", "message": "Object not found: {0}".format(name)},
            )
        return found[0]

    # ------------------------------------------------------------------- bridge
    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        self.calls.append(method)
        if self.transport_failure is not None:
            # fail_after=None keeps the old behaviour: every call fails.
            if self.fail_after is None or len(self.calls) > self.fail_after:
                raise self.transport_failure
        params = params or {}
        handler = getattr(self, "_h_" + method, None)
        if handler is not None:
            return handler(params)
        primitive = PRIMITIVE_CLASSES.get(method)
        if primitive is not None:
            return self._create(dict(params, **{"class": params.get("class") or primitive}))
        raise BridgeCommandError(
            "Unknown command: {0}".format(method),
            detail={"kind": "err.unknown_method", "message": method},
        )

    # ---------------------------------------------------------------- handlers
    def _h_bridge_status(self, params):
        return {"running": True, "language": "en", "maxLanguage": "ENU", "handlerCount": 353}

    def _h_scene_info(self, params):
        return {"objectCount": sum(len(v) for v in self.nodes.values()), "objects": 0}

    def _h_find_objects(self, params):
        name = params.get("name") or ""
        pattern = params.get("pattern") or ""
        exact = params.get("exact") is True
        matched: List[Dict[str, Any]] = []
        for key, entries in self.nodes.items():
            if exact and key == name:
                matched.extend(entries)
            elif not exact and pattern and self._glob(key, pattern):
                matched.extend(entries)
        return {"count": len(matched), "objects": [copy.deepcopy(_sync_bounds(node)) for node in matched]}

    @staticmethod
    def _glob(text: str, pattern: str) -> bool:
        import fnmatch
        return fnmatch.fnmatchcase(text, pattern)

    def _h_get_object_info(self, params):
        return copy.deepcopy(_sync_bounds(self._require(str(params.get("name") or ""))))

    def _targets(self, params) -> List[str]:
        """Mirror ``mcpResolveNodes ... fallbackToSelection:true``."""
        names = [str(n) for n in params.get("objects") or []]
        return names if names else list(self.selection)

    def _h_transform_object(self, params):
        value = list(params.get("value") or [0, 0, 0])
        operation = params.get("operation") or "move"
        mode = params.get("mode") or "relative"
        for name in self._targets(params):
            node = self._require(name)
            if self.ignore_transform:
                continue
            if operation == "move":
                node["position"] = (value if mode == "absolute"
                                    else [a + b for a, b in zip(node["position"], value)])
            elif operation == "scale":
                node["scale"] = (value if mode == "absolute"
                                 else [a * b for a, b in zip(node["scale"], value)])
            elif operation == "rotate":
                node["rotation"] = (value if mode == "absolute"
                                    else [a + b for a, b in zip(node["rotation"], value)])
        return {"message": "Done."}

    def _h_delete_objects(self, params):
        deleted: List[str] = []
        for name in params.get("objects") or []:
            self._require(name)
            if name in self.undeletable or self.fake_delete:
                continue
            self.nodes.pop(name, None)
            deleted.append(name)
        return {"deleted": deleted, "message": "Done."}

    def _h_clone_objects(self, params):
        created: List[str] = []
        failures: List[str] = []
        count = int(params.get("count") or 1)
        clone_type = params.get("cloneType") or "copy"
        for name in params.get("objects") or []:
            source = self._require(name)
            for index in range(count):
                if name in self.reject_ops:
                    # A locked source refuses the copy; the handler names the
                    # attempt instead of reporting the request as created.
                    failures.append("{0} #{1}: copy returned no node".format(name, index + 1))
                    continue
                clone_name = "{0}_clone{1}".format(name, index + 1)
                self._handle += 1
                clone = copy.deepcopy(source)
                clone["name"] = clone_name
                clone["handle"] = self._handle
                self.nodes.setdefault(clone_name, []).append(clone)
                created.append(clone_name)
        return {"created": created, "count": len(created), "failures": failures,
                "cloneType": clone_type, "message": "Created."}

    def _h_select_objects(self, params):
        mode = params.get("mode") or "replace"
        names = [str(n) for n in params.get("objects") or [] if str(n) in self.nodes]
        if mode == "replace":
            self.selection = list(names)
        elif mode == "add":
            self.selection = sorted(set(self.selection) | set(names))
        elif mode == "subtract":
            self.selection = [n for n in self.selection if n not in names]
        elif mode == "invert":
            self.selection = [n for n in self.nodes if n not in self.selection]
        return self._selection_info()

    def _h_get_selection(self, params):
        return self._selection_info()

    def _selection_info(self) -> Dict[str, Any]:
        infos = []
        for name in self.selection:
            node = self.node(name)
            if node:
                infos.append(copy.deepcopy(node))
        return {"count": len(infos), "objects": infos}

    def _h_mat_assign(self, params):
        material = str(params.get("material") or "")
        applied: List[str] = []
        for name in params.get("objects") or []:
            node = self._require(name)
            if name in self.skip_assign:
                continue
            node["material"] = material
            applied.append(name)
        return {"material": material, "applied": applied, "message": "Done."}

    def _h_mod_add(self, params):
        modifier = str(params.get("modifier") or "")
        applied: List[str] = []
        failures: List[str] = []
        reserved = {"objects", "modifier", "name", "params", "undo", "undo_label"}
        extra = {k: v for k, v in params.items() if k not in reserved}
        for key in (params.get("params") or {}):
            extra[key] = (params.get("params") or {})[key]
        for name in params.get("objects") or []:
            node = self._require(name)
            if name in self.skip_assign or name in self.reject_ops:
                failures.append("{0}: modifier rejected".format(name))
                continue
            node["modifiers"] = list(node["modifiers"]) + [modifier]
            # Mirror the handler: a parameter the modifier refuses makes the
            # whole object a failure, not a silent "applied".
            rejected = [k for k in extra if k in self.clamp_mod_props]
            if rejected:
                worst = rejected[0]
                failures.append("{0}: 1 parameter(s) rejected: {1}: kept {2}".format(
                    name, worst, self.clamp_mod_props[worst]))
                continue
            node.setdefault("modParams", {}).update(extra)
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "Done."}

    # ------------------------------------------------- stage 3: scene reading
    def _h_list_objects(self, params):
        pattern = str(params.get("namePattern") or "")
        klass = str(params.get("class") or "")
        entries: List[Dict[str, Any]] = []
        for key in sorted(self.nodes):
            if pattern and not self._glob(key, pattern):
                continue
            for node in self.nodes[key]:
                if klass and node.get("class") != klass:
                    continue
                entries.append(copy.deepcopy(node))
        total = len(entries)
        limit = int(params.get("limit") or 200)
        offset = int(params.get("offset") or 0)
        return {"count": total, "offset": offset, "limit": limit,
                "objects": entries[offset:offset + limit]}

    # ------------------------------------------------- stage 3: primitives
    def _unique_name(self, name: str) -> str:
        """Mirror Max's automatic rename when a name is already taken."""
        if name not in self.nodes:
            return name
        stem = name.rstrip("0123456789") or name
        index = 1
        while "{0}{1:03d}".format(stem, index) in self.nodes:
            index += 1
        return "{0}{1:03d}".format(stem, index)

    def _create(self, params):
        klass = str(params.get("class") or "Box")
        requested = str(params.get("name") or params.get("setName") or "{0}001".format(klass))
        name = self._unique_name(requested)
        node = self.add(name, klass, list(params.get("position") or [0, 0, 0]))
        failures: List[str] = []
        warnings: List[str] = []
        if name != requested:
            # Max keeps a unique variant instead of raising; the handler reports
            # it as a warning, because the object really was created.
            warnings.append("name: scene kept {0}".format(name))
        for prop in ("length", "width", "height", "radius", "radius1", "radius2",
                     "segments", "sides", "turns", "cornerRadius"):
            value = params.get(prop)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                clamped = self.clamp_props.get(prop)
                if clamped is not None:
                    # The scene silently keeps another value; only a read-back
                    # notices, which is exactly what the handler now does.
                    node[prop] = float(clamped)
                    failures.append("{0}: kept {1}".format(prop, clamped))
                else:
                    node[prop] = float(value)
        # Same shape as mcpH_create_primitive: success + node + failures + warnings.
        return {"success": not failures, "object": copy.deepcopy(node),
                "failures": failures, "warnings": warnings,
                "message": "Created {0}".format(name)}

    def _h_create_line(self, params):
        """Mirror mcpH_create_line: knots first, then name/position, then a verdict."""
        points = list(params.get("points") or [])
        if not points:
            raise BridgeCommandError(
                "Missing parameter: points",
                detail={"kind": "err.missing_param", "message": "points"},
            )
        failures: List[str] = []
        warnings: List[str] = []
        requested = str(params.get("name") or "Line001")
        name = self._unique_name(requested)
        node = self.add(name, "Line", list(params.get("position") or [0, 0, 0]))
        if name != requested:
            warnings.append("name: scene kept {0}".format(name))
        knots = len(points)
        if name in self.reject_ops:
            # addKnot refused for every point: the knot count is the read-back.
            knots = 0
            failures.append("knots: asked for {0}, scene has 0".format(len(points)))
        node["knots"] = knots
        node["closed"] = bool(params.get("closed"))
        return {"success": not failures, "object": copy.deepcopy(node),
                "failures": failures, "warnings": warnings,
                "message": "Created {0}".format(name)}

    # ------------------------------------------------- stage 3: modelling
    def _h_convert_to_editable_poly(self, params):
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            node["class"] = "Editable_Poly"
            node["baseClass"] = "Editable_Poly"
            node["isPoly"] = True
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "Done."}

    def _h_poly_get_stats(self, params):
        out: List[Any] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                # The real handler appends "ERROR <name>: <message>" as a string.
                out.append("ERROR {0}: Editable Poly required".format(name))
                continue
            faces = node.get("faceCount", 6)
            out.append({"name": name, "verts": node.get("vertexCount", 8),
                        "faces": faces, "edges": 12, "materialIdMin": 1,
                        "materialIdMax": 1, "polygonCount": faces})
        return {"objects": out, "message": "Done."}

    def _h_poly_select_faces(self, params):
        """Mirror mcpH_poly_select_faces: rows, plus the two halves apart.

        The real handler used to mix "ERROR <name>" strings into `results`, which
        the runtime reads as a non-empty list = success.
        """
        applied: List[str] = []
        rows: List[Dict[str, Any]] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                failures.append("{0}: Editable Poly required".format(name))
                continue
            faces = node.get("faceCount", 6)
            self.selected_faces[name] = list(range(1, faces + 1))
            rows.append({"object": name, "faces": faces, "count": faces})
            applied.append(name)
        return {"results": rows, "applied": applied, "failures": failures,
                "message": "Done."}

    def _h_poly_extrude_faces(self, params):
        amount = params.get("amount") or 0.0
        applied: List[str] = []
        unchanged: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                failures.append("{0}: Editable Poly required".format(name))
                continue
            faces = params.get("faces")
            selected = self.selected_faces.get(name) or []
            if not isinstance(faces, list) and not selected:
                failures.append("{0}: nothing selected".format(name))
                continue
            if self.poly_noop or name in self.reject_ops:
                unchanged.append(name)
            else:
                node["faceCount"] = node.get("faceCount", 6) + 4
            applied.append(name)
        return {"applied": applied, "unchanged": unchanged, "failures": failures,
                "message": "Done."}

    # ------------------------------------------------- stage 3: materials
    def _h_mat_create_standard(self, params):
        name = str(params.get("name") or "Material#{0}".format(len(self.materials) + 1))
        diffuse = list(params.get("diffuse") or [128, 128, 128])
        existing = self.materials.get(name)
        if existing is not None:
            # Same shape as mcpAssignCreatedMat: success + class/name/assignedTo.
            return {"success": True, "class": "Standard", "name": name,
                    "assignedTo": [], "reused": True, "message": "Exists."}
        self.materials[name] = {"class": "Standard", "name": name, "diffuse": diffuse}
        return {"success": True, "class": "Standard", "name": name,
                "assignedTo": [], "reused": False, "diffuse": diffuse,
                "message": "Created."}

    def _h_mat_list(self, params):
        limit = int(params.get("limit") or 200)
        offset = int(params.get("offset") or 0)
        rows = [copy.deepcopy(self.materials[key]) for key in sorted(self.materials)]
        return {"count": len(rows), "offset": offset, "limit": limit,
                "materials": rows[offset:offset + limit]}

    def _h_mat_get_for_object(self, params):
        rows: List[Dict[str, Any]] = []
        for name in self._targets(params):
            node = self._require(name)
            material = node.get("material") or ""
            rows.append({"object": name,
                         "material": ({"name": material} if material else None)})
        return {"count": len(rows), "objects": rows}

    def _h_rename_object(self, params):
        old = str(params.get("name") or "")
        new = str(params.get("newName") or "")
        node = self._require(old)
        if not new:
            raise BridgeCommandError(
                "Missing parameter: newName",
                detail={"kind": "err.missing_param", "message": "newName"},
            )
        # Max does not raise when the target name is taken - it silently keeps
        # the old one.  The handler therefore compares instead of assuming, and
        # this stub must do the same or the offline tests would be kinder than
        # the real thing.
        if new == old or new not in self.nodes:
            self.nodes.pop(old, None)
            node["name"] = new
            self.nodes.setdefault(new, []).append(node)
            self.selection = [new if item == old else item for item in self.selection]
        return {"oldName": old, "newName": node["name"],
                "renamed": node["name"] == new, "message": "Renamed."}

    # ------------------------------------------- stage 5: visibility and state
    def _h_scene_new(self, params):
        """Mirror mcpH_scene_new: clear the scene, optionally keep session settings."""
        keep = params.get("keepScene") is True
        saved = dict(self.session) if keep else {}
        self.nodes.clear()
        self.selection = []
        self.groups.clear()
        self.layers = {"0": {"name": "0", "hidden": False, "frozen": False,
                             "wireColor": None}}
        self.session = saved
        return {"success": True, "created": True, "kept": sorted(saved),
                "message": "OK"}

    def _h_hide_objects(self, params):
        return self._set_flag(params, "isHidden", True, "hidden")

    def _h_unhide_objects(self, params):
        # Mirrors mcpH_unhide_objects: with no objects the real handler acts on
        # everything, so the stub must too.
        return self._set_flag(params, "isHidden", False, "shown", all_when_empty=True)

    def _h_unhide_all(self, params):
        return self._set_flag(params, "isHidden", False, "shown", everyone=True)

    def _h_freeze_objects(self, params):
        return self._set_flag(params, "isFrozen", True, "frozen")

    def _h_unfreeze_all(self, params):
        return self._set_flag(params, "isFrozen", False, "thawed", everyone=True)

    def _set_flag(self, params, field, want, key, all_when_empty=False, everyone=False):
        """Apply the call, then report the flag the scene actually holds.

        With ``everyone`` the call still touches every object, but only the ones
        whose state actually changed are reported - "thawed" means it used to be
        frozen, not "it is not frozen now", otherwise the list is a dump of the
        whole scene.
        """
        if everyone:
            targets = sorted(self.nodes)
            report = {name for name in targets
                      if self.nodes[name][0].get(field) is (not want)}
        else:
            targets = [str(n) for n in params.get("objects") or []]
            if not targets and all_when_empty:
                targets = sorted(self.nodes)
            report = None
        hit: List[str] = []
        miss: List[str] = []
        for name in targets:
            node = self._require(name)
            counted = report is None or name in report
            if name in self.reject_ops:
                if counted:
                    miss.append(name)
                continue
            node[field] = want
            if counted:
                hit.append(name)
        return {key: hit, "failures": miss, "message": "OK"}

    def _h_reset_transform(self, params):
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.reject_ops:
                failures.append(name)
                continue
            if params.get("rotation", True) is not False:
                node["rotation"] = [0.0, 0.0, 0.0]
            if params.get("scale", True) is not False:
                node["scale"] = [1.0, 1.0, 1.0]
            if params.get("position") is True:
                node["position"] = [0.0, 0.0, 0.0]
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "OK"}

    def _h_snap_objects_to_grid(self, params):
        spacing = float(params.get("spacing") or 10.0)
        if spacing <= 0:
            spacing = 10.0
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.reject_ops:
                failures.append(name)
                continue
            pos = list(node.get("position") or [0.0, 0.0, 0.0])
            # floor(x + 0.5), matching the MAXScript handler; Python's round()
            # is banker's rounding and would disagree on exact halves.
            node["position"] = [math.floor(value / spacing + 0.5) * spacing for value in pos]
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "OK"}

    def _h_open_group(self, params):
        return self._set_group_open(params, True)

    def _h_close_group(self, params):
        return self._set_group_open(params, False)

    def _set_group_open(self, params, want):
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name not in self.groups or name in self.reject_ops:
                failures.append(name)
                continue
            node["groupOpen"] = want
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "OK"}

    # ---------------------------------------------- stage 4: layers, groups
    def _h_list_layers(self, params):
        rows = []
        for name in sorted(self.layers):
            layer = self.layers[name]
            rows.append({
                "name": name,
                "hidden": bool(layer.get("hidden")),
                "frozen": bool(layer.get("frozen")),
                "wireColor": layer.get("wireColor"),
                "nodeCount": sum(1 for entries in self.nodes.values()
                                 for node in entries if node.get("layer") == name),
            })
        return {"count": len(rows), "layers": rows}

    def _h_create_layer(self, params):
        name = str(params.get("name") or "")
        if not name:
            raise BridgeCommandError(
                "Missing parameter: name",
                detail={"kind": "err.missing_param", "message": "name"},
            )
        if name in self.layers:
            raise BridgeCommandError(
                "layer already exists: {0}".format(name),
                detail={"kind": "err.bad_value", "message": name},
            )
        self.layers[name] = {
            "name": name,
            "hidden": bool(params.get("hidden")),
            "frozen": False,
            "wireColor": params.get("color"),
        }
        return {"layer": name, "message": "Layer created: {0}".format(name)}

    def _h_assign_to_layer(self, params):
        layer = str(params.get("layer") or "")
        if not layer:
            raise BridgeCommandError(
                "Missing parameter: layer",
                detail={"kind": "err.missing_param", "message": "layer"},
            )
        if layer not in self.layers:
            # mcpEnsureLayer creates it on demand.
            self.layers[layer] = {"name": layer, "hidden": False,
                                  "frozen": False, "wireColor": None}
        moved: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.skip_assign:
                failures.append("{0}: layer rejected".format(name))
                continue
            node["layer"] = layer
            moved.append(name)
        return {"layer": layer, "moved": moved, "failures": failures}

    def _h_group_objects(self, params):
        names = self._targets(params)
        if not names:
            raise BridgeCommandError(
                "Nothing selected",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        requested = str(params.get("name") or "")
        group = self._unique_name(requested or "Group001")
        self._handle += 1
        node = _node(group, self._handle, "Group")
        node["superClass"] = "Container"
        node["vertexCount"] = 0
        node["faceCount"] = 0
        node["children"] = list(names)
        node["childCount"] = len(names)
        self.nodes.setdefault(group, []).append(node)
        for name in names:
            target = self._require(name)
            target["parent"] = group
        self.groups[group] = list(names)
        return {"group": group, "message": "OK"}

    def _h_ungroup_objects(self, params):
        ungrouped: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name not in self.groups:
                failures.append(name)
                continue
            for child in self.groups.pop(name):
                member = self.node(child)
                if member is not None:
                    member["parent"] = ""
            self.nodes.pop(name, None)
            ungrouped.append(name)
        return {"ungrouped": ungrouped, "failures": failures, "message": "OK"}

    # ------------------------------------------- stage 4: saving and export
    def _h_scene_save_as(self, params):
        path = str(params.get("path") or "")
        if not path:
            raise BridgeCommandError(
                "Missing parameter: path",
                detail={"kind": "err.missing_param", "message": "path"},
            )
        if "." not in path.rsplit("/", 1)[-1]:
            path = path + ".max"
        if path in self.existing_files and params.get("confirm") is not True:
            raise BridgeCommandError(
                "File exists, pass confirm=true to overwrite: {0}".format(path),
                detail={"kind": "err.confirm_required", "message": path},
            )
        # No bytes are written: this stub records the intent so tests can assert
        # the call happened, and never claims a file exists on disk.
        self.saved_path = path
        return {"saved": path, "pathKept": params.get("keepPath") is False,
                "message": "Saved {0}".format(path)}

    def _h_export_fbx(self, params):
        path = str(params.get("path") or "")
        if not path:
            raise BridgeCommandError(
                "Missing parameter: path",
                detail={"kind": "err.missing_param", "message": "path"},
            )
        if not path.lower().endswith(".fbx"):
            path = path + ".fbx"
        self.exported_path = path
        return {"path": path, "preset": str(params.get("preset") or "unreal"),
                "written": True, "message": "Exported {0}".format(path)}

    # ------------------------------------------------- stage 3: visual feedback
    def _h_vision_capture(self, params):
        if self.vision_without_image:
            return {"count": 0, "views": [], "message": "No active viewport"}
        return {
            "count": 1,
            "views": ["perspective"],
            "maxEdge": int(params.get("max_edge") or 640),
            "_images": [{
                "label": "perspective",
                "data": base64.b64encode(PNG_BYTES).decode("ascii"),
                "mime": "image/png",
            }],
        }


    # ------------------------------------------------- stage 10: modelling truth
    def _h_align_objects(self, params):
        """Mirror mcpH_align_objects: per-object, verified against the target."""
        target = self._require(str(params.get("target") or ""))
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.reject_ops:
                failures.append("{0}: position kept {1}".format(name, node["position"]))
                continue
            if params.get("position", True) is not False:
                node["position"] = list(target["position"])
            if params.get("rotation") is True:
                node["rotation"] = list(target["rotation"])
            if params.get("scale") is True:
                node["scale"] = list(target["scale"])
            applied.append(name)
        return {"target": target["name"], "aligned": applied, "failures": failures,
                "message": "OK"}

    def _h_attach_objects(self, params):
        """Mirror mcpH_attach_objects: the target must be a shape, and the spline
        count is the only evidence that attach did anything."""
        target = self._require(str(params.get("target") or ""))
        if target.get("superClass") != "ShapeClass":
            raise BridgeCommandError(
                "target is not a shape: {0}".format(target["name"]),
                detail={"kind": "err.bad_value", "message": target["name"]},
            )
        attached: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.reject_ops or node.get("superClass") != "ShapeClass":
                failures.append("{0}: attach added no splines".format(name))
                continue
            self.nodes.pop(name, None)
            target["splines"] = int(target.get("splines") or 1) + 1
            attached.append(name)
        return {"target": target["name"], "attached": attached,
                "failures": failures, "message": "OK"}

    def _h_parent_objects(self, params):
        parent = self._require(str(params.get("parent") or ""))
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if name in self.reject_ops:
                failures.append("{0}: parent not changed".format(name))
                continue
            node["parent"] = parent["name"]
            applied.append(name)
        return {"parent": parent["name"], "children": applied,
                "failures": failures, "message": "OK"}

    def _h_boolean_operation(self, params):
        names = self._targets(params)
        if len(names) < 2:
            raise BridgeCommandError(
                "objects needs at least two entries",
                detail={"kind": "err.bad_value", "message": "objects"},
            )
        result = self._require(names[0])
        before = int(result.get("faceCount") or 0)
        failures: List[str] = []
        for name in names[1:]:
            operand = self._require(name)
            if self.boolean_noop or name in self.reject_ops:
                # The sequence completes but the operand is still there.
                failures.append("{0}: operand still in the scene after boolean".format(name))
                continue
            result["faceCount"] = before + int(operand.get("faceCount") or 0)
            self.nodes.pop(name, None)
        return {"success": not failures, "result": copy.deepcopy(result),
                "facesBefore": before, "facesAfter": int(result.get("faceCount") or 0),
                "changed": int(result.get("faceCount") or 0) != before,
                "failures": failures, "message": "OK"}

    def _h_proboolean(self, params):
        names = self._targets(params)
        if len(names) < 2:
            raise BridgeCommandError(
                "objects needs at least two entries",
                detail={"kind": "err.bad_value", "message": "objects"},
            )
        first = self._require(names[0])
        before = int(first.get("faceCount") or 0)
        remaining = 0
        for name in names[1:]:
            operand = self._require(name)
            if self.boolean_noop:
                remaining += 1
                continue
            first["faceCount"] = int(first.get("faceCount") or 0) + int(operand.get("faceCount") or 0)
            self.nodes.pop(name, None)
        after = int(first.get("faceCount") or 0)
        return {"success": True, "result": copy.deepcopy(first),
                "facesBefore": before, "facesAfter": after, "changed": after != before,
                "operandsRemaining": remaining, "message": "OK"}

    def _h_mod_remove(self, params):
        spec = str(params.get("modifier") or "")
        removed: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            stack = list(node.get("modifiers") or [])
            match = next((m for m in stack if m == spec), None)
            if match is None:
                failures.append("{0}: no modifier {1}".format(name, spec))
                continue
            if name in self.reject_ops:
                failures.append("{0}: modifier still in the stack".format(name))
                removed.append(name)
                continue
            stack.remove(match)
            node["modifiers"] = stack
            removed.append(name)
        return {"removed": removed, "failures": failures, "message": "OK"}

    def _h_mod_set_param(self, params):
        return self._set_mod_params(params, single=True)

    def _h_mod_set_params(self, params):
        return self._set_mod_params(params, single=False)

    def _set_mod_params(self, params, single):
        spec = str(params.get("modifier") or "")
        wanted = ({str(params.get("param")): _coerce(params.get("value"))} if single
                  else {k: _coerce(v) for k, v in (params.get("params") or {}).items()})
        applied: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            stack = list(node.get("modifiers") or [])
            if spec not in stack:
                failures.append("{0}: no modifier {1}".format(name, spec))
                continue
            rejected = [k for k in wanted if k in self.clamp_mod_props]
            if rejected:
                key = rejected[0]
                failures.append("{0}: {1}: kept {2}".format(name, key, self.clamp_mod_props[key]))
                continue
            node.setdefault("modParams", {}).update(wanted)
            applied.append(name)
        return {"applied": applied, "failures": failures, "message": "OK"}

    def _h_poly_weld_vertices(self, params):
        applied: List[str] = []
        unchanged: List[str] = []
        failures: List[str] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                failures.append("{0}: Editable Poly required".format(name))
                continue
            applied.append(name)
            if self.poly_noop:
                # Coincident vertices: the call succeeds and changes nothing.
                unchanged.append(name)
            else:
                node["vertexCount"] = max(1, int(node.get("vertexCount") or 8) - 2)
        return {"applied": applied, "unchanged": unchanged, "failures": failures,
                "message": "OK"}

    def _h_array_objects(self, params):
        names = [str(n) for n in params.get("objects") or []]
        if not names:
            raise BridgeCommandError(
                "no objects",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        created: List[str] = []
        moved: List[str] = []
        failures: List[str] = []
        count = int(params.get("count1") or 3)
        for index in range(1, max(1, count)):
            try:
                source = self._require(names[0])
                clone = self.add(self._unique_name("{0}_arr".format(source["name"])),
                                 source.get("class") or "Box")
            except BridgeCommandError as exc:
                failures.append("cell {0}: {1}".format(index, exc))
                continue
            created.append(clone["name"])
        proto = self._require(names[0])
        if names[0] in self.reject_ops:
            failures.append("{0}: position rejected".format(names[0]))
        else:
            moved.append(names[0])
        return {"created": created, "moved": moved, "count": len(created),
                "failures": failures, "message": "OK"}

    def _h_scatter_objects(self, params):
        names = [str(n) for n in params.get("objects") or []]
        if not names:
            raise BridgeCommandError(
                "no objects",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        created: List[str] = []
        failures: List[str] = []
        count = int(params.get("count") or len(names))
        for index in range(1, max(1, count) + 1):
            source = self._require(names[(index - 1) % len(names)])
            if params.get("region") == "surface" and not names:
                failures.append("instance {0}: ray missed the surface".format(index))
                continue
            clone = self.add(self._unique_name("{0}_sc".format(source["name"])),
                             source.get("class") or "Box")
            created.append(clone["name"])
        return {"created": created, "count": len(created), "failures": failures,
                "message": "OK"}

    def _h_detach_elements(self, params):
        node = self._require(str(params.get("name") or ""))
        before = len(self.nodes)
        created: List[str] = []
        failures: List[str] = []
        elements = int(node.get("elements") or 0)
        for index in range(1, elements + 1):
            if self.poly_noop:
                failures.append("element {0}: detach created no node".format(index))
                continue
            name = "Det_{0}_{1}".format(node["name"], index)
            clone = self.add(self._unique_name(name), node.get("class") or "Editable_Poly")
            created.append(clone["name"])
        assert len(self.nodes) >= before
        return {"detached": created, "failures": failures, "message": "OK"}

    # ------------------------------------------------- stage 11: asset placement
    def _h_place_on_surface(self, params):
        targets = self._targets(params)
        if not targets:
            raise BridgeCommandError(
                "no objects",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        surface_name = str(params.get("surface") or "")
        surface_node = self._require(surface_name) if surface_name else None
        ground_z = float(params.get("groundZ") or 0.0)
        offset = float(params.get("offset") or 0.0)
        use_pivot = bool(params.get("usePivot"))

        applied: List[str] = []
        placed: List[Dict[str, Any]] = []
        failures: List[str] = []
        for name in targets:
            node = self._require(name)
            if surface_node is not None and node is surface_node:
                failures.append("{0}: cannot place surface onto itself".format(name))
                continue
            if name in self.reject_ops:
                failures.append("{0}: z read-back mismatch".format(name))
                continue
            _sync_bounds(node)
            pos = list(node["position"])
            if surface_node is not None:
                _sync_bounds(surface_node)
                s_min = surface_node["boundingBox"]["min"]
                s_max = surface_node["boundingBox"]["max"]
                if not (s_min[0] <= pos[0] <= s_max[0] and s_min[1] <= pos[1] <= s_max[1]):
                    failures.append("{0}: ray missed surface {1}".format(name, surface_name))
                    continue
                hit_z = s_max[2]
            else:
                hit_z = ground_z
            target_z = hit_z + offset
            if not use_pivot:
                pivot_to_bottom = pos[2] - node["boundingBox"]["min"][2]
                target_z += pivot_to_bottom
            if not self.ignore_transform:
                node["position"] = [pos[0], pos[1], target_z]
                _sync_bounds(node)
            actual_z = node["position"][2] if use_pivot else node["boundingBox"]["min"][2]
            if abs(actual_z - (hit_z + offset)) > 0.01:
                failures.append("{0}: z read-back {1} != {2}".format(name, actual_z, hit_z + offset))
                continue
            applied.append(name)
            placed.append({
                "name": name,
                "surfaceZ": hit_z,
                "finalZ": actual_z,
                "position": list(node["position"]),
            })
        return {
            "success": bool(applied) and not failures,
            "applied": applied,
            "placed": placed,
            "failures": failures,
            "message": "OK",
        }

    def _h_place_relative(self, params):
        targets = self._targets(params)
        if not targets:
            raise BridgeCommandError(
                "no objects",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        target_name = str(params.get("target") or "")
        target = self._require(target_name)
        _sync_bounds(target)
        t_min = target["boundingBox"]["min"]
        t_max = target["boundingBox"]["max"]
        t_center = [(t_min[i] + t_max[i]) * 0.5 for i in range(3)]
        side = str(params.get("side") or "top").lower()
        gap = float(params.get("gap") or 0.0)
        align_center = params.get("alignCenter") is not False

        applied: List[str] = []
        placed: List[Dict[str, Any]] = []
        failures: List[str] = []
        for name in targets:
            node = self._require(name)
            if node is target:
                failures.append("{0}: cannot place target relative to itself".format(name))
                continue
            if name in self.reject_ops or self.ignore_transform:
                failures.append("{0}: position read-back mismatch".format(name))
                continue
            _sync_bounds(node)
            n_min = node["boundingBox"]["min"]
            n_max = node["boundingBox"]["max"]
            n_center = [(n_min[i] + n_max[i]) * 0.5 for i in range(3)]
            dx = (t_center[0] - n_center[0]) if align_center else 0.0
            dy = (t_center[1] - n_center[1]) if align_center else 0.0
            dz = (t_center[2] - n_center[2]) if align_center else 0.0
            if side == "top":
                dz = (t_max[2] + gap) - n_min[2]
            elif side == "bottom":
                dz = (t_min[2] - gap) - n_max[2]
            elif side == "right":
                dx = (t_max[0] + gap) - n_min[0]
            elif side == "left":
                dx = (t_min[0] - gap) - n_max[0]
            elif side == "back":
                dy = (t_max[1] + gap) - n_min[1]
            elif side == "front":
                dy = (t_min[1] - gap) - n_max[1]
            elif side == "center":
                dx, dy, dz = [t_center[i] - n_center[i] for i in range(3)]
            else:
                failures.append("{0}: unknown side {1}".format(name, side))
                continue
            pos = node["position"]
            node["position"] = [pos[0] + dx, pos[1] + dy, pos[2] + dz]
            _sync_bounds(node)
            applied.append(name)
            placed.append({
                "name": name,
                "position": list(node["position"]),
                "min": list(node["boundingBox"]["min"]),
                "max": list(node["boundingBox"]["max"]),
            })
        return {
            "success": bool(applied) and not failures,
            "target": target["name"],
            "side": side,
            "applied": applied,
            "placed": placed,
            "failures": failures,
            "message": "OK",
        }

    def _h_distribute_along_spline(self, params):
        protos = self._targets(params)
        if not protos:
            raise BridgeCommandError(
                "no objects",
                detail={"kind": "err.no_selection", "message": "no_selection"},
            )
        spline_name = str(params.get("spline") or "")
        sp = self._require(spline_name)
        if sp.get("class") not in SHAPE_CLASSES and sp.get("superClass") != "ShapeClass":
            raise BridgeCommandError(
                "target is not a spline shape",
                detail={"kind": "err.invalid_argument", "message": spline_name},
            )
        count = int(params.get("count") or 0)
        if count <= 0:
            spacing = float(params.get("spacing") or 0.0)
            count = max(1, int(100.0 / spacing) + 1) if spacing > 0 else 10
        surface_name = str(params.get("surface") or "")
        surface_node = self._require(surface_name) if surface_name else None
        offset = float(params.get("offset") or 0.0)

        created: List[str] = []
        failures: List[str] = []
        for idx in range(1, count + 1):
            proto_name = protos[(idx - 1) % len(protos)]
            proto = self._require(proto_name)
            if proto_name in self.reject_ops:
                failures.append("instance {0}: copy returned no node".format(idx))
                continue
            t = (idx - 1) / float(max(1, count - 1)) if count > 1 else 0.0
            px = t * 100.0
            py = 0.0
            pz = offset
            if surface_node is not None:
                _sync_bounds(surface_node)
                pz = surface_node["boundingBox"]["max"][2] + offset
            clone = self.add(self._unique_name("{0}_sp".format(proto["name"])),
                             proto.get("class") or "Box", [px, py, pz])
            for dim in ("width", "length", "height", "radius"):
                if dim in proto:
                    clone[dim] = proto[dim]
            _sync_bounds(clone)
            created.append(clone["name"])
        return {
            "success": bool(created) and not failures,
            "spline": sp["name"],
            "created": created,
            "count": len(created),
            "failures": failures,
            "message": "Created {0}".format(len(created)),
        }

    def _h_check_overlaps(self, params):
        req_names = [str(n) for n in params.get("objects") or []]
        against_names = [str(n) for n in params.get("against") or []]
        ignore_set = {str(n).lower() for n in (params.get("ignore") or [])}
        tol = float(params.get("tolerance") if params.get("tolerance") is not None else 0.01)
        include_hidden = bool(params.get("includeHidden"))

        def all_geom() -> List[Dict[str, Any]]:
            out: List[Dict[str, Any]] = []
            for entries in self.nodes.values():
                for n in entries:
                    if n.get("superClass") == "GeometryClass" and (include_hidden or not n.get("isHidden")):
                        out.append(_sync_bounds(n))
            return out

        if req_names:
            targets = [_sync_bounds(self._require(nm)) for nm in req_names]
        elif self.selection:
            targets = [_sync_bounds(self._require(nm)) for nm in self.selection]
        else:
            targets = all_geom()

        if against_names:
            pool = [_sync_bounds(self._require(nm)) for nm in against_names]
        else:
            pool = all_geom()

        targets = [n for n in targets if n["name"].lower() not in ignore_set]
        pool = [n for n in pool if n["name"].lower() not in ignore_set]

        overlaps: List[Dict[str, Any]] = []
        seen = set()
        for a in targets:
            a_min, a_max = a["boundingBox"]["min"], a["boundingBox"]["max"]
            for b in pool:
                if a is b:
                    continue
                pair = tuple(sorted((a["handle"], b["handle"])))
                if pair in seen:
                    continue
                b_min, b_max = b["boundingBox"]["min"], b["boundingBox"]["max"]
                ox = min(a_max[0], b_max[0]) - max(a_min[0], b_min[0])
                oy = min(a_max[1], b_max[1]) - max(a_min[1], b_min[1])
                oz = min(a_max[2], b_max[2]) - max(a_min[2], b_min[2])
                if ox > tol and oy > tol and oz > tol:
                    seen.add(pair)
                    overlaps.append({
                        "a": a["name"],
                        "b": b["name"],
                        "penetration": [ox, oy, oz],
                    })
        return {
            "checkedObjects": len(targets),
            "overlapCount": len(overlaps),
            "overlaps": overlaps,
            "tolerance": tol,
            "message": "OK",
        }


__all__ = ["FakeScene", "PRIMITIVE_CLASSES", "PNG_BYTES",
           "BridgeCommandError", "BridgeNotRunning", "BridgeTimeout"]
