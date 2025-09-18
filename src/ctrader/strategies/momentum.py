from __future__ import annotations

from typing import Dict, List

from ctrader.data_providers.marketdata import fetch_fx_usd_to_aud, fetch_history_daily


def _price_at_offset(series: list[float], offset_days: int) -> float | None:
    if not series or offset_days <= 0 or offset_days >= len(series):
        return None
    return series[-1 - offset_days]


def momentum_12_1(
    symbols: List[str],
    exchange: str,
    quote: str,
    lookback_months: int,
    skip_recent_months: int,
) -> Dict[str, float]:
    lb_days = int(lookback_months * 30)
    skip_days = int(skip_recent_months * 30)
    use_aud = (quote or "").upper() == "AUD"
    fx = fetch_fx_usd_to_aud() if use_aud else None
    scores: Dict[str, float] = {}
    for s in symbols:
        hist = fetch_history_daily(s, vs="usd", days=max(400, lb_days + skip_days + 30))
        px = [p * (fx if fx else 1.0) for _, p in hist]
        a = _price_at_offset(px, skip_days)
        b = _price_at_offset(px, lb_days + skip_days)
        scores[s] = 0.0 if a is None or b is None or b <= 0 else (a / b) - 1.0
    return scores


def boost_top_k(
    weights: Dict[str, float], scores: Dict[str, float], k: int, boost_pct: float
) -> Dict[str, float]:
    ordered = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    top = set([t for t, _ in ordered[: max(0, k)]])
    out = {
        t: float(w) * (1.0 + float(boost_pct)) if t in top else float(w)
        for t, w in weights.items()
    }
    s = sum(out.values())
    return {k: v / s for k, v in out.items()} if s else dict(weights)
