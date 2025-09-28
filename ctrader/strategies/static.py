from __future__ import annotations

from typing import Dict, Iterable

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


class StaticStrategy(Strategy):
    name = "static"

    def target_allocations(
        self,
        holdings: Iterable[Holding],
        universe: Iterable[str],
        weights: Dict[str, float],
        **kwargs,
    ) -> Allocation:
        return Allocation(weights=dict(weights))
