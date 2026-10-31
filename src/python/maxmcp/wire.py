r"""Wire codec for the bridge link.

The MAXScript side is byte oriented: it decodes every network read with a
single byte ASCII codec and rebuilds strings through the Windows ANSI code page.
To stay safe in both directions every string is transported as the ANSI code
page *bytes* expressed as U+00XX code points, which ``json.dumps`` then emits as
``\\u00XX`` escapes - pure ASCII on the wire, Chinese preserved exactly.

    python str  --to_wire-->  latin-1 view of the ANSI bytes  -->  json \u00XX
    json \u00XX  --from_wire-->  python str

Both directions are identity functions for pure ASCII, which is the common case.
"""

from __future__ import annotations

import platform
from typing import Any

try:  # pragma: no cover - platform dependent
    ANSI = "mbcs" if platform.system() == "Windows" else "utf-8"
except Exception:  # pragma: no cover
    ANSI = "utf-8"


def to_wire(value: Any) -> Any:
    """Python str -> the byte escaped form MAXScript can rebuild."""
    if isinstance(value, str):
        try:
            return value.encode(ANSI, "replace").decode("latin-1")
        except (LookupError, UnicodeError):
            return value
    if isinstance(value, dict):
        return {k: to_wire(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_wire(v) for v in value]
    return value


def from_wire(value: Any) -> Any:
    """Inverse of :func:`to_wire`, applied to everything coming back from Max.

    A wire string can only contain code points U+0000..U+00FF (it is a latin-1
    view of ANSI bytes).  Anything outside that range has already been decoded -
    for example a localized MAXScript error message that the bridge decoded on
    purpose - and re-decoding it would turn "找不到对象" into mojibake.  Treating
    such strings as identity makes the conversion safe to apply to envelopes that
    mix decoded diagnostics with raw bridge payloads (the Scene Runtime does
    exactly that).
    """
    if isinstance(value, str):
        if any(ord(ch) > 0xFF for ch in value):
            return value
        try:
            return value.encode("latin-1", "backslashreplace").decode(ANSI, "replace")
        except (LookupError, UnicodeError):
            return value
    if isinstance(value, dict):
        return {k: from_wire(v) for k, v in value.items()}
    if isinstance(value, list):
        return [from_wire(v) for v in value]
    return value


def describe() -> str:
    return ANSI
