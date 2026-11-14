"""Round-trip check: the autoloader install.py writes must parse in doctor.py.

No 3ds Max required.  This exists because the two sides disagreed for months
without anyone noticing: install.py writes

    mcpLoaderBridgeFile = @"C:\\...\\mcp_bridge.ms"

and doctor.py looked for

    local bridgeFile = @"..."

so a healthy install was reported as "broken autoloader".  A unit test on either
side alone would have passed; only the round trip fails.

Checks:
  1. the real STARTUP_TEMPLATE, rendered with a Windows path, parses back to
     exactly that path;
  2. the legacy `local bridgeFile = @"..."` shape still parses (installs from
     older releases are upgraded in place, not reinstalled);
  3. a comment line containing `@"` is ignored;
  4. CRLF endings and trailing whitespace do not break it;
  5. a loader with no assignment returns "" (doctor then says "could not
     parse", which is the honest answer).

Usage:  python test/static/doctor_loader_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "scripts"))

import doctor  # noqa: E402
import install  # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def main() -> int:
    bridge = r"C:\Users\tester\AppData\Local\Autodesk\3dsMax\2022 - 64bit\ENU\scripts\3dsmax-mcp\mcp_bridge.ms"

    print("1. STARTUP_TEMPLATE round trip")
    text = install.STARTUP_TEMPLATE.format(app="3dsmax-mcp", bridge=bridge)
    check("rendered template parses back to the same path",
          doctor.parse_autoloader_target(text) == bridge,
          "got {0!r}".format(doctor.parse_autoloader_target(text)))
    check("the template still assigns it to a bridge-named variable",
          "mcpLoaderBridgeFile" in text.split('@"')[0].splitlines()[-1])

    print("2. legacy shape")
    legacy = 'local bridgeFile = @"C:\\old\\mcp_bridge.ms"'
    check("local bridgeFile = @\"...\" parses",
          doctor.parse_autoloader_target(legacy) == r"C:\old\mcp_bridge.ms")

    print("3. comments are not assignments")
    commented = (
        '-- example: bridgeFile = @"C:\\nope\\mcp_bridge.ms"\n'
        'mcpLoaderBridgeFile = @"C:\\real\\mcp_bridge.ms"\n'
    )
    check("a commented path is ignored",
          doctor.parse_autoloader_target(commented) == r"C:\real\mcp_bridge.ms")

    print("4. whitespace and CRLF")
    crlf = text.replace("\n", "\r\n")
    check("CRLF file still parses",
          doctor.parse_autoloader_target(crlf) == bridge,
          "got {0!r}".format(doctor.parse_autoloader_target(crlf)))
    padded = '   mcpLoaderBridgeFile   =   @"C:\\pad\\mcp_bridge.ms"   '
    check("leading/trailing spaces still parse",
          doctor.parse_autoloader_target(padded) == r"C:\pad\mcp_bridge.ms")

    print("5. no assignment")
    check("empty text -> empty string", doctor.parse_autoloader_target("") == "")
    check("loader without a path -> empty string",
          doctor.parse_autoloader_target("fn mcpLoaderLog = ()\n") == "")

    print("6. a bridge-named variable wins over an unrelated one")
    two = (
        'logFile = @"C:\\logs\\loader.log"\n'
        'mcpLoaderBridgeFile = @"C:\\scripts\\mcp_bridge.ms"\n'
    )
    check("picks the bridge variable",
          doctor.parse_autoloader_target(two) == r"C:\scripts\mcp_bridge.ms")

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("autoloader round trip: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
