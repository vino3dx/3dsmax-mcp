"""Run a local .ms file inside 3ds Max through the MCP bridge (dev helper)."""
import json
import os
import sys
import urllib.request

URL = os.environ.get("MAXMCP_URL", "http://127.0.0.1:8771/mcp")
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(tool, args, timeout=3600):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": args}}).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return {"http_error": exc.code, "body": exc.read().decode("utf-8", "replace")}


def main():
    if len(sys.argv) < 2:
        print("usage: run_ms.py <file.ms> [--raw code]")
        return 2
    if sys.argv[1] == "--raw":
        code = sys.argv[2]
    else:
        path = sys.argv[1].replace("/", "\\")
        code = 'fileIn @"' + path + '"'
    out = call("execute_maxscript", {"code": code})
    if "http_error" in out:
        print("HTTP", out["http_error"], out["body"])
        return 1
    res = out.get("result", out)
    if isinstance(res, dict) and res.get("isError"):
        print("TOOL ERROR")
    for part in (res.get("content") or []):
        if part.get("type") == "text":
            print(part.get("text", ""))
    if not (res.get("content") or []):
        print(json.dumps(out, ensure_ascii=False, indent=2)[:2000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
