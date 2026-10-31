"""Offline end-to-end acceptance for the whole chain.

    JSON-RPC dispatch -> MaxMcpServer -> MaxBridge (real socket) -> stub bridge

The stub is a real TCP server speaking the newline-delimited JSON protocol, so
framing, timeouts, disconnects and the error envelope are exercised for real.  It
never pretends to be 3ds Max: every case is about *failure handling*, plus one
successful image round trip whose bytes are generated locally.

Groups (mirroring docs/OVERNIGHT_ACCEPTANCE.md):
  Bridge   not running / timeout / invalid JSON / empty reply / MAXScript error /
           mid-request disconnect
  Runtime  success / failure / partial / argument error / timeout / unverified /
           verification failed
  Batch    empty / single / multiple / partial / all failed / duplicates
  Refs     normal / missing / ambiguous / stale / invalid
  Visual   image block, missing file, corrupt file, MIME correction, budget
"""

import base64
import json
from pathlib import Path
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from maxmcp.batch import BatchExecutor  # noqa: E402
from maxmcp.bridge import (  # noqa: E402
    BridgeDisconnected,
    BridgeNotRunning,
    BridgeProtocolError,
    BridgeTimeout,
    MaxBridge,
)
from maxmcp.config import Config  # noqa: E402
from maxmcp.protocol import NullTransport  # noqa: E402
from maxmcp.runtime import SceneRuntime, resolve_object_refs  # noqa: E402
from maxmcp.server import MaxMcpServer  # noqa: E402

from fake_scene import FakeScene  # noqa: E402

PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


# --------------------------------------------------------------------- stub bridge
class BridgeStub:
    """A one-purpose TCP bridge used to provoke specific transport failures."""

    def __init__(self, responder):
        self.responder = responder
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(4)
        self.port = self._server.getsockname()[1]
        self._stop = False
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with conn:
            buffer = b""
            while not self._stop:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        request = json.loads(line.decode("ascii"))
                    except ValueError:
                        return
                    payload = self.responder(request.get("method", ""), request.get("params") or {})
                    if payload is None:
                        return
                    try:
                        conn.sendall(payload)
                    except OSError:
                        return

    def close(self):
        self._stop = True
        try:
            self._server.close()
        except OSError:
            pass


def ok_reply(request_id, result):
    return (json.dumps({"id": request_id, "ok": True, "result": result},
                       ensure_ascii=True) + "\n").encode("ascii")


def max_error(request_id, kind, message):
    from maxmcp.wire import to_wire
    body = json.dumps({"kind": kind, "message": to_wire(message)}, ensure_ascii=True)
    return ('{"id":%d,"ok":false,"error":%s}\n' % (request_id, body)).encode("ascii")


def bridge_to(port, timeout=2.0, profile="core"):
    config = Config(port=port, port_scan=1, connect_timeout_s=0.5, timeout_s=timeout,
                    tool_profile=profile, language="en")
    return MaxBridge(config)


def server_to(port, timeout=2.0, profile="core"):
    server = MaxMcpServer(Config(port=port, port_scan=1, connect_timeout_s=0.5,
                                 timeout_s=timeout, tool_profile=profile, language="en"),
                          NullTransport())
    return server


def call_tool(server, name, arguments=None):
    reply = server.on_tools_call({"name": name, "arguments": arguments or {}})
    text = reply["content"][0]["text"]
    payload = json.loads(text) if text.strip().startswith(("{", "[")) else text
    return reply, payload


# ------------------------------------------------------------------------- bridge
def check_bridge_not_running():
    # port 1 on loopback is refused immediately on every platform we ship to
    bridge = MaxBridge(Config(port=1, port_scan=1, connect_timeout_s=0.2, language="en"))
    try:
        bridge.call("bridge_ping", {})
    except BridgeNotRunning as exc:
        assert exc.kind == "not_running"
    else:
        raise AssertionError("a missing bridge must raise BridgeNotRunning")


def check_bridge_timeout():
    stub = BridgeStub(lambda method, params: time.sleep(1.0) or b"")
    try:
        bridge = bridge_to(stub.port, timeout=0.25)
        started = time.time()
        try:
            bridge.call("scene_info", {})
        except BridgeTimeout as exc:
            assert exc.kind == "timeout"
            assert time.time() - started < 3.0
        else:
            raise AssertionError("a silent bridge must raise BridgeTimeout")
    finally:
        stub.close()


