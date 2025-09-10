from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from ctrader.config_loader import load_pools_config
from ctrader.data_providers.marketdata import fetch_fx_usd_to_aud, fetch_history_daily
from ctrader.risk.rebalancer import create_rebalance_plan
from ctrader.risk.risk_manager import RiskRules, enforce_caps
from ctrader.strategies.inverse_vol import inverse_vol_weights
from ctrader.strategies.momentum import boost_top_k, momentum_12_1
from ctrader.strategies.trend_filter import apply_trend_filter


@dataclass
class BtConfig:
    fee_bps: float = 10.0
    slip_bps: float = 5.0
    threshold_pct: float = 0.0
    start_cash: float = 10000.0
    min_order_value: float = 5.0


def _to_aud(series: list[float], fx: float | None, quote: str) -> list[float]:
    if (quote or "").upper() == "AUD" and fx:
        return [p * fx for p in series]
    return series


def run_backtest(cfg_path: str | Path, pool: str, bt_days: int = 365) -> pd.DataFrame:
    cfg = load_pools_config(cfg_path)
    g = cfg.get("global", {})
    pcfg = cfg["pools"][pool]
    quote = g.get("quote_currency", "AUD").upper()
    fee_bps = float(g.get("fee_bps", 10))
    slip_bps = float(g.get("slippage_bps", 5))
    thresh = float(cfg.get("rebalance", {}).get("threshold_pct", 0.0))
    assets = list(pcfg["assets"].keys())
    fx = fetch_fx_usd_to_aud() if quote == "AUD" else None
    hist_map = {
        a: _to_aud(
            [
                p
                for _, p in fetch_history_daily(
                    a, vs="usd", days=max(bt_days + 400, 800)
                )
            ],
            fx,
            quote,
        )
        for a in assets
    }
    cash = float(pcfg.get("initial_equity", 10000))
    holdings = {a: 0.0 for a in assets}
    rows = []
    for i in range(-bt_days, 0):
        prices = {
            a: (hist_map[a][i] if len(hist_map[a]) >= -i else 0.0) for a in assets
        }
        w = dict(pcfg["assets"])
        w = apply_trend_filter(
            w,
            "binance",
            quote,
            int(g.get("trend_filter_sma_days", 200)),
            float(g.get("trend_min_weight", 0.25)),
        )
        if cfg.get("sizing", {}).get("risk_parity", True):
            szz = cfg["sizing"]
            w = inverse_vol_weights(
                w,
                "binance",
                quote,
                int(szz.get("vol_lookback_days", 30)),
                float(szz.get("vol_floor", 0.0005)),
                float(szz.get("risk_parity_strength", 1.0)),
            )
        if cfg.get("momentum", {}).get("enabled", True):
            mom = cfg["momentum"]
            scores = momentum_12_1(
                list(w.keys()),
                "binance",
                quote,
                int(mom.get("lookback_months", 12)),
                int(mom.get("skip_recent_months", 1)),
            )
            w = boost_top_k(
                w,
                scores,
                int(mom.get("top_k", 6)),
                float(mom.get("momentum_boost_pct", 0.04)),
            )
        rules = RiskRules(
            float(pcfg.get("max_per_asset_pct", 100)),
            float(pcfg.get("max_meme_bucket_pct", 100)),
            float(pcfg.get("max_ai_bucket_pct", 100)),
            pcfg.get("per_asset_caps", {}),
        )
        w = enforce_caps(w, pcfg.get("categories", {}), rules)
        equity = cash + sum(holdings[a] * prices.get(a, 0.0) for a in assets)
        targets = {
            a: ((equity * float(w.get(a, 0.0))) / prices[a]) if prices[a] > 0 else 0.0
            for a in assets
        }
        plan = create_rebalance_plan(
            holdings,
            targets,
            prices,
            threshold_pct=thresh,
            min_order_value=5.0,
            qty_precision={a: 6 for a in assets},
        )
        fees = fee_bps / 10000.0
        slip = slip_bps / 10000.0
        for _, r in plan.iterrows():
            if r["side"] == "HOLD" or float(r["qty"]) <= 0:
                continue
            a = r["ticker"]
            q = float(r["qty"])
            px = float(prices.get(a, 0.0))
            trade_px = px * (1.0 + slip if r["side"] == "BUY" else 1.0 - slip)
            if r["side"] == "BUY":
                cost = q * trade_px * (1.0 + fees)
                if cash >= cost - 1e-9:
                    cash -= cost
                    holdings[a] = holdings.get(a, 0.0) + q
            else:
                have = holdings.get(a, 0.0)
                sell_q = min(q, have)
                proceeds = sell_q * trade_px * (1.0 - fees)
                cash += proceeds
                holdings[a] = max(0.0, have - sell_q)
        equity = cash + sum(holdings[a] * prices.get(a, 0.0) for a in assets)
        rows.append(
            {
                "day_index": i,
                "equity": equity,
                "cash": cash,
                **{f"qty_{a}": holdings[a] for a in assets},
            }
        )
    return pd.DataFrame(rows)
