"""Static + offline validation for the 24 core tools that had no live case.

"Has no live case" does not mean "not implemented", so this test proves what can
be proven without 3ds Max:

* the tool is registered in the catalog and in MAXScript (``mcpRegister``);
* required parameters, types, enums and bounds are declared and consistent;
* read-only versus destructive is labelled correctly (``scene_save`` used to be
  advertised as read-only although it writes to disk);
* obviously invalid arguments are rejected in Python with ``invalid_arguments``
  before anything is sent to Max;
* the dangerous tools keep their safety boundary (``scene_save_as`` needs
  ``confirm`` to overwrite an existing scene).

What it deliberately does **not** claim: that these commands behave correctly
inside a running 3ds Max.  That still needs ``test/live``.
"""

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.catalog import build_catalog  # noqa: E402
from maxmcp.catalog.schema import CORE_TOOLS  # noqa: E402
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

#: The tools the core capability matrix listed as "no live case yet".
NO_LIVE_CASE = (
    "bridge_capabilities", "bridge_ping", "create_circle", "create_cone",
    "create_geosphere", "create_plane", "create_pyramid", "create_torus",
    "create_tube", "delete_objects", "execute_maxscript", "get_selection",
    "mat_list", "mod_symmetry", "mod_turbosmooth", "poly_chamfer_edges",
    "poly_connect_edges", "poly_get_selection", "poly_get_stats",
    "poly_inset_faces", "poly_weld_vertices", "scene_open", "scene_save",
    "scene_save_as",
)

READ_ONLY = {
    "bridge_capabilities", "bridge_ping", "get_selection", "mat_list",
    "poly_get_selection", "poly_get_stats",
}
DESTRUCTIVE = {
    "create_circle", "create_cone", "create_geosphere", "create_plane",
    "create_pyramid", "create_torus", "create_tube", "delete_objects",
    "execute_maxscript", "mod_symmetry", "mod_turbosmooth",
    "poly_chamfer_edges", "poly_connect_edges", "poly_inset_faces",
    "poly_weld_vertices", "scene_open", "scene_save", "scene_save_as",
}
REQUIRED = {
    "execute_maxscript": ["code"],
    "poly_chamfer_edges": ["edges"],
    "poly_connect_edges": ["edges"],
    "poly_inset_faces": ["outline"],
    "poly_weld_vertices": ["vertices"],
    "scene_open": ["path"],
    "scene_save_as": ["path"],
}


def registered_bridge_methods():
    """Every ``mcpRegister "name"`` declared anywhere in src/ms."""
    names = set()
    pattern = re.compile(r'mcpRegister\s+"([^"]+)"')
    for path in sorted((ROOT / "src" / "ms").glob("*.ms")):
        text = path.read_text(encoding="utf-8", errors="replace")
        names.update(pattern.findall(text))
    return names


def schema_problems(entry):
    problems = []
    schema = entry.schema
    if schema.get("type") != "object":
        problems.append("schema is not an object")
    props = schema.get("properties") or {}
    for name, spec in props.items():
        if "type" not in spec:
            problems.append("{0}: property without type".format(name))
        layout = spec.get("default")
        if layout is not None and not isinstance(layout, (str, int, float, bool, list)):
            problems.append("{0}: default has an unportable type".format(name))
        enum = spec.get("enum")
        if enum is not None:
            if not isinstance(enum, list) or not enum:
                problems.append("{0}: empty enum".format(name))
        minimum, maximum = spec.get("minimum"), spec.get("maximum")
        if isinstance(minimum, (int, float)) and isinstance(maximum, (int, float)):
            if minimum > maximum:
                problems.append("{0}: minimum > maximum".format(name))
    for name in schema.get("required") or []:
        if name not in props:
            problems.append("required parameter {0} is not declared".format(name))
    return problems


def check_registration():
    catalog = build_catalog()
    bridges = registered_bridge_methods()
    assert bridges, "no mcpRegister entries found - is src/ms present?"
    for name in NO_LIVE_CASE:
        entry = catalog.get(name)
        assert entry is not None, "{0} is not declared in the catalog".format(name)
        assert name in CORE_TOOLS, "{0} is missing from CORE_TOOLS".format(name)
        assert entry.bridge_method in bridges, \
            "{0} has no MAXScript handler ({1})".format(name, entry.bridge_method)
        assert entry.description_zh and entry.description_en
        problems = schema_problems(entry)
        assert not problems, "{0}: {1}".format(name, "; ".join(problems))


def check_required_parameters():
    catalog = build_catalog()
    for name, required in REQUIRED.items():
        entry = catalog.get(name)
        assert entry.schema.get("required") == required, \
            "{0}: required={1}, expected {2}".format(name, entry.schema.get("required"), required)
    # tools without mandatory input must not invent one
    for name in ("bridge_ping", "bridge_capabilities", "get_selection", "scene_save",
                 "poly_get_stats", "poly_get_selection", "mat_list"):
        assert not catalog.get(name).schema.get("required"), name


def check_safety_labels():
    catalog = build_catalog()
    for name in READ_ONLY:
        assert catalog.get(name).mutating is False, "{0} must be read-only".format(name)
    for name in DESTRUCTIVE:
        assert catalog.get(name).mutating is True, "{0} must be marked destructive".format(name)
    # scene_save writes a file: advertising it as read-only was wrong
    assert catalog.get("scene_save").mutating is True
    # overwriting an existing scene needs an explicit confirmation flag
    scenes = catalog.get("scene_save_as").schema["properties"]
    assert "confirm" in scenes and scenes["confirm"]["type"] == "boolean"


