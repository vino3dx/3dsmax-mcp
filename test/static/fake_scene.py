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
"""

from __future__ import annotations

import copy
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.bridge import BridgeCommandError, BridgeNotRunning, BridgeTimeout  # noqa: E402


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
        self._handle = 100
        #: names Max will refuse to delete (simulates a locked/referenced node)
        self.undeletable: set = set()
        #: names the material/modifier handlers will silently skip
        self.skip_assign: set = set()
        #: set to a transport exception to make the next call fail at that layer
        self.transport_failure: Optional[BaseException] = None
        #: when True, transform_object silently ignores the request (no change)
        self.ignore_transform = False
        #: when True, delete_objects returns success without deleting
        self.fake_delete = False

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
            raise self.transport_failure
        params = params or {}
        handler = getattr(self, "_h_" + method, None)
        if handler is None:
            raise BridgeCommandError(
                "Unknown command: {0}".format(method),
                detail={"kind": "err.unknown_method", "message": method},
            )
        return handler(params)

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


__all__ = ["FakeScene", "BridgeCommandError", "BridgeNotRunning", "BridgeTimeout"]
