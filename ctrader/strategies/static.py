from __future__ import annotations

from typing import Dict, Iterable

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


class StaticStrategy(Strategy):
    """Use fixed weights provided at construction time."""

    name = "static"

    def __init__(self, weights: Dict[str, float]):
        self._weights = {k.upper(): float(v) for k, v in (weights or {}).items()}

    def target_allocations(
        self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs
    ) -> Allocation:
        syms = [s.upper() for s in universe]
        # Restrict/extend to the universe; missing symbols get 0
        w = {s: float(self._weights.get(s, 0.0)) for s in syms}
        total = sum(w.values())
        if total <= 0:
            # Fallback to equal if bad weights
            eq = 1.0 / max(1, len(syms))
            return Allocation(weights={s: eq for s in syms})
        norm = {s: (w[s] / total) for s in syms}
        return Allocation(weights=norm)
