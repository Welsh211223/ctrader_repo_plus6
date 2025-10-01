from __future__ import annotations

from typing import Iterable

from ctrader.models import Allocation, Holding


class Strategy:
    name: str = "base"

    def target_allocations(
        self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs
    ) -> Allocation:
        raise NotImplementedError
