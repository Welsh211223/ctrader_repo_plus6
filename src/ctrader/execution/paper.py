from __future__ import annotations
from dataclasses import dataclass
import pandas as pd

@dataclass
class PaperLedger:
    cash: float
    holdings: dict[str,float]

def simulate_exec(ledger: PaperLedger, plan: pd.DataFrame, prices: dict[str,float], fee_bps: float, slip_bps: float) -> PaperLedger:
    fees = fee_bps/10000.0; slip = slip_bps/10000.0
    h = dict(ledger.holdings); cash = float(ledger.cash)
    for _, r in plan.iterrows():
        t = r["ticker"]; side = r["side"]; qty = float(r["qty"])
        if side=="HOLD" or qty<=0: continue
        px = float(prices.get(t,0.0)); 
        if px<=0: continue
        trade_px = px * (1.0 + slip if side=="BUY" else 1.0 - slip)
        if side=="BUY":
            cost = qty*trade_px*(1.0+fees)
            if cash >= cost - 1e-9: cash -= cost; h[t] = h.get(t,0.0) + qty
        else:
            have = h.get(t,0.0); sell_qty = min(qty, have); proceeds = sell_qty*trade_px*(1.0-fees)
            cash += proceeds; h[t] = max(0.0, have - sell_qty)
    return PaperLedger(cash=cash, holdings=h)
