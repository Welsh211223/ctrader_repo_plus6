"""
Runtime guard for live trading.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

_TRUTHY = {"1", "true", "yes", "on"}


def _is_truthy(val: str | None) -> bool:
    if val is None:
        return False
    return val.strip().lower() in _TRUTHY


def assert_live_ok(now: float | None = None) -> None:
    live = _is_truthy(os.getenv("COINSPOT_LIVE_DANGEROUS", "false"))
    if not live:
        return
    if _is_truthy(os.getenv("CONFIRM_LIVE")):
        return
    token = Path(".allow_live")
    _now = time.time() if now is None else now
    if token.exists():
        try:
            age = _now - token.stat().st_mtime
            if age <= 3600:
                return
        except OSError:
            pass
    raise RuntimeError(
        "Refusing to place LIVE orders: COINSPOT_LIVE_DANGEROUS=true but no explicit confirmation provided. "
        "Do ONE of:\n"
        "  - Set CONFIRM_LIVE=1 for this run, or\n"
        "  - Create an empty file named .allow_live (valid for 1 hour).\n"
        "This safeguard prevents accidental live trades."
    )
