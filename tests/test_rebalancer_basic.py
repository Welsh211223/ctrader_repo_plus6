from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance


def test_rebalance_static_two_assets():
    holdings = [Holding(symbol="BTC", amount=0.005), Holding(symbol="ETH", amount=0.50)]
    prices = {"BTC": 100000.0, "ETH": 4000.0}
    targets = Allocation(weights={"BTC": 0.5, "ETH": 0.5})
    plan = plan_rebalance(
        holdings,
        prices,
        targets,
        drift_threshold=0.0,
        min_trade_value=10.0,
        fee_rate=0.0,
    )
    sides = {o.symbol: o.side for o in plan.orders}
    assert sides["BTC"] == "buy"
    assert sides["ETH"] == "sell"
    amt = {o.symbol: o.amount for o in plan.orders}
    assert abs(amt["BTC"] - 0.0075) < 1e-6
    assert abs(amt["ETH"] - 0.1875) < 1e-6
