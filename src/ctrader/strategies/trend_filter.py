from __future__ import annotations

import math
from typing import Dict

from ctrader.data_providers.marketdata import (fetch_fx_usd_to_aud,
                                               fetch_history_daily)


def _sma(prices: list[float], window: int) -> float:
    if not prices or window <= 0 or len(prices) < window:
        return float("nan")
    return sum(prices[-window:]) / float(window)


def apply_trend_filter(
    weights: Dict[str, float],
    exchange: str,
    quote: str,
    sma_days: int,
    min_weight: float,
) -> Dict[str, float]:
    if sma_days <= 1:
        return dict(weights)
    out = dict(weights)
    fx = fetch_fx_usd_to_aud() if (quote or "").upper() == "AUD" else None
    for sym, w in list(weights.items()):
        hist = fetch_history_daily(sym, vs="usd", days=max(365, sma_days + 30))
        series = [p * (fx if fx else 1.0) for _, p in hist]
        sma = _sma(series, sma_days)
        if not series or math.isnan(sma):
            continue
        px = series[-1]
        out[sym] = float(w) * (float(min_weight) if px < sma else float(w))
    s = sum(max(0.0, v) for v in out.values())
    return {k: v / s for k, v in out.items()} if s > 0 else out
