"""Server-side scene-context snapshot cache.

`context_get` answers with a `since` cursor: a caller that passes the revision
it last saw gets back only the domains that moved. That keeps a poll cheap, but
it also means a caller who wants a *complete* picture - an MCP resource read, a
panel, an agent that just reconnected - would have to stitch those deltas
together itself and remember every domain it had ever received.

This module does that stitching once, on the server, so `max://scene/context`
can always answer with a full snapshot while the bridge still only rebuilds the
domains that actually changed.

Data-honesty rules, because a cache is the easiest place in a project like this
to start inventing data:

* Merging never fabricates a section. A domain the bridge has not sent yet stays
  absent, and `missing` says which ones they are.
* The revision reported is the bridge's, never a local counter, so it can always
  be fed straight back into `context_get(since=...)`.
* A revision that moves backwards means Max restarted, the bridge was reloaded,
  or a different scene was opened. The whole cache is dropped rather than
  serving a mixture of two sessions.
* Every section keeps the provenance the bridge attached to it (domain,
  revision, updatedAt, source, valid, supported, stale, buildMs). The cache
  adds `fetchedAt` and `ageMs` only -- it never rewrites the bridge's numbers.
"""

from __future__ import annotations

import copy
import threading
import time
from typing import Any, Dict, Iterable, List, Optional

__all__ = ["SceneContextCache"]


class SceneContextCache:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._revision: int = 0
        self._sections: Dict[str, Dict[str, Any]] = {}
        self._session_starts: int = 0
        self._merges: int = 0
        self._last_merge_at: Optional[float] = None

    # ------------------------------------------------------------------ state
    @property
    def revision(self) -> int:
        """The cursor to pass back as `since`; 0 means "read everything"."""
        with self._lock:
            return self._revision

    def reset(self) -> None:
        with self._lock:
            self._revision = 0
            self._sections = {}
            self._session_starts += 1

    def cursor(self) -> int:
        """The `since` value to ask the bridge with.

        0 when nothing has been cached yet: passing a non-zero cursor while the
        cache is empty would make the bridge skip every unchanged domain and the
        snapshot would never fill.
        """
        with self._lock:
            return self._revision if self._sections else 0

    # ------------------------------------------------------------------ merge
    def merge(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Fold one `context_get` reply into the snapshot.

        Returns a small report so a caller can tell what happened without
        inspecting the cache: which domains were kept, which were dropped, and
        whether the snapshot was thrown away because the session changed.
        """
        if not isinstance(payload, dict):
            return {"merged": False, "reason": "payload is not an object"}

        revision = payload.get("revision")
        if not isinstance(revision, int):
            return {"merged": False, "reason": "payload has no integer revision"}

        incoming = payload.get("sections")
        if not isinstance(incoming, dict):
            incoming = {}

        with self._lock:
            restarted = bool(self._sections) and revision < self._revision
            if restarted:
                # Two different sessions: keeping any old section would be a
                # fabricated mix of two scenes.
                self._sections = {}
                self._session_starts += 1

            dropped = []
            for name, section in incoming.items():
                if isinstance(section, dict):
                    # Deep copy: `data` is nested, and a shallow copy would
                    # leave the caller sharing the cache's inner dicts.
                    merged = copy.deepcopy(section)
                    merged["fetchedAt"] = _stamp()
                    self._sections[name] = merged
                else:
                    # The bridge says this domain may have changed but sent
                    # something unreadable, so the stored copy is no longer
                    # trustworthy: drop it rather than keep serving a value the
                    # bridge just told us is out of date.
                    dropped.append(name)
                    self._sections.pop(name, None)

            self._revision = revision
            self._merges += 1
            self._last_merge_at = time.time()

            kept = sorted(self._sections)
            return {
                "merged": True,
                "restarted": restarted,
                "revision": revision,
                "received": sorted(incoming),
                "dropped": dropped,
                "kept": kept,
            }

    # -------------------------------------------------------------- read side
    def missing(self, expected: Iterable[str]) -> List[str]:
        with self._lock:
            return [name for name in expected if name not in self._sections]

    def snapshot(self, expected: Optional[Iterable[str]] = None) -> Dict[str, Any]:
        """A context_get-shaped payload rebuilt from the cache.

        `complete` is False while any requested domain has never been read, so a
        caller cannot mistake a partial snapshot for a full one.
        """
        with self._lock:
            sections = {name: copy.deepcopy(value) for name, value in self._sections.items()}
            revision = self._revision
            merges = self._merges
            last = self._last_merge_at
            starts = self._session_starts

        names = list(expected) if expected is not None else sorted(sections)
        absent = [name for name in names if name not in sections]
        return {
            "revision": revision,
            "source": "server-cache",
            "complete": not absent,
            "missing": absent,
            "sectionCount": len(sections),
            "merges": merges,
            "sessionStarts": starts,
            "lastMergeAt": last,
            "detail": "brief",
            "sections": {name: sections[name] for name in names if name in sections},
        }

    def stats(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "revision": self._revision,
                "sectionCount": len(self._sections),
                "sections": sorted(self._sections),
                "merges": self._merges,
                "sessionStarts": self._session_starts,
                "lastMergeAt": self._last_merge_at,
            }


def _stamp() -> str:
    return time.strftime("%H:%M:%S")