def check_bridge_invalid_json():
    stub = BridgeStub(lambda method, params: b'{"id":1,"ok":true,"result":oops}\n')
    try:
        bridge = bridge_to(stub.port)
        try:
            bridge.call("scene_info", {})
        except BridgeProtocolError as exc:
            assert "protocol" in exc.kind or exc.kind == "protocol_error"
        else:
            raise AssertionError("invalid JSON must raise BridgeProtocolError")
    finally:
        stub.close()


def check_bridge_empty_reply():
    stub = BridgeStub(lambda method, params: b"\n")
    try:
        bridge = bridge_to(stub.port)
        try:
            bridge.call("scene_info", {})
        except BridgeProtocolError as exc:
            assert "<empty>" in str(exc)
        else:
            raise AssertionError("an empty reply must raise BridgeProtocolError")
    finally:
        stub.close()


def check_bridge_max_error():
    stub = BridgeStub(lambda method, params: max_error(1, "err.node_not_found", "找不到对象：Box001"))
    try:
        bridge = bridge_to(stub.port)
        try:
            bridge.call("get_object_info", {"name": "Box001"})
        except Exception as exc:  # noqa: BLE001
            assert exc.code == "object_not_found", exc
            assert "找不到对象" in str(exc)
        else:
            raise AssertionError("a MAXScript error must surface as an exception")
    finally:
        stub.close()


def check_bridge_disconnect():
    stub = BridgeStub(lambda method, params: None)
    try:
        bridge = bridge_to(stub.port)
        try:
            bridge.call("scene_info", {})
        except BridgeDisconnected as exc:
            assert exc.kind == "disconnected"
        else:
            raise AssertionError("a dropped connection must raise BridgeDisconnected")
    finally:
        stub.close()


# ------------------------------------------------------------------------ runtime
def check_runtime_success():
    calls = []
    states = [{"objectCount": 0}, {"objectCount": 1}]

    def fake(method, params):
        calls.append(method)
        return states.pop(0) if method == "scene_info" else {"success": True}

    record = SceneRuntime(fake).execute("create_box", "create_box", {"class": "Box"})
    assert record.success is True
    assert record.changed is True
    assert record.verification.performed is True
    assert record.verification.passed is True
    assert calls == ["scene_info", "create_box", "scene_info"]


def check_runtime_failure():
    record = SceneRuntime(lambda method, params: (
        {"objectCount": 1} if method == "scene_info" else {"success": False, "message": "rejected"}
    )).execute("create_box", "create_box")
    assert record.success is False
    assert record.failures[0]["kind"] == "operation_failed"


def check_runtime_partial_is_not_success():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    payload = BatchExecutor(scene.call).run(
        "transform_object", "transform_object",
        {"objects": ["Box001", "Box002", "Ghost"], "operation": "move", "value": [0, 0, 1]})
    assert payload["success"] is False
    assert payload["summary"]["succeeded"] == 2


def check_runtime_argument_error():
    server = server_to(1)
    reply, payload = call_tool(server, "scene_open", {})
    assert reply["isError"] is True
    assert payload["error"]["code"] == "invalid_arguments"


def check_runtime_timeout_envelope():
    stub = BridgeStub(lambda method, params: time.sleep(1.0) or b"")
    try:
        server = server_to(stub.port, timeout=0.25)
        reply, payload = call_tool(server, "create_box", {"class": "Box"})
        assert reply["isError"] is True
        assert payload["failures"][0]["kind"] == "bridge_timeout"
        assert payload["verification"]["performed"] is False
    finally:
        stub.close()


def check_runtime_unverified():
    record = SceneRuntime(lambda method, params: (
        {"objectCount": 1} if method == "scene_info" else {"success": True}
    )).execute("mat_assign", "mat_assign", {"material": "Red"})
    assert record.verification.performed is False
    assert record.verification.passed is None


def check_runtime_verification_failure():
    record = SceneRuntime(lambda method, params: (
        {"objectCount": 0} if method == "scene_info" else {"success": True}
    )).execute("create_box", "create_box")
    assert record.success is False
    assert record.verification.passed is False
    assert record.failures[0]["kind"] == "verification_failed"


