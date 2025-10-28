from __future__ import annotations

import os
from pathlib import Path

import requests
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from ctrader.utils.cache import JsonDiskCache

COINGECKO_IDS = {
    "BTC": "bitcoin",
    "ETH": "ethereum",
    "XRP": "ripple",
    "HBAR": "hedera-hashgraph",
    "QNT": "quant-network",
    "SOL": "solana",
    "DOGE": "dogecoin",
    "SHIB": "shiba-inu",
    "AVAX": "avalanche-2",
    "MATIC": "matic-network",
    "BNB": "binancecoin",
    "DOT": "polkadot",
    "LTC": "litecoin",
    "BCH": "bitcoin-cash",
    "ADA": "cardano",
}


def _cache() -> JsonDiskCache:
    ttl = int(os.getenv("CACHE_TTL_SEC", "86400"))
    base = Path(__file__).resolve().parents[3] / "data" / "cache"
    return JsonDiskCache(base, ttl_sec=ttl)


def _offline() -> bool:
    return str(os.getenv("OFFLINE_MODE", "false")).lower() == "true"


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(min=1, max=8),
    retry=retry_if_exception_type(requests.RequestException),
)
def _http_json(url: str) -> dict:
    r = requests.get(url, timeout=20)
    r.raise_for_status()
    return r.json()


def fetch_history_daily(
    symbol: str, vs: str = "usd", days: int = 730
) -> list[tuple[int, float]]:
    if symbol not in COINGECKO_IDS:
        return []
    cid = COINGECKO_IDS[symbol]
    key = f"cg:hist:{cid}:{vs}:{days}:daily"
    cache = _cache()
    hit = cache.get(key)
    if hit is not None:
        return [(int(t), float(p)) for t, p in hit]
    if _offline():
        return hit or []
    url = f"https://api.coingecko.com/api/v3/coins/{cid}/market_chart?vs_currency={vs}&days={days}&interval=daily"
    try:
        data = _http_json(url)
        prices = data.get("prices", [])
        out = [(int(t), float(p)) for t, p in prices]
        cache.set(key, out)
        return out
    except Exception:
        return hit or []


def fetch_fx_usd_to_aud() -> float | None:
    cache = _cache()
    key = "fx:usd_aud"
    hit = cache.get(key)
    if hit is not None:
        try:
            return float(hit)
        except Exception:
            pass
    if _offline():
        return hit if isinstance(hit, (int, float)) else None
    try:
        data = _http_json("https://api.exchangerate.host/latest?base=USD&symbols=AUD")
        rate = float(data.get("rates", {}).get("AUD", 0.0)) or None
        if rate:
            cache.set(key, rate)
        return rate
    except Exception:
        return hit if isinstance(hit, (int, float)) else None
