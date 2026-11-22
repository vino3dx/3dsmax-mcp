"""Schema -> Python contract for modifier parameter types.

No 3ds Max required.  This locks down defect #1 and the Python half of defect
#2 from the T15 brief; the MAXScript half (conversion, read-back) is proven by
``test/live/modifier_param_types_test.py`` against a real Max.

The two defects, both on the catalog <-> handler boundary:

  1. ``mod_add.params`` / ``mod_set_params.params`` were declared as an
     **array**.  ``server._coerce`` therefore wrapped the caller's object in a
     one-element list, MAXScript's ``mcpIsObj`` said "not an object", and
     ``mcpPairs`` returned ``#()``: every parameter was dropped while the
     handler still reported success.

  2. ``mod_set_param.value`` was declared as a **string**.  ``_coerce``
     stringified every argument, so ``3`` arrived in MAXScript as ``"3"`` and
     ``setProperty`` refused it on numeric properties.  The live matrix missed
     this because it talks to the bridge directly and never crosses _coerce.

What this test pins:
  * the declared type of each of those three parameters;
  * ``_coerce`` passing an object through untouched (no wrapping, no str());
  * ``_coerce`` preserving int / float / str / bool for the union-typed value;
  * ``_coerce`` refusing a list or dict for the union-typed value;
  * the payload that actually reaches the bridge keeping those JSON types.

Usage:  python test/static/modifier_param_types_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(REPO, "src", "python")
if SRC not in sys.path:
    sys.path.insert(0, SRC)

from maxmcp.catalog import build_catalog  # noqa: E402
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.server import MaxMcpServer, _coerce  # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


class RecordingBridge:
    """Accepts every call and remembers the payload that was sent."""

    def __init__(self):
        self.calls = []

    def call(self, method, params=None):
        self.calls.append((method, params))
        return {"applied": ["probe"], "appliedParams": ["probe.iterations"],
                "rejected": [], "failures": [], "partial": False, "success": True}

    def status(self):
        return {"connected": True, "info": {"language": "en", "maxLanguage": "ENU"}}


def payload_for(tool_name, arguments):
    server = MaxMcpServer(Config(tool_profile="full", language="en"), NullTransport())
    bridge = RecordingBridge()
    server.bridge = bridge
    server.on_tools_call({"name": tool_name, "arguments": arguments})
    for method, params in bridge.calls:
        if method == tool_name:
            return params
    return {}


def main() -> int:
    catalog = build_catalog()

    print("1. `params` is declared as an object, not an array")
    for tool_name in ("mod_add", "mod_set_params"):
        spec = catalog.get(tool_name).schema["properties"]["params"]
        check("{0}.params type is object".format(tool_name), spec.get("type") == "object",
              "got {0!r}".format(spec.get("type")))
        check("{0}.params allows caller-chosen keys".format(tool_name),
              spec.get("additionalProperties") is True, str(spec.get("additionalProperties")))

    print("2. `value` keeps its JSON type")
    value_spec = catalog.get("mod_set_param").schema["properties"]["value"]
    check("mod_set_param.value has no string type", value_spec.get("type") != "string")
    declared = value_spec.get("type")
    declared = declared if isinstance(declared, (list, tuple)) else [declared]
    for wanted in ("integer", "number", "string", "boolean"):
        check("declares {0}".format(wanted), wanted in declared, str(declared))

    print("3. _coerce preserves the object")
    params_spec = catalog.get("mod_set_params").schema["properties"]["params"]
    original = {"iterations": 2, "isolineDisplay": True}
    coerced = _coerce(original, params_spec, "params")
    check("object stays an object", isinstance(coerced, dict), type(coerced).__name__)
    check("object is not wrapped in a list", not isinstance(coerced, list))
    check("object values are untouched", coerced == original, repr(coerced))
    check("a JSON string holding an object is parsed",
          _coerce('{"angle": 45.5}', params_spec, "params") == {"angle": 45.5})
    try:
        _coerce([{"a": 1}], params_spec, "params")
        check("a list is refused", False, "no ValueError")
    except ValueError:
        check("a list is refused", True)

    print("4. _coerce preserves scalar types")
    for value, expected_type in ((3, int), (2.5, float), ("45", str), (True, bool)):
        out = _coerce(value, value_spec, "value")
        check("{0!r} stays {1}".format(value, expected_type.__name__),
              type(out) is expected_type, "got {0!r}".format(out))
    check("integer is not stringified", _coerce(3, value_spec, "value") == 3)
    check("float is not truncated", _coerce(2.5, value_spec, "value") == 2.5)
    for bad in ([1, 2], {"a": 1}):
        try:
            _coerce(bad, value_spec, "value")
            check("refuses {0}".format(type(bad).__name__), False, "no ValueError")
        except ValueError:
            check("refuses {0}".format(type(bad).__name__), True)

    print("5. the payload reaching the bridge keeps those types")
    sent = payload_for("mod_set_param", {"modifier": "Bend", "param": "angle", "value": 45.5})
    check("value arrives as a float", isinstance(sent.get("value"), float), repr(sent.get("value")))
    sent = payload_for("mod_set_param", {"modifier": "Bend", "param": "angle", "value": 45})
    check("integer value arrives as an int", type(sent.get("value")) is int, repr(sent.get("value")))
    sent = payload_for("mod_set_param", {"modifier": "TurboSmooth", "param": "isolineDisplay",
                                         "value": "true"})
    check("string value arrives as a string", sent.get("value") == "true", repr(sent.get("value")))
    sent = payload_for("mod_set_params", {"modifier": "TurboSmooth",
                                          "params": {"iterations": 2, "isolineDisplay": True}})
    check("batch params arrive as an object", isinstance(sent.get("params"), dict),
          repr(sent.get("params")))
    check("batch values keep their types",
          sent.get("params") == {"iterations": 2, "isolineDisplay": True}, repr(sent.get("params")))
    sent = payload_for("mod_add", {"modifier": "Bend", "objects": ["probe"],
                                   "params": {"angle": 30}})
    check("mod_add params arrive as an object", isinstance(sent.get("params"), dict),
          repr(sent.get("params")))

    print("6. an unusable value is a validation error, not a silent call")
    server = MaxMcpServer(Config(tool_profile="full", language="en"), NullTransport())
    bridge = RecordingBridge()
    server.bridge = bridge
    result = server.on_tools_call({"name": "mod_set_param",
                                   "arguments": {"modifier": "Bend", "param": "angle",
                                                 "value": {"nested": 1}}})
    check("dict value is rejected", result.get("isError") is True, str(result)[:200])
    check("no bridge call was made", bridge.calls == [], str(bridge.calls))

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("modifier parameter types: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
