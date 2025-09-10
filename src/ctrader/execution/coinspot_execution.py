from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional

from ctrader.utils.live_guard import assert_live_ok

try:
    # Optional: only for type hints / wiring. Not required at runtime here.
    from ctrader.data_providers.coinspot_v2 import CoinSpotV2  # type: ignore
except Exception:  # pragma: no cover

    class CoinSpotV2:  # minimal stub fallback
        pass


def place_plan_coinspot(
    plan: Any,
    client: Optional["CoinSpotV2"] = None,
    *,
    prices: Optional[Dict[str, float]] = None,
    max_trades: int = 0,
    mode: str = "dry",  # "dry" or "live"
    use_quote: bool = False,
    threshold_pct: float = 0.0,
    direction: str = "buy",
    order_timeout_sec: int = 60,
    poll_interval_sec: int = 2,
    notify: Optional[Callable[[Dict[str, Any]], None]] = None,
) -> List[Dict[str, Any]]:
    """
    Minimal, safe placeholder executor.

    - In "dry" mode: returns a single 'noop' event.
    - In "live" mode: enforces assert_live_ok() and returns a 'guarded' event
      (still does NOT place orders). This keeps the repo healthy while the
      real CoinSpot execution is restored later.
    """
    if mode.lower() == "live":
        assert_live_ok()  # safety gate

    evt: Dict[str, Any] = {
        "mode": mode,
        "status": "noop" if mode.lower() != "live" else "guarded",
        "reason": "placeholder implementation of coinspot execution",
        "details": {
            "max_trades": max_trades,
            "use_quote": use_quote,
            "threshold_pct": threshold_pct,
            "direction": direction,
            "order_timeout_sec": order_timeout_sec,
            "poll_interval_sec": poll_interval_sec,
        },
    }
    if notify:
        try:
            notify(evt)
        except Exception:
            # notifications should never crash an execution flow
            pass
    return [evt]
