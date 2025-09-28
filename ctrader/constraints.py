from __future__ import annotations

import math
from typing import Dict, Optional


def floor_to_step(x: float, step: float) -> float:
    if step is None or step <= 0:
        return x
    q = math.floor(x / step + 1e-12)
    return round(q * step, 12)


def apply_qty_constraints(
    amount: float, side: str, min_qty: Optional[float], qty_step: Optional[float]
) -> float:
    amt = amount
    if qty_step and qty_step > 0:
        sgn = 1.0 if amt >= 0 else -1.0
        amt = floor_to_step(abs(amt), qty_step) * sgn
    if min_qty and min_qty > 0 and abs(amt) < min_qty:
        return 0.0
    return round(amt, 8)


def meets_min_notional(value: float, min_notional: Optional[float]) -> bool:
    if not min_notional or min_notional <= 0:
        return True
    return value >= min_notional


def get_symbol_constraints(symbol: str, cfg: Optional[Dict]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    if not cfg:
        return out
    s = symbol.upper()
    sym = (cfg.get(s) or {}) if isinstance(cfg, dict) else {}
    dflt = (cfg.get("default") or {}) if isinstance(cfg, dict) else {}
    for k in ("min_notional", "min_qty", "qty_step", "price_step"):
        if k in sym and sym[k] is not None:
            out[k] = float(sym[k])
        elif k in dflt and dflt[k] is not None:
            out[k] = float(dflt[k])
    return out
