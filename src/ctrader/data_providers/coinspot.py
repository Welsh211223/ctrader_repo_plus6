from __future__ import annotations

from typing import Any, cast

import requests
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

PUB_BASE = "https://www.coinspot.com.au/pubapi/v2"


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=10),
    retry=retry_if_exception_type((requests.RequestException,)),
)
def _get(path: str) -> dict:
    url = PUB_BASE + path
    r = requests.get(url, timeout=15)
    r.raise_for_status()
    return cast(dict[Any, Any], r.json())


def fetch_prices_coinspot(symbols: list[str], market: str = "AUD") -> dict[str, float]:
    data = _get("/latest")
    prices = data.get("prices", {})
    out = {}
    m = (market or "AUD").upper()
    for s in symbols:
        key = s.lower() if m == "AUD" else f"{s.lower()}_{m.lower()}"
        p = prices.get(key, {})
        if isinstance(p, dict):
            val = p.get("last") or p.get("ask") or p.get("bid")
            out[s] = float(val) if val is not None else 0.0
        else:
            out[s] = 0.0
    return out


def fetch_buy_price(symbol: str, market: str = "AUD") -> float | None:
    m = (market or "AUD").upper()
    path = (
        f"/buyprice/{symbol.upper()}"
        if m == "AUD"
        else f"/buyprice/{symbol.upper()}/{m}"
    )
    try:
        data = _get(path)
        return float(data.get("rate", 0.0)) or None
    except Exception:
        return None


def fetch_sell_price(symbol: str, market: str = "AUD") -> float | None:
    m = (market or "AUD").upper()
    path = (
        f"/sellprice/{symbol.upper()}"
        if m == "AUD"
        else f"/sellprice/{symbol.upper()}/{m}"
    )
    try:
        data = _get(path)
        return float(data.get("rate", 0.0)) or None
    except Exception:
        return None
