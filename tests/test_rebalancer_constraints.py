from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance


def test_qty_step_rounding_and_min_notional():
    holdings = [Holding(symbol="BTC", amount=0.1)]  # PV = 1000
    prices = {"BTC": 10000.0, "ETH": 2000.0}
    targets = Allocation(weights={"BTC": 0.0, "ETH": 1.0})
    plan = plan_rebalance(
        holdings,
        prices,
        targets,
        drift_threshold=0.0,
        min_trade_value=10.0,
        fee_rate=0.0,
        constraints={
            "default": {"min_notional": 10.0, "min_qty": 0.01, "qty_step": 0.01}
        },
    )
    # Assert we have a BUY ETH order regardless of list order
    eth_orders = [o for o in plan.orders if o.symbol == "ETH" and o.side == "buy"]
    assert eth_orders, f"Expected a buy ETH order, got: {plan.orders}"
    eth = eth_orders[0]
    assert abs((eth.amount / 0.01) - round(eth.amount / 0.01)) < 1e-9
