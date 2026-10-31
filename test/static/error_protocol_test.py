"""Offline tests for the unified error protocol.

Covers the three places a failure used to lose information:

1. ``MaxBridge._parse`` - the MAXScript ``kind`` was dropped, so every bridge
   failure arrived as ``command_error``.
2. ``wire.from_wire`` - already-decoded Chinese diagnostics were decoded twice.
3. ``SceneRuntime`` / server envelope - empty payloads and "not verified" states
   could read as success.

The bridge is exercised through a stub socket so the real ``_parse`` and framing
code runs, not a re-implementation of it.
"""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp import errors  # noqa: E402
from maxmcp.bridge import (  # noqa: E402
    BridgeDisconnected,
    BridgeProtocolError,
    BridgeTimeout,
    MaxBridge,
)
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.runtime import SceneRuntime  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402
from maxmcp.wire import from_wire, to_wire  # noqa: E402


class StubSocket:
    """Minimal socket replacement: yields the scripted bytes, records writes."""

    def __init__(self, payload: bytes, drop_after=False):
        self.payload = payload
        self.drop_after = drop_after
        self.sent = []
        self.closed = False
        self._served = False

    def sendall(self, data):
        self.sent.append(data)

    def settimeout(self, timeout):
        pass

    def recv(self, size):
        if not self._served:
            self._served = True
            return self.payload
        if self.drop_after:
            return b""
        return b""

    def close(self):
        self.closed = True


def bridge_with(payload: bytes, drop_after=False) -> MaxBridge:
    bridge = MaxBridge(Config(language="en"))
    bridge._sock = StubSocket(payload, drop_after=drop_after)
    return bridge


def reply(payload, ok=True):
    body = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
    return ('{"id":1,"ok":%s,"result":%s}\n' % ("true" if ok else "false", body)).encode("ascii")


def error_reply(kind: str, message: str) -> bytes:
    """Build a MAXScript-style error reply, ANSI-escaped exactly like mcp_net.ms."""
    wire_message = to_wire(message)
    return (
        '{"id":1,"ok":false,"error":{"kind":"%s","message":%s}}\n'
        % (kind, json.dumps(wire_message, ensure_ascii=True))
    ).encode("ascii")


def check_classification_table():
    expected = {
        "err.node_not_found": "object_not_found",
        "err.missing_param": "invalid_arguments",
        "err.bad_value": "invalid_arguments",
        "err.no_selection": "empty_selection",
        "err.class_missing": "unsupported_class",
        "err.poly_required": "wrong_object_type",
        "err.file_missing": "file_not_found",
        "err.confirm_required": "confirmation_required",
        "err.unknown_method": "unknown_method",
        "err.not_found_in_list": "item_not_found",
        "err.render_engine": "render_engine_unavailable",
        "err.element_api_missing": "unsupported_feature",
        "runtime_error": "max_runtime_error",
        "not_running": "bridge_not_running",
        "timeout": "bridge_timeout",
        "protocol_error": "bridge_protocol_error",
        "disconnected": "bridge_disconnected",
        "command_error": "max_command_failed",
        "": "max_command_failed",
    }
    for raw, code in expected.items():
        assert errors.classify(raw) == code, (raw, errors.classify(raw), code)
    # an undocumented kind is preserved, never flattened
    assert errors.classify("err.custom_thing") == "err.custom_thing"
    # every documented code has a spec
    from maxmcp.errors import MAX_ERROR_MAP, BRIDGE_KIND_MAP
    for code in set(MAX_ERROR_MAP.values()) | set(BRIDGE_KIND_MAP.values()):
        assert code in errors.ERROR_SPECS, code


def check_documentation_lists_every_code():
    """docs/ERROR_CODES.md must not drift from errors.py."""
    doc = (ROOT / "docs" / "ERROR_CODES.md").read_text(encoding="utf-8")
    missing = sorted(code for code in errors.ERROR_SPECS if "`{0}`".format(code) not in doc)
    assert not missing, "undocumented error codes: " + ", ".join(missing)


def check_bridge_error_kind_survives():
    bridge = bridge_with(error_reply("err.node_not_found", "找不到对象：Box001"))
    try:
        bridge.call("get_object_info", {"name": "Box001"})
    except Exception as exc:  # noqa: BLE001
        assert exc.code == "object_not_found", exc.code
        assert exc.max_kind == "err.node_not_found"
        assert "找不到对象" in str(exc), str(exc)
        assert exc.detail["kind"] == "err.node_not_found"
    else:
        raise AssertionError("bridge should have raised")


def check_success_payload():
    bridge = bridge_with(reply({"name": "Box001"}))
    assert bridge.call("create_box", {}) == {"name": "Box001"}


def check_empty_result_is_none():
    bridge = bridge_with(b'{"id":1,"ok":true,"result":null}\n')
    assert bridge.call("some_command", {}) is None


def check_invalid_json():
    bridge = bridge_with(b'{"id":1,"ok":true,"result":oops}\n')
    try:
        bridge.call("x", {})
    except BridgeProtocolError as exc:
        assert exc.kind == "protocol_error"
        assert errors.classify(exc.kind) == "bridge_protocol_error"
    else:
        raise AssertionError("invalid JSON must raise BridgeProtocolError")


