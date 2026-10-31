"""Ad-hoc JSON-RPC client for the local 3dsmax-mcp HTTP endpoint (dev helper)."""
import json
import os
import sys
import urllib.request

URL = os.environ.get("MAXMCP_URL", "http://127.0.0.1:8771/mcp")
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def rpc(method, params, rid=1):
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=1800) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        return {"http_error": exc.code, "body": raw}


def main():
    if len(sys.argv) < 2:
        print("usage: _call.py <tool> [args.json|-]")
        return 2
    tool = sys.argv[1]
    args = {}
    if len(sys.argv) > 2:
        raw = sys.stdin.read() if sys.argv[2] == "-" else open(sys.argv[2], "r", encoding="utf-8").read()
        args = json.loads(raw) if raw.strip() else {}
    out = rpc("tools/call", {"name": tool, "arguments": args})
    res = out.get("result", out)
    if isinstance(res, dict) and "content" in res:
        for part in res["content"]:
            if part.get("type") == "text":
                print(part.get("text", ""))
    else:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
