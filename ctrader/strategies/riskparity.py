from __future__ import annotations

import math
from typing import Dict, Iterable, List

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


def _stdev(xs: List[float]) -> float:
    n = len(xs)
    if n < 2:
        return float("nan")
    mu = sum(xs) / n
    var = sum((x - mu) ** 2 for x in xs) / (n - 1)
    return math.sqrt(var)


class RiskParityStrategy(Strategy):
    """Inverse-volatility weights from config history."""

    name = "risk_parity"

    def target_allocations(
        self,
        holdings: Iterable[Holding],
        universe: Iterable[str],
        history: Dict[str, list],
        **kwargs,
    ) -> Allocation:
        syms = [s.upper() for s in universe]
        vols: Dict[str, float] = {}
        for s in syms:
            series = [float(x) for x in (history.get(s) or [])]
            if len(series) < 3:
                vols[s] = float("nan")
                continue
            rets = []
            for i in range(1, len(series)):
                p0, p1 = series[i - 1], series[i]
                if p0 <= 0 or p1 <= 0:
                    continue
                rets.append((p1 - p0) / p0)
            vols[s] = _stdev(rets) if len(rets) >= 2 else float("nan")

        inv = {s: (1.0 / v) for s, v in vols.items() if v == v and v > 0}
        if not inv:
            w = 1.0 / max(1, len(syms))
            return Allocation(weights={s: w for s in syms})

        total = sum(inv.values())
        weights = {s: inv[s] / total for s in inv}
        for s in syms:
            weights.setdefault(s, 0.0)
        return Allocation(weights=weights)
