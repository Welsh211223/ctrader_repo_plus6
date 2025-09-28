from __future__ import annotations

from typing import Dict, Iterable, List, Optional

from ctrader.constraints import (
    apply_qty_constraints,
    get_symbol_constraints,
    meets_min_notional,
)
from ctrader.models import Allocation, Holding, Order, TradePlan


def plan_rebalance(
    holdings: Iterable[Holding],
    prices: Dict[str, float],
    targets: Allocation,
    drift_threshold: float = 0.01,
    min_trade_value: float = 30.0,
    fee_rate: float = 0.001,
    constraints: Optional[Dict] = None,
) -> TradePlan:
    by_symbol = {h.symbol.upper(): h for h in holdings}
    prices = {k.upper(): float(v) for k, v in prices.items()}
    targets_w = targets.weights

    pv = 0.0
    for sym, h in by_symbol.items():
        p = prices.get(sym)
        if p:
            pv += h.amount * p
    if pv <= 0:
        return TradePlan(orders=[], portfolio_value=0.0, note="No portfolio value")

    orders: List[Order] = []

    for sym, w in targets_w.items():
        price = prices.get(sym)
        if not price or price <= 0:
            continue
        cur_amt = by_symbol.get(sym).amount if sym in by_symbol else 0.0
        cur_val = cur_amt * price
        desired_val = w * pv
        diff_val = desired_val - cur_val
        if abs(diff_val) < drift_threshold * pv:
            continue

        side = "buy" if diff_val > 0 else "sell"
        value = abs(diff_val)

        c = get_symbol_constraints(sym, constraints)
        min_notional = float(c.get("min_notional", min_trade_value))
        min_qty = c.get("min_qty")
        qty_step = c.get("qty_step")

        raw_amount = value / price
        amt = apply_qty_constraints(raw_amount, side, min_qty, qty_step)
        adj_value = abs(amt * price)
        if amt <= 0 or not meets_min_notional(adj_value, min_notional):
            continue

        est_fee = adj_value * fee_rate
        orders.append(
            Order(
                side=side, symbol=sym, amount=amt, est_value=adj_value, est_fee=est_fee
            )
        )

    return TradePlan(orders=orders, portfolio_value=pv, note="rebalance plan")
