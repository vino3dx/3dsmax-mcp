"""Entry point: ``python -m maxmcp``.

Also usable straight from a checkout without installing:
``python src/maxmcp/__main__.py`` or ``python -m maxmcp`` with ``src`` on PYTHONPATH.
"""

from __future__ import annotations

import os
import sys

# Allow running from a source checkout where `src` is not on sys.path yet.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SRC = os.path.dirname(_HERE)
if os.path.isdir(os.path.join(_SRC, "maxmcp")) and _SRC not in sys.path:
    sys.path.insert(0, _SRC)

from maxmcp.server import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
