from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass

import requests
from tenacity import (retry, retry_if_exception_type, stop_after_attempt,
                      wait_exponential)

API_BASE = "https://www.coinspot.com.au/api/v2"
RO_BASE = "https://www.coinspot.com.au/api/v2/ro"


def _bool_env(name: str, default: bool = False) -> bool:
    v = str(os.getenv(name, str(default))).strip().lower()
    return v in ("1", "true", "yes", "y", "on")


def _nonce() -> int:
    return int(time.time() * 1000)


def _headers(api_key: str, api_secret: str, payload: dict) -> dict:
    msg = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    sig = hmac.new(
        api_secret.encode("utf-8"), msg.encode("utf-8"), hashlib.sha512
    ).hexdigest()
    return {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "sign": sig,
        "key": api_key,
    }


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=8),
    retry=retry_if_exception_type((requests.RequestException,)),
)
def _post(url: str, headers: dict, payload: dict) -> dict:
    r = requests.post(url, json=payload, headers=headers, timeout=20)
    if r.status_code != 200:
        raise requests.RequestException(f"HTTP {r.status_code}: {r.text[:200]}")
    return r.json()


@dataclass
class CoinSpotV2:
    api_key: str
    api_secret: str

    @property
    def live_enabled(self) -> bool:
        return _bool_env("COINSPOT_LIVE_DANGEROUS", False)

    def _auth_post(self, path: str, payload: dict | None = None) -> dict:
        payload = dict(payload or {})
        payload.setdefault("nonce", _nonce())
        return _post(
            API_BASE + path, _headers(self.api_key, self.api_secret, payload), payload
        )

    def _ro_post(self, path: str, payload: dict | None = None) -> dict:
        payload = dict(payload or {})
        payload.setdefault("nonce", _nonce())
        return _post(
            RO_BASE + path, _headers(self.api_key, self.api_secret, payload), payload
        )

    # Full-access
    def status(self) -> dict:
        return self._auth_post("/status", {})

    def quote_buy_now(
        self, cointype: str, amount: float, amounttype: str = "coin"
    ) -> dict:
        return self._auth_post(
            "/quote/buy/now",
            {
                "cointype": cointype.upper(),
                "amount": float(amount),
                "amounttype": amounttype,
            },
        )

    def quote_sell_now(
        self, cointype: str, amount: float, amounttype: str = "coin"
    ) -> dict:
        return self._auth_post(
            "/quote/sell/now",
            {
                "cointype": cointype.upper(),
                "amount": float(amount),
                "amounttype": amounttype,
            },
        )

    def place_market_buy(
        self, cointype: str, amount: float, rate: float, markettype: str | None = None
    ) -> dict:
        payload = {
            "cointype": cointype.upper(),
            "amount": float(amount),
            "rate": float(rate),
        }
        if markettype and markettype.upper() != "AUD":
            payload["markettype"] = markettype.upper()
        return self._auth_post("/my/buy", payload)

    def place_market_sell(
        self, cointype: str, amount: float, rate: float, markettype: str | None = None
    ) -> dict:
        payload = {
            "cointype": cointype.upper(),
            "amount": float(amount),
            "rate": float(rate),
        }
        if markettype and markettype.upper() != "AUD":
            payload["markettype"] = markettype.upper()
        return self._auth_post("/my/sell", payload)

    def place_buy_now(
        self,
        cointype: str,
        amount: float,
        amounttype: str = "coin",
        rate: float | None = None,
        threshold: float | None = None,
        direction: str | None = None,
    ) -> dict:
        p = {
            "cointype": cointype.upper(),
            "amounttype": amounttype,
            "amount": float(amount),
        }
        if rate is not None:
            p["rate"] = float(rate)
        if threshold is not None:
            p["threshold"] = float(threshold)
        if direction:
            p["direction"] = str(direction).upper()
        return self._auth_post("/my/buy/now", p)

    def place_sell_now(
        self,
        cointype: str,
        amount: float,
        amounttype: str = "coin",
        rate: float | None = None,
        threshold: float | None = None,
        direction: str | None = None,
    ) -> dict:
        p = {
            "cointype": cointype.upper(),
            "amounttype": amounttype,
            "amount": float(amount),
        }
        if rate is not None:
            p["rate"] = float(rate)
        if threshold is not None:
            p["threshold"] = float(threshold)
        if direction:
            p["direction"] = str(direction).upper()
        return self._auth_post("/my/sell/now", p)

    def cancel_buy(self, order_id: str) -> dict:
        return self._auth_post("/my/buy/cancel", {"id": order_id})

    def cancel_sell(self, order_id: str) -> dict:
        return self._auth_post("/my/sell/cancel", {"id": order_id})

    # Read-only
    def ro_status(self) -> dict:
        return self._ro_post("/status", {})

    def ro_balances(self) -> dict:
        return self._ro_post("/my/balances", {})

    def ro_open_market_orders(
        self, cointype: str | None = None, markettype: str | None = None
    ) -> dict:
        p = {}
        if cointype:
            p["cointype"] = cointype.upper()
        if markettype:
            p["markettype"] = markettype.upper()
        return self._ro_post("/orders/market/open", p)

    def ro_market_order_history(
        self, cointype: str | None = None, markettype: str | None = None
    ) -> dict:
        p = {}
        if cointype:
            p["cointype"] = cointype.upper()
        if markettype:
            p["markettype"] = markettype.upper()
        return self._ro_post("/my/marketorders/history", p)