def check_bounds():
    catalog = build_catalog()
    turbosmooth = catalog.get("mod_turbosmooth").schema["properties"]
    assert turbosmooth["iterations"]["minimum"] == 0
    assert turbosmooth["iterations"]["maximum"] == 6
    assert turbosmooth["renderIterations"]["maximum"] == 6
    symmetry = catalog.get("mod_symmetry").schema["properties"]
    assert symmetry["axis"]["minimum"] == 0 and symmetry["axis"]["maximum"] == 2
    mat_list = catalog.get("mat_list").schema["properties"]
    assert mat_list["limit"]["minimum"] >= 1
    assert mat_list["offset"]["minimum"] >= 0
    weld = catalog.get("poly_weld_vertices").schema["properties"]
    assert weld["threshold"]["minimum"] == 0.0
    connect = catalog.get("poly_connect_edges").schema["properties"]
    assert connect["segments"]["minimum"] == 1


class CountingBridge:
    def __init__(self):
        self.calls = []

    def call(self, method, params=None):
        self.calls.append((method, params))
        return {"ok": True, "method": method}

    def status(self):
        return {"connected": True, "info": {"language": "en"}}


def server_with(fake):
    server = MaxMcpServer(Config(tool_profile="core", language="en"), NullTransport())
    server.bridge = fake
    server.runtime = type(server.runtime)(fake.call)
    server.batch = type(server.batch)(fake.call)
    return server


def call(server, name, arguments=None):
    reply = server.on_tools_call({"name": name, "arguments": arguments or {}})
    payload = json.loads(reply["content"][0]["text"])
    return reply, payload


def check_argument_validation_blocks_the_bridge():
    fake = CountingBridge()
    server = server_with(fake)

    reply, payload = call(server, "scene_open", {})
    assert reply["isError"] is True
    assert payload["error"]["code"] == "invalid_arguments"
    assert "path" in payload["error"]["message"]

    reply, payload = call(server, "mod_turbosmooth", {"iterations": 99})
    assert reply["isError"] is True
    assert "iterations" in payload["error"]["message"]

    reply, payload = call(server, "mat_list", {"limit": 0})
    assert reply["isError"] is True
    assert "limit" in payload["error"]["message"]

    reply, payload = call(server, "scene_open", {"path": "C:/x.max", "quiet": "maybe"})
    assert reply["isError"] is True
    assert "quiet" in payload["error"]["message"]

    assert fake.calls == [], "invalid arguments must never reach 3ds Max: %r" % (fake.calls,)


def check_execute_maxscript_surfaces_max_kind():
    """An empty script is rejected by Max; the reason must survive the round trip."""
    from maxmcp.bridge import BridgeCommandError

    class RejectingBridge(CountingBridge):
        def call(self, method, params=None):
            if method == "execute_maxscript":
                raise BridgeCommandError(
                    "Missing required parameter: code",
                    detail={"kind": "err.missing_param", "message": "Missing required parameter: code"},
                )
            return super().call(method, params)

    server = server_with(RejectingBridge())
    reply, payload = call(server, "execute_maxscript", {"code": ""})
    assert reply["isError"] is True
    assert payload["success"] is False
    assert payload["failures"][0]["kind"] == "invalid_arguments", payload["failures"]


def method_calls(fake, method):
    return [params for name, params in fake.calls if name == method]


def check_valid_arguments_reach_the_bridge():
    fake = CountingBridge()
    server = server_with(fake)
    reply, payload = call(server, "mat_list", {"limit": "5"})
    assert reply.get("isError", False) is False, payload
    assert method_calls(fake, "mat_list") == [{"limit": 5}]

    reply, _ = call(server, "poly_weld_vertices", {"vertices": [1, 2], "threshold": 0.1})
    assert reply.get("isError", False) is False
    assert method_calls(fake, "poly_weld_vertices") == [{"vertices": [1, 2], "threshold": 0.1}]

    reply, payload = call(server, "scene_save_as", {"path": "D:/tmp/out.max"})
    assert reply.get("isError", False) is False, payload
    assert method_calls(fake, "scene_save_as") == [{"path": "D:/tmp/out.max"}]


def check_case_insensitive_enum():
    fake = CountingBridge()
    server = server_with(fake)
    bridge_method = build_catalog().get("mod_symmetry").bridge_method
    reply, payload = call(server, "mod_symmetry", {"axis": 1, "flip": "TRUE"})
    assert reply.get("isError", False) is False, payload
    params = method_calls(fake, bridge_method)[-1]
    assert params["flip"] is True
    assert params["axis"] == 1


def main():
    check_registration()
    check_required_parameters()
    check_safety_labels()
    check_bounds()
    check_argument_validation_blocks_the_bridge()
    check_execute_maxscript_surfaces_max_kind()
    check_valid_arguments_reach_the_bridge()
    check_case_insensitive_enum()
    print("core tool validation: all checks passed ({0} tools audited)".format(len(NO_LIVE_CASE)))


if __name__ == "__main__":
    main()