# -------------------------------------------------------------------------- batch
def check_batch_matrix():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Box002")
    executor = BatchExecutor(scene.call)

    empty = executor.run("transform_object", "transform_object", {"objects": []})
    assert empty["scope"] == "selection"

    single = executor.run("transform_object", "transform_object",
                          {"objects": ["Box001"], "operation": "move", "value": [0, 0, 1]})
    assert single["success"] is True and single["summary"]["total"] == 1

    multi = executor.run("transform_object", "transform_object",
                         {"objects": ["Box001", "Box002"], "operation": "move", "value": [0, 0, 1]})
    assert multi["success"] is True and multi["summary"]["succeeded"] == 2

    partial = executor.run("transform_object", "transform_object",
                           {"objects": ["Box001", "Ghost"], "operation": "move", "value": [0, 0, 1]})
    assert partial["success"] is False and partial["summary"]["failed"] == 1

    everything = executor.run("transform_object", "transform_object",
                              {"objects": ["Gone1", "Gone2"], "operation": "move", "value": [0, 0, 1]})
    assert everything["success"] is False
    assert [item["kind"] for item in everything["failures"]] == ["batch_failed"]

    duplicate = executor.run("transform_object", "transform_object",
                             {"objects": ["Box001", "Box001"], "operation": "move", "value": [0, 0, 1]})
    assert duplicate["summary"]["total"] == 1
    assert duplicate["warnings"][0]["kind"] == "duplicate_object_in_request"


# --------------------------------------------------------------------- references
def check_reference_matrix():
    scene = FakeScene()
    scene.add("Box001")
    scene.add("Dup")
    scene.add("Dup")
    executor = BatchExecutor(scene.call)

    rows = resolve_object_refs(
        ["Box001", "Ghost", "Dup", "", 12],
        [{"name": "Box001", "handle": 1}, {"name": "Dup", "handle": 2}, {"name": "Dup", "handle": 3}],
    )
    assert [row["success"] for row in rows] == [True, False, False, False, False]
    assert rows[1]["error"]["kind"] == "stale_object_reference"
    assert rows[2]["error"]["kind"] == "ambiguous_object"
    assert rows[3]["error"]["kind"] == "invalid_object_reference"
    assert rows[4]["error"]["kind"] == "invalid_object_reference"

    ambiguous = executor.run("delete_objects", "delete_objects", {"objects": ["Dup"]})
    assert ambiguous["objects"][0]["error"]["kind"] == "ambiguous_object"


# ------------------------------------------------------------------------- visual
def check_visual_round_trip_through_mcp():
    payload = {
        "count": 1,
        "views": ["perspective"],
        "_images": [{"label": "perspective", "data": base64.b64encode(PNG_BYTES).decode("ascii"),
                     "mime": "image/png"}],
    }
    stub = BridgeStub(lambda method, params: ok_reply(1, payload))
    try:
        server = server_to(stub.port, profile="full")
        reply, text_payload = call_tool(server, "vision_capture", {"max_edge": 320})
        assert reply.get("isError", False) is False, text_payload
        assert reply["content"][0]["type"] == "text"
        assert text_payload["count"] == 1
        assert "_images" not in text_payload
        images = [block for block in reply["content"] if block["type"] == "image"]
        assert len(images) == 1
        assert images[0]["mimeType"] == "image/png"
        assert base64.b64decode(images[0]["data"]) == PNG_BYTES
    finally:
        stub.close()


def check_visual_errors_are_reported():
    payload = {
        "_images": [
            {"label": "missing", "path": str(Path(ROOT) / "does-not-exist.png")},
            {"label": "corrupt", "data": base64.b64encode(b"nope").decode("ascii")},
        ]
    }
    stub = BridgeStub(lambda method, params: ok_reply(1, payload))
    try:
        server = server_to(stub.port, profile="full")
        reply, text_payload = call_tool(server, "vision_capture", {})
        assert reply["isError"] is True, "an unusable image must be an error result"
        assert [block["type"] for block in reply["content"]] == ["text"]
        assert len(text_payload["image_errors"]) == 2
    finally:
        stub.close()


def main():
    check_bridge_not_running()
    check_bridge_timeout()
    check_bridge_invalid_json()
    check_bridge_empty_reply()
    check_bridge_max_error()
    check_bridge_disconnect()
    check_runtime_success()
    check_runtime_failure()
    check_runtime_partial_is_not_success()
    check_runtime_argument_error()
    check_runtime_timeout_envelope()
    check_runtime_unverified()
    check_runtime_verification_failure()
    check_batch_matrix()
    check_reference_matrix()
    check_visual_round_trip_through_mcp()
    check_visual_errors_are_reported()
    print("offline acceptance: all checks passed")


if __name__ == "__main__":
    main()