def check_non_object_json():
    bridge = bridge_with(b'[1,2,3]\n')
    try:
        bridge.call("x", {})
    except BridgeProtocolError:
        pass
    else:
        raise AssertionError("a non-object reply must be a protocol error")


def check_empty_line():
    bridge = bridge_with(b'\n')
    try:
        bridge.call("x", {})
    except BridgeProtocolError as exc:
        assert "<empty>" in str(exc)
    else:
        raise AssertionError("an empty reply must be a protocol error")


def check_disconnect_mid_request():
    bridge = bridge_with(b"", drop_after=True)
    try:
        bridge.call("x", {})
    except BridgeDisconnected as exc:
        assert exc.kind == "disconnected"
        assert errors.classify(exc.kind) == "bridge_disconnected"
    else:
        raise AssertionError("a closed socket must raise BridgeDisconnected")


def check_wire_decode_is_idempotent():
    chinese = "找不到对象：Box001"
    encoded = to_wire(chinese)
    assert encoded != chinese
    decoded = from_wire(encoded)
    assert decoded == chinese
    # decoding twice must not corrupt an already-decoded diagnostic
    assert from_wire(decoded) == chinese
    # pure ASCII stays identity in both directions
    assert from_wire("Box001") == "Box001"
    # nested structures are handled the same way
    assert from_wire({"a": [encoded], "b": 3}) == {"a": [chinese], "b": 3}


def check_runtime_empty_payload_warning():
    runtime = SceneRuntime(lambda method, params: {"objectCount": 0} if method == "scene_info" else None)
    record = runtime.execute("transform_object", "transform_object", {"objects": ["Box001"]})
    assert record.success is True
    assert record.verification.performed is False
    assert record.verification.passed is None
    assert record.warnings and "unverified" in record.warnings[0]["message"]
    assert record.as_dict()["verification"]["performed"] is False


def check_runtime_error_kinds():
    def call(method, params):
        if method == "scene_info":
            return {"objectCount": 1}
        raise BridgeTimeout("no reply")

    record = SceneRuntime(call).execute("create_box", "create_box")
    assert record.success is False
    failure = record.failures[0]
    assert failure["kind"] == "bridge_timeout"
    assert failure["retryable"] is True
    assert failure["stage"] == "execute"


def check_server_error_envelope():
    class FailingBridge:
        def call(self, method, params=None):
            raise BridgeTimeout("no reply from Max")

        def status(self):
            return {"connected": False, "kind": "timeout"}

    # full profile: the bridge call raises straight out of on_tools_call
    server = MaxMcpServer(Config(tool_profile="full", language="en"), NullTransport())
    server.bridge = FailingBridge()
    reply_payload = server.on_tools_call({"name": "create_box", "arguments": {"class": "Box"}})
    assert reply_payload["isError"] is True
    error = json.loads(reply_payload["content"][0]["text"])["error"]
    assert error["code"] == "bridge_timeout"
    assert error["kind"] == "timeout"
    assert error["retryable"] is True
    assert error["tool"] == "create_box"

    # core profile: the Scene Runtime converts it into a result envelope whose
    # failure keeps the same stable code
    core = MaxMcpServer(Config(tool_profile="core", language="en"), NullTransport())
    core.bridge = FailingBridge()
    core.runtime = SceneRuntime(core.bridge.call)
    core_reply = core.on_tools_call({"name": "create_box", "arguments": {"class": "Box"}})
    assert core_reply["isError"] is True
    envelope = json.loads(core_reply["content"][0]["text"])
    assert envelope["success"] is False
    assert envelope["failures"][0]["kind"] == "bridge_timeout"
    assert envelope["failures"][0]["stage"] == "before"


def check_no_bridge_no_false_success():
    """A bridge that was never started must never look like a successful edit."""
    server = MaxMcpServer(Config(tool_profile="core", language="en"), NullTransport())
    server.bridge = MaxBridge(Config(port=1, port_scan=1, connect_timeout_s=0.05))
    server.runtime = SceneRuntime(server.bridge.call)
    server.batch = type(server.batch)(server.bridge.call)
    reply_payload = server.on_tools_call(
        {"name": "create_box", "arguments": {"class": "Box"}})
    assert reply_payload["isError"] is True
    envelope = json.loads(reply_payload["content"][0]["text"])
    assert envelope["success"] is False
    assert envelope["failures"][0]["kind"] == "bridge_not_running", envelope
    assert envelope["verification"]["performed"] is False
    assert envelope["changed"] is False


def main():
    check_classification_table()
    check_documentation_lists_every_code()
    check_bridge_error_kind_survives()
    check_success_payload()
    check_empty_result_is_none()
    check_invalid_json()
    check_non_object_json()
    check_empty_line()
    check_disconnect_mid_request()
    check_wire_decode_is_idempotent()
    check_runtime_empty_payload_warning()
    check_runtime_error_kinds()
    check_server_error_envelope()
    check_no_bridge_no_false_success()
    print("error protocol: all checks passed")


if __name__ == "__main__":
    main()
