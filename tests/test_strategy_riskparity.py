from ctrader.models import Holding
from ctrader.strategies.riskparity import RiskParityStrategy


def test_risk_parity_prefers_lower_vol():
    hist = {
        "BTC": [100, 101, 102, 103, 104, 103, 102],
        "ETH": [100, 120, 80, 140, 90, 160, 100],
    }
    syms = ["BTC", "ETH"]
    alloc = RiskParityStrategy().target_allocations(
        [Holding(symbol="BTC", amount=0), Holding(symbol="ETH", amount=0)],
        syms,
        history=hist,
    )
    assert abs(sum(alloc.weights.values()) - 1.0) < 1e-9
    assert alloc.weights["BTC"] > alloc.weights["ETH"]
