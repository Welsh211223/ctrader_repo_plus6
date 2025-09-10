from __future__ import annotations

import math
from typing import Dict

from ctrader.data_providers.marketdata import fetch_fx_usd_to_aud, fetch_history_daily


def _daily_returns(prices: list[float]) -> list[float]:
    rets = []
    for i in range(1, len(prices)):
        a, b = prices[i - 1], prices[i]
        if a > 0 and b > 0:
            rets.append((b / a) - 1.0)
    return rets


def inverse_vol_weights(
    weights: Dict[str, float],
    exchange: str,
    quote: str,
    lookback_days: int,
    vol_floor: float,
    strength: float,
) -> Dict[str, float]:
    base = dict(weights)
    invw = {}
    fx = fetch_fx_usd_to_aud() if (quote or "").upper() == "AUD" else None
    for s in base.keys():
        hist = fetch_history_daily(s, vs="usd", days=max(lookback_days + 30, 120))
        px = [p * (fx if fx else 1.0) for _, p in hist][-lookback_days:]
        if len(px) < max(10, int(0.5 * lookback_days)):
            vol = None
        else:
            rets = _daily_returns(px)
            if len(rets) < 5:
                vol = None
            else:
                mu = sum(rets) / len(rets)
                var = sum((r - mu) ** 2 for r in rets) / (len(rets) - 1)
                vol = math.sqrt(var)
        vol_eff = max(vol or vol_floor, vol_floor)
        invw[s] = 1.0 / vol_eff
    ssum = sum(invw.values())
    invw = (
        {k: v / ssum for k, v in invw.items()}
        if ssum
        else {k: 1.0 / len(base) for k in base}
    )
    out = {
        k: (1.0 - float(strength)) * float(w)
        + float(strength) * float(invw.get(k, 0.0))
        for k, w in base.items()
    }
    s = sum(out.values())
    return (
        {k: v / s for k, v in out.items()} if s else {k: 1.0 / len(base) for k in base}
    )
