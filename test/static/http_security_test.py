"""Static checks for the HTTP exposure guard (no 3ds Max required).

Covers the P0 rule: a non-loopback HTTP endpoint without a bearer token must be
refused at startup, while the loopback/no-token default keeps working so local
MCP clients are unaffected.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.http_transport import (  # noqa: E402
    McpHttpTransport,
    UnsafeExposureError,
    is_loopback_host,
)


def _dispatch(_msg):
    return None


def main() -> None:
    # 1. Address classification: only genuine loopback addresses are trusted,
    #    and wildcard/unknown names fail closed (treated as exposed).
    for addr in ("127.0.0.1", "127.0.0.2", "localhost", "::1", "ip6-localhost"):
        assert is_loopback_host(addr), addr
    for addr in ("0.0.0.0", "::", "192.168.1.10", "", "example.com"):
        assert not is_loopback_host(addr), addr

    # 2. A non-loopback bind without a token is refused BEFORE any socket opens.
    exposed = McpHttpTransport(_dispatch, host="0.0.0.0", port=0, token=None, log=lambda _text: None)
    assert not exposed.is_loopback
    assert exposed.require_token
    try:
        exposed.start()
    except UnsafeExposureError:
        pass
    else:
        raise AssertionError("non-loopback without token must be refused at start()")

    # 3. The loopback/no-token default stays available for local MCP clients.
    local = McpHttpTransport(_dispatch, host="127.0.0.1", port=0, token=None, log=lambda _text: None)
    assert local.is_loopback
    assert not local.require_token
    try:
        local.start()
        assert local.port > 0, "port 0 should resolve to a real bound port"
        assert local.is_loopback  # re-derived from the actual bound address
        assert local.warn_if_exposed() is None
    finally:
        local.stop()

    # 4. A non-loopback bind WITH a token is allowed, and reports exposure so
    #    the caller prints a warning. Use a loopback-aliased address to avoid
    #    binding a real NIC in CI, then override state to exercise the policy.
    secured = McpHttpTransport(_dispatch, host="127.0.0.1", port=0, token="s3cr3t", log=lambda _text: None)
    try:
        secured.start()
        # Simulate the post-bind classification of an exposed socket.
        secured.is_loopback = False
        assert secured.warn_if_exposed() is not None
    finally:
        secured.stop()

    print("http security policy: all checks passed")


if __name__ == "__main__":
    main()
