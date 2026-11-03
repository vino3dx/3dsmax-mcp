"""Static tests for the result semantics a handler reports.

Stage 9 gave every Animation / Rigging handler the same three-way answer:

    objects    the nodes the operation really changed
    skipped    the nodes where there was nothing to do (a legitimate no-op)
    failures   the nodes where it did not work

and the runtime turns that into a verdict.  What matters here is that the six
concepts stay independent, because collapsing any two of them produces the class
of bug this stage exists to remove:

    success      the operation met its contract
    changed      the scene actually differs
    applied      the nodes in `objects`
    skipped      fine, but nothing happened to them
    failed       named in `failures`
    verification whether something was read back afterwards

A skipped node is not a failure and not a success claim; `changed` is not
`success`; and a call where everything was skipped succeeds without changing
anything.  None of this needs 3ds Max: it is the interpretation of a payload.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.runtime import build_batch_result, declared_outcome, normalize_payload  # noqa: E402


def check_applied_only_is_success():
    payload = normalize_payload(
        {"objects": ["Character_A"], "failures": [], "message": "OK"}, "anim_clear_animation")
    assert payload["success"] is True
    assert payload["failures"] == []
    assert payload["data"]["objects"] == ["Character_A"]


def check_any_failure_is_not_success():
    payload = normalize_payload(
        {"objects": ["Character_A"], "failures": ["Character_B: no position controller"]},
        "anim_clear_animation")
    assert payload["success"] is False
    assert payload["failures"] == ["Character_B: no position controller"]


def check_all_skipped_is_a_successful_noop():
    """Nothing to clear is not a failure - but it is also not "changed"."""
    payload = normalize_payload(
        {"objects": [], "skipped": ["Character_A: no keys to clear"], "failures": []},
        "anim_clear_animation")
    assert payload["success"] is True, "no-op is a success, not a failure"
    assert payload["failures"] == []
    assert payload["data"]["objects"] == [], "nothing was applied"
    assert payload["data"]["skipped"] == ["Character_A: no keys to clear"]


def check_skipped_is_not_an_outcome_claim():
    """`skipped` alone cannot decide anything: it is a reason, not a verdict."""
    assert declared_outcome({"skipped": ["A: no keys"]}) is None
    assert declared_outcome({"objects": [], "skipped": ["A: no keys"]}) == (False, "objects")


def check_changed_is_independent_of_success():
    """A successful no-op reports changed=false; that must not read as failure."""
    payload = normalize_payload({"objects": [], "failures": []}, "anim_clear_animation")
    assert payload["success"] is True
    assert payload["changed"] is False

    # And an operation that reports a change without a verdict is still unproven:
    # `changed` never substitutes for `success`.
    unproven = normalize_payload({"changed": True, "message": "OK"}, "anim_bake")
    assert unproven["success"] is False
    assert unproven["failures"][0]["kind"] == "missing_success"


def check_verification_unavailable_is_not_passed():
    payload = normalize_payload({"objects": ["A"], "failures": []}, "rig_skin_set_weight")
    assert payload["verification"]["performed"] is False
    assert payload["verification"]["passed"] is None, "unverified is not verified-failed"


def check_saturation_shapes_reach_the_runtime():
    """The exact shapes the Stage 9 handlers emit, one per verdict."""
    # all applied
    assert declared_outcome({"objects": ["A", "B"], "failures": []}) == (True, "failures")
    # one failed out of two
    assert declared_outcome({"objects": ["A"], "failures": ["B: no Skin"]}) == (False, "failures")
    # everything skipped: `failures: []` says "I checked, nothing failed", which is
    # a successful no-op - different from a payload that says nothing at all.
    assert declared_outcome({"objects": [], "failures": []}) == (True, "failures")
    # objects alone, empty: the handler did nothing and claimed nothing
    assert declared_outcome({"objects": []}) == (False, "objects")


def check_batch_summary_counts():
    rows = [
        {"name": "A", "success": True, "verified": True},
        {"name": "B", "success": True},
        {"name": "C", "success": False},
    ]
    result = build_batch_result("anim_clear_animation", rows)
    assert result["summary"] == {"total": 3, "succeeded": 2, "failed": 1}
    assert result["success"] is False, "one failed row means the batch is not a success"
    assert [row["name"] for row in result["objects"] if row["success"]] == ["A", "B"]


def check_partial_success_is_not_reported_as_success():
    rows = [{"name": "A", "success": True}, {"name": "B", "success": False}]
    result = build_batch_result("rig_skin_set_weight", rows)
    assert result["success"] is False
    assert result["failures"][0]["kind"] == "partial_success"


def check_verification_counts_only_successful_rows():
    rows = [{"name": "A", "success": True, "verified": True},
            {"name": "B", "success": False, "verified": True}]
    result = build_batch_result("rig_skin_auto_weight", rows)
    # A failed row cannot be "verified": the two claims contradict each other.
    assert result["objects"][1]["verified"] is False
    assert result["verification"]["passed"] is None


def main():
    check_applied_only_is_success()
    check_any_failure_is_not_success()
    check_all_skipped_is_a_successful_noop()
    check_skipped_is_not_an_outcome_claim()
    check_changed_is_independent_of_success()
    check_verification_unavailable_is_not_passed()
    check_saturation_shapes_reach_the_runtime()
    check_batch_summary_counts()
    check_partial_success_is_not_reported_as_success()
    check_verification_counts_only_successful_rows()
    print("result semantics: all checks passed")


if __name__ == "__main__":
    main()
