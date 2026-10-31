"""Integration-level proof that the core profile wires Scene Runtime into MCP."""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.config import Config
from maxmcp.protocol import NullTransport
from maxmcp.runtime import SceneRuntime
from maxmcp.server import MaxMcpServer


class FakeBridge:
    def __init__(self, fail_after=False, fail_operation=False):
        self.calls = []
        self.objects = 0
        self.fail_after = fail_after
        self.fail_operation = fail_operation

    def call(self, method, params=None):
        self.calls.append(method)
        if method == "scene_info":
            if self.fail_after and len([x for x in self.calls if x == "scene_info"]) == 2:
                raise RuntimeError("readback unavailable")
            return {"objectCount": self.objects}
        if method == "create_box":
            if self.fail_operation:
                return {"success": False, "message": "primitive rejected"}
            self.objects += 1
            return {"created": True}
        if method == "bridge_status":
            return {"language": "en", "maxLanguage": "ENU"}
        return {"ok": True}

    def status(self):
        return {"connected": True, "info": {"language": "en", "maxLanguage": "ENU"}}


def call_with(fake):
    server = MaxMcpServer(Config(tool_profile="core", language="en"), NullTransport())
    server.bridge = fake
    server.runtime = SceneRuntime(fake.call)
    return server.on_tools_call({"name": "create_box", "arguments": {"class": "Box"}})


def main():
    fake = FakeBridge()
    reply = call_with(fake)
    text = reply["content"][0]["text"]
    payload = json.loads(text)
    assert reply.get("isError", False) is False
    assert payload["success"] is True
    assert payload["changed"] is True
    assert payload["verification"]["performed"] is True
    assert payload["verification"]["passed"] is True
    assert fake.calls[:3] == ["scene_info", "create_box", "scene_info"]

    failed = call_with(FakeBridge(fail_after=True))
    assert failed["isError"] is True
    assert json.loads(failed["content"][0]["text"])["success"] is False

    operation_failed = call_with(FakeBridge(fail_operation=True))
    assert operation_failed["isError"] is True
    operation_payload = json.loads(operation_failed["content"][0]["text"])
    assert operation_payload["success"] is False
    assert operation_payload["failures"][0]["kind"] == "operation_failed"
    print("runtime server integration: all checks passed")


if __name__ == "__main__":
    main()
