from __future__ import annotations

from typing import Dict

import requests


def fetch_simple_prices(
    symbol_to_id: Dict[str, str], vs_currency: str = "aud"
) -> Dict[str, float]:
    """symbol_to_id: {"BTC": "bitcoin", "ETH": "ethereum"}"""
    if not symbol_to_id:
        return {}
    ids = ",".join({v.lower() for v in symbol_to_id.values()})
    vs = vs_currency.lower()
    url = f"https://api.coingecko.com/api/v3/simple/price?ids={ids}&vs_currencies={vs}"
    r = requests.get(url, timeout=8)
    r.raise_for_status()
    data = r.json() or {}
    out: Dict[str, float] = {}
    for sym, cid in symbol_to_id.items():
        rec = data.get(cid.lower())
        if rec and vs in rec and isinstance(rec[vs], (int, float)):
            out[sym.upper()] = float(rec[vs])
    return out
