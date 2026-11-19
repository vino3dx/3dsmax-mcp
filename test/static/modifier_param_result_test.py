"""Source-level contract for honest modifier parameter-setting results.

No 3ds Max required.  This locks down the fix for the "fake success" defect
where mod_set_param / mod_set_params reported msg.ok even when no parameter
was actually applied.  The behaviour is rooted in MAXScript, so the checks
read the source directly; the end-to-end truth is covered by the live test.

The defect (baseline 0de553c):
  * mcpApplyModParams used `try ( setProperty mod k v ) catch()` -- an empty
    catch swallowed unknown-property and type errors and still returned ok.
  * mcpH_mod_set_params called it then appended applied unconditionally and
    returned a hard-coded msg.ok, so an all-invalid params object looked like
    a full success.
  * mcpH_mod_set_param hid failures in `failures` while the response still
    carried msg.ok, and had no notion of an unsupported parameter.

After the fix:
  * mcpApplyModParams classifies each name via getPropNames into
    applied / rejected (unsupported) / failures (assignment threw).
  * both handlers account applied / appliedParams / rejected / failures,
    throw when nothing applied (transport -> MCP isError), and mark partial
    success explicitly with partial:true and success:false.

Usage:  python test/static/modifier_param_result_test.py
Exit code 0 when everything matches, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPO, "src", "ms", "mcp_modifiers.ms")
CORE = os.path.join(REPO, "src", "ms", "mcp_core.ms")

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   {0}".format(name))
    else:
        print("  FAIL {0}{1}".format(name, "  " + detail if detail else ""))
        FAILURES.append(name)


def function_body(text: str, name: str) -> str:
    """Text of `fn <name> ...` up to the closing paren at column 0."""
    start = text.find("fn {0}".format(name))
    if start < 0:
        return ""
    end = text.find("\n)", start)
    return text[start:end + 2] if end > 0 else text[start:]


def main() -> int:
    text = open(SOURCE, encoding="utf-8").read()
    core = open(CORE, encoding="utf-8").read()
    apply_body = function_body(text, "mcpApplyModParams")
    single_body = function_body(text, "mcpH_mod_set_param")
    batch_body = function_body(text, "mcpH_mod_set_params")

    print("1. mcpApplyModParams classifies every parameter")
    check("mcpApplyModParams is defined", bool(apply_body))
    check("uses getPropNames as supported-name authority", "getPropNames" in apply_body)
    check("returns three buckets", "#(applied, rejected, failures)" in apply_body)
    check("no empty catch() left in applier",
          re.search(r"catch\s*\(\s*\)", apply_body) is None,
          "an empty catch still swallows errors")
    check("assignment exception captured as reason", "getCurrentException" in apply_body)
    check("unsupported name gets an explicit reason", "unsupported parameter" in apply_body)
    check("applied only appended after clean setProperty", "append applied ks" in apply_body)
    check("rejected and failures are populated",
          "append rejected" in apply_body and "append failures" in apply_body)

    print("2. mcpH_mod_set_param (single) honest result")
    check("mcpH_mod_set_param is defined", bool(single_body))
    check("uses the classifying applier", "mcpApplyModParams" in single_body)
    for field in ("applied", "appliedParams", "rejected", "failures"):
        check("reports {0}".format(field), '"{0}"'.format(field) in single_body)
    check("all-failed throws (not a fake ok)",
          "mcpFail" in single_body and "err.mod_params_failed" in single_body)
    check("explicit partial/success markers",
          '"partial"' in single_body and '"success"' in single_body)
    check("message is not unconditionally msg.ok",
          re.search(r'mcpPair p "message" \(mcpMsg "msg.ok"\)', single_body) is None)

    print("3. mcpH_mod_set_params (batch) honest result")
    check("mcpH_mod_set_params is defined", bool(batch_body))
    check("uses the classifying applier", "mcpApplyModParams" in batch_body)
    for field in ("applied", "appliedParams", "rejected", "failures"):
        check("reports {0}".format(field), '"{0}"'.format(field) in batch_body)
    check("all-failed throws (not a fake ok)",
          "mcpFail" in batch_body and "err.mod_params_failed" in batch_body)
    check("explicit partial/success markers",
          '"partial"' in batch_body and '"success"' in batch_body)
    check("partial message carries counts",
          "msg.mod_params_partial" in batch_body)
    check("appliedParams gated on real applications",
          "res[1].count > 0" in batch_body and "for x in res[1] do append appliedParams" in batch_body)
    check("message is not unconditionally msg.ok",
          re.search(r'mcpPair p "message" \(mcpMsg "msg.ok"\)', batch_body) is None)

    print("4. supporting messages exist")
    check("err.mod_params_failed defined", '"err.mod_params_failed"' in core)
    check("msg.mod_params_partial defined", '"msg.mod_params_partial"' in core)

    print("5. compatibility: tool names unchanged")
    reg = function_body(text, "mcpRegisterModifiers")
    check("mod_set_param still registered", '"mod_set_param"' in reg)
    check("mod_set_params still registered", '"mod_set_params"' in reg)

    print()
    if FAILURES:
        print("{0} check(s) failed: {1}".format(len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("modifier parameter result contract: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
