from __future__ import annotations

from pathlib import Path

import pandas as pd


def _normalize(weights: dict[str, float]) -> dict[str, float]:
    s = sum(max(0.0, float(v)) for v in weights.values())
    if s <= 0:
        n = len(weights) or 1
        return {k: 1.0 / n for k in weights}
    return {k: max(0.0, float(v)) / s for k, v in weights.items()}


def compute_targets(
    equity: float, weights: dict[str, float], prices: dict[str, float]
) -> dict[str, float]:
    w = _normalize(weights)
    targets = {}
    for t, wgt in w.items():
        px = float(prices.get(t, 0.0))
        targets[t] = 0.0 if px <= 0 else (equity * wgt) / px
    return targets


def load_holdings(pool: str, base: Path) -> dict[str, float]:
    base.mkdir(parents=True, exist_ok=True)
    fp = base / f"{pool}_holdings.csv"
    if not fp.exists():
        return {}
    df = pd.read_csv(fp)
    return {str(r["ticker"]): float(r["qty"]) for _, r in df.iterrows()}


def save_holdings(pool: str, holdings: dict[str, float], base: Path) -> None:
    base.mkdir(parents=True, exist_ok=True)
    fp = base / f"{pool}_holdings.csv"
    rows = [{"ticker": t, "qty": float(q)} for t, q in holdings.items()]
    pd.DataFrame(rows).to_csv(fp, index=False)


def compute_drift(
    current: dict[str, float], prices: dict[str, float], targets: dict[str, float]
) -> pd.DataFrame:
    rows = []
    for t in sorted(targets.keys() | current.keys()):
        cq = float(current.get(t, 0.0))
        tq = float(targets.get(t, 0.0))
        px = float(prices.get(t, 0.0))
        delta = tq - cq
        side = "HOLD"
        if delta > 1e-9:
            side = "BUY"
        elif delta < -1e-9:
            side = "SELL"
        rows.append(
            {
                "ticker": t,
                "price": px,
                "current_qty": cq,
                "target_qty": tq,
                "delta_qty": delta,
                "est_value": abs(delta) * px,
                "side": side,
            }
        )
    return pd.DataFrame(rows)
