from __future__ import annotations

import csv
import os
import time
from typing import Dict

from ctrader.models import TradePlan


def execute_plan(
    plan: TradePlan, prices: Dict[str, float], out_path: str = "paper_trades.csv"
) -> str:
    if not plan.orders:
        return out_path
    exists = os.path.exists(out_path)
    with open(out_path, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if not exists:
            w.writerow(["ts", "side", "symbol", "amount", "price", "value", "est_fee"])
        ts = int(time.time())
        for o in plan.orders:
            price = float(prices.get(o.symbol, 0.0))
            value = float(o.amount * price)
            w.writerow([ts, o.side, o.symbol, o.amount, price, value, o.est_fee])
    return out_path
