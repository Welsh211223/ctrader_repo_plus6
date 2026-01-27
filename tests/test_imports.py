# tests/test_imports.py
# Purpose: ensure key modules import without side-effects or missing deps.


def test_imports_smoke():
    modules = [
        "ctrader.data_providers.coinspot",
        "ctrader.data_providers.coinspot_v2",
        "ctrader.data_providers.marketdata",
        "ctrader.strategies.trend_filter",
        "ctrader.strategies.momentum",
        "ctrader.strategies.inverse_vol",
        "ctrader.backtest",
        "ctrader.cli.trade",
    ]
    for m in modules:
        __import__(m)
