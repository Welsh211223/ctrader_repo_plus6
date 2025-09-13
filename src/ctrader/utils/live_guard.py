from __future__ import annotations

import os
import time
from pathlib import Path

_TRUTHY = {"1", "true", "yes", "on"}


def _is_truthy(v: str | None) -> bool:
    return (v or "").strip().lower() in _TRUTHY


def assert_live_ok(now: float | None = None) -> None:
    """Block accidental live trading unless explicitly confirmed."""
    if not _is_truthy(os.getenv("COINSPOT_LIVE_DANGEROUS", "false")):
        return
    if _is_truthy(os.getenv("CONFIRM_LIVE")):
        return
    tok = Path(".allow_live")
    t = time.time() if now is None else now
    if tok.exists():
        try:
            if t - tok.stat().st_mtime <= 3600:
                return
        except OSError:
            pass
    raise RuntimeError(
        "Refusing LIVE orders: COINSPOT_LIVE_DANGEROUS=true without explicit confirmation. "
        "Set CONFIRM_LIVE=1 or create an empty .allow_live (valid 1 hour)."
    )
