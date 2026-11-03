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

#: Smallest possible valid PNG header + payload; enough for the server's sniff.
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


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
        if position:
            node["position"] = list(position)
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
        return {"count": len(matched), "objects": [copy.deepcopy(node) for node in matched]}

    @staticmethod
    def _glob(text: str, pattern: str) -> bool:
        import fnmatch
        return fnmatch.fnmatchcase(text, pattern)

    def _h_get_object_info(self, params):
        return copy.deepcopy(self._require(str(params.get("name") or "")))

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
        count = int(params.get("count") or 1)
        clone_type = params.get("cloneType") or "copy"
        for name in params.get("objects") or []:
            source = self._require(name)
            for index in range(count):
                clone_name = "{0}_clone{1}".format(name, index + 1)
                self._handle += 1
                clone = copy.deepcopy(source)
                clone["name"] = clone_name
                clone["handle"] = self._handle
                self.nodes.setdefault(clone_name, []).append(clone)
                created.append(clone_name)
        return {"created": created, "count": len(created),
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
        for name in params.get("objects") or []:
            node = self._require(name)
            if name in self.skip_assign:
                failures.append("{0}: modifier rejected".format(name))
                continue
            node["modifiers"] = list(node["modifiers"]) + [modifier]
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
        for prop in ("length", "width", "height", "radius"):
            value = params.get(prop)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                node[prop] = float(value)
        # Same shape as mcpH_create_primitive: success + the created node + failures.
        return {"success": True, "object": copy.deepcopy(node), "failures": [],
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
        applied: List[Dict[str, Any]] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                raise BridgeCommandError(
                    "Editable Poly required: {0}".format(name),
                    detail={"kind": "err.poly_required", "message": name},
                )
            faces = node.get("faceCount", 6)
            self.selected_faces[name] = list(range(1, faces + 1))
            applied.append({"name": name, "faces": faces})
        return {"objects": applied, "message": "Done."}

    def _h_poly_extrude_faces(self, params):
        amount = params.get("amount") or 0.0
        applied: List[Dict[str, Any]] = []
        for name in self._targets(params):
            node = self._require(name)
            if not node.get("isPoly"):
                raise BridgeCommandError(
                    "Editable Poly required: {0}".format(name),
                    detail={"kind": "err.poly_required", "message": name},
                )
            faces = params.get("faces")
            selected = self.selected_faces.get(name) or []
            if not isinstance(faces, list) and not selected:
                raise BridgeCommandError(
                    "Nothing selected",
                    detail={"kind": "err.no_selection", "message": "empty face selection"},
                )
            node["faceCount"] = node.get("faceCount", 6) + 4
            applied.append({"name": name, "amount": amount, "faces": node["faceCount"]})
        return {"objects": applied, "message": "Done."}

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


__all__ = ["FakeScene", "PRIMITIVE_CLASSES", "PNG_BYTES",
           "BridgeCommandError", "BridgeNotRunning", "BridgeTimeout"]
