from __future__ import annotations

from typing import Iterable

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


class EqualWeightStrategy(Strategy):
    name = "equal"

    def target_allocations(
        self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs
    ) -> Allocation:
        u = [s.upper() for s in universe]
        n = len(u)
        if n == 0:
            raise ValueError("Universe cannot be empty for EqualWeightStrategy.")
        w = 1.0 / n
        return Allocation(weights={s: w for s in u})
