from __future__ import annotations

import math

import pandas as pd


def _round_qty(qty: float, precision: int | None) -> float:
    if precision is None:
        return float(qty)
    factor = 10 ** int(precision)
    return math.floor(qty * factor + 1e-12) / factor


def create_rebalance_plan(
    current: dict[str, float],
    targets: dict[str, float],
    prices: dict[str, float],
    threshold_pct: float = 0.0,
    min_order_value: float | None = None,
    qty_precision: dict[str, int] | None = None,
) -> pd.DataFrame:
    rows = []
    for t in sorted(targets.keys() | current.keys()):
        cq = float(current.get(t, 0.0))
        tq = float(targets.get(t, 0.0))
        px = float(prices.get(t, 0.0))
        delta = tq - cq
        denom = max(abs(tq), 1e-9)
        pct = (abs(delta) / denom) * 100.0
        if threshold_pct > 0 and pct < threshold_pct:
            side = "HOLD"
            qty = 0.0
        else:
            if delta > 1e-9:
                side = "BUY"
                qty = delta
            elif delta < -1e-9:
                side = "SELL"
                qty = -delta
            else:
                side = "HOLD"
                qty = 0.0
        qprec = (qty_precision or {}).get(t)
        qty = _round_qty(qty, qprec)
        notion = qty * px
        if min_order_value is not None and notion < min_order_value:
            side = "HOLD"
            qty = 0.0
            notion = 0.0
        rows.append(
            {"ticker": t, "side": side, "qty": qty, "est_value": notion, "price": px}
        )
    return pd.DataFrame(rows)


def any_drift_exceeds_threshold(
    current: dict[str, float], targets: dict[str, float], threshold_pct: float
) -> bool:
    for t in targets.keys() | current.keys():
        cq = float(current.get(t, 0.0))
        tq = float(targets.get(t, 0.0))
        denom = max(abs(tq), 1e-9)
        pct = (abs(tq - cq) / denom) * 100.0
        if pct >= threshold_pct:
            return True
    return False
