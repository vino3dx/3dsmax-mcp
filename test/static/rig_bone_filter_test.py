"""Contract check for rig_list_bones' bone filter.

No 3ds Max required -- this is a source-level audit of a bug that could not be
caught any other way offline, plus the invariant that matters at runtime.

The bug, measured on 3ds Max 2022: `Biped.createNew 3 100 [0,0,0]` adds 31
nodes whose class is `Biped_Object`; not one of them is a `BoneGeometry`. The
handler filtered on

    if (classof o) == BoneGeometry

so a fully rigged Biped returned `count: 0` with no error, and CAT rigs would
have done the same. Live result after the fix, same scene:

    before, bare scene          count 3   kinds {bone 3, biped 0, cat 0}
    before, + Biped             count 3   (31 biped nodes invisible)
    after,  + Biped             count 34  kinds {bone 3, biped 31, cat 0}

Checks:
  1. mcpBoneKind exists and names BoneGeometry, Biped_Object and CATBone;
  2. the handler no longer compares against the BoneGeometry class symbol
     (that compare is what silently dropped every Biped);
  3. rows carry `boneKind` and the response carries a `kinds` breakdown, so a
     caller can tell the families apart without a second call;
  4. the failure path returns "" rather than raising, so one odd node cannot
     take the whole listing down.

Usage:  python test/static/rig_bone_filter_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPO, "src", "ms", "mcp_rigging.ms")

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def function_body(text: str, name: str) -> str:
    """Text of `fn <name> ...)` up to the closing paren at column 0."""
    start = text.find("fn {0}".format(name))
    if start < 0:
        return ""
    end = text.find("\n)", start)
    return text[start:end + 2] if end > 0 else text[start:]


def main() -> int:
    text = open(SOURCE, encoding="utf-8").read()
    kind_body = function_body(text, "mcpBoneKind")
    handler = function_body(text, "mcpH_rig_list_bones")

    print("1. mcpBoneKind")
    check("mcpBoneKind is defined", bool(kind_body))
    for family, needle in (
        ("BoneGeometry", '"BoneGeometry"'),
        ("Biped_Object", '"Biped_Object"'),
        ("CATBone", '"CATBone"'),
    ):
        check("classifies {0}".format(family), needle in kind_body)
    check("class name compare is guarded",
          "catch" in kind_body,
          "classof on a node without the plugin raises")
    check("returns empty string for unknown nodes", 'return ""' in kind_body)

    print("2. no class-symbol compare in the handler")
    stray = re.findall(r"classof\s+\w+\s*\)\s*==\s*BoneGeometry", handler)
    check("handler does not compare to the BoneGeometry symbol", not stray,
          "found {0}".format(stray))
    check("handler uses mcpBoneKind", "mcpBoneKind" in handler)

    print("3. response shape")
    check("rows carry boneKind", '"boneKind"' in handler)
    check("response carries a kinds breakdown", '"kinds"' in handler)
    for family in ('"bone"', '"biped"', '"cat"'):
        check("kinds counts {0}".format(family.strip('"')), family in handler)
    check("pagination unchanged", "mcpPaginateInto" in handler)
    check("root filter unchanged", 'mcpStr params "root"' in handler)

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("bone filter: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
