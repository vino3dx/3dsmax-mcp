"""Tests for the server-side scene-context snapshot cache.

The cache exists so `max://scene/context` can answer with a complete snapshot
while the bridge only rebuilds the domains that changed. The properties worth
pinning down are the ones that would let it lie: inventing sections it never
read, serving a mixture of two Max sessions, or reporting a local revision that
cannot be fed back into `context_get(since=...)`.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "python"))

from maxmcp.context import SceneContextCache


def section(domain, revision, value):
    return {
        "domain": domain,
        "revision": revision,
        "updatedAt": "12:00:00",
        "source": "maxscript",
        "valid": True,
        "supported": True,
        "stale": False,
        "buildMs": 1,
        "data": {"value": value},
    }


def payload(revision, sections, available=None):
    return {
        "revision": revision,
        "sections": sections,
        "availableSections": available or sorted(sections),
    }


def main() -> None:
    # -- an empty cache asks for everything ---------------------------------
    cache = SceneContextCache()
    assert cache.cursor() == 0, "an empty cache must not send a non-zero since"
    assert cache.revision == 0

    # -- unfed domains stay absent, never defaulted -------------------------
    report = cache.merge(payload(5, {"scene": section("scene", 1, "a")}))
    assert report["merged"] is True
    assert report["received"] == ["scene"]
    snap = cache.snapshot(["scene", "objects"])
    assert snap["complete"] is False, "a domain never read must not count as complete"
    assert snap["missing"] == ["objects"]
    assert "objects" not in snap["sections"]

    # -- merging keeps the bridge's revision, not a local counter -----------
    assert snap["revision"] == 5
    assert cache.cursor() == 5

    # -- a later delta fills the gap and preserves per-section provenance ---
    cache.merge(payload(9, {"objects": section("objects", 4, "b")}))
    snap = cache.snapshot(["scene", "objects"])
    assert snap["complete"] is True
    assert snap["revision"] == 9
    assert snap["sections"]["scene"]["data"]["value"] == "a"
    assert snap["sections"]["objects"]["revision"] == 4
    assert snap["sections"]["objects"]["source"] == "maxscript"
    assert snap["sections"]["objects"]["valid"] is True
    for name in ("scene", "objects"):
        assert "fetchedAt" in snap["sections"][name], "the cache must date what it stored"

    # -- a backwards revision means a new session: drop, do not mix --------
    report = cache.merge(payload(1, {"scene": section("scene", 1, "fresh")}))
    assert report["restarted"] is True
    assert report["kept"] == ["scene"], "the old session's objects section must be gone"
    snap = cache.snapshot(["scene", "objects"])
    assert snap["complete"] is False
    assert snap["sections"]["scene"]["data"]["value"] == "fresh"
    assert "objects" not in snap["sections"]
    assert snap["sessionStarts"] == 1

    # -- malformed replies are refused instead of half-applied -------------
    before = cache.snapshot()["revision"]
    assert cache.merge({"sections": {"scene": section("scene", 1, "x")}})["merged"] is False
    assert cache.merge(None)["merged"] is False
    assert cache.merge(payload("7", {}))["merged"] is False
    assert cache.snapshot()["revision"] == before

    # -- a non-object section is reported, not stored ----------------------
    report = cache.merge({"revision": 12, "sections": {"scene": "not an object"}})
    assert report["merged"] is True
    assert report["dropped"] == ["scene"]
    assert "scene" not in cache.snapshot()["sections"]

    # -- reset forgets the cursor so the next read is a full read ----------
    cache.reset()
    assert cache.revision == 0
    assert cache.cursor() == 0
    assert cache.snapshot()["sections"] == {}

    # -- snapshot() takes a copy: a caller cannot corrupt the cache --------
    cache.merge(payload(3, {"scene": section("scene", 1, "keep")}))
    snap = cache.snapshot(["scene"])
    snap["sections"]["scene"]["data"]["value"] = "mutated"
    assert cache.snapshot(["scene"])["sections"]["scene"]["data"]["value"] == "keep"

    print("context cache: all checks passed")


if __name__ == "__main__":
    main()
