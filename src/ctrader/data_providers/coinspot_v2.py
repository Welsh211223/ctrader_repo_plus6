from __future__ import annotations

import hashlib
import hmac
import json
import time
from typing import Any, Dict

try:
    import requests
except ImportError:  # pragma: no cover
    requests = None  # type: ignore[assignment]

API_BASE = "https://www.coinspot.com.au/api"
RO_BASE = "https://www.coinspot.com.au/api/ro"


def _nonce() -> str:
    return str(int(time.time() * 1000))


def _headers(api_key: str, api_secret: str, payload: Dict[str, Any]) -> Dict[str, str]:
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    sig = hmac.new(api_secret.encode("utf-8"), raw, hashlib.sha512).hexdigest()
    return {"Content-Type": "application/json", "key": api_key, "sign": sig}


def _post(url: str, headers: Dict[str, str], payload: Dict[str, Any]) -> Dict[str, Any]:
    if requests is None:
        return {"success": False, "error": "requests not available", "url": url}
    r = requests.post(url, headers=headers, data=json.dumps(payload))
    try:
        data = r.json()
    except Exception:
        return {"success": False, "status": r.status_code, "text": r.text}
    if isinstance(data, dict):
        return data
    return {"success": False, "status": r.status_code, "text": str(data)}


class CoinSpotV2:
    """
    Minimal v2 client exposing the attributes/methods used elsewhere in the repo.
    """

    # expected by coinspot_execution.py
    live_enabled: bool = False

    def __init__(self, api_key: str, api_secret: str) -> None:
        self.api_key = api_key
        self.api_secret = api_secret

    def _auth_post(
        self, path: str, payload: Dict[str, Any] | None = None
    ) -> Dict[str, Any]:
        data: Dict[str, Any] = dict(payload or {})
        data.setdefault("nonce", _nonce())
        return _post(
            API_BASE + path, _headers(self.api_key, self.api_secret, data), data
        )

    def _ro_post(
        self, path: str, payload: Dict[str, Any] | None = None
    ) -> Dict[str, Any]:
        data: Dict[str, Any] = dict(payload or {})
        data.setdefault("nonce", _nonce())
        return _post(
            RO_BASE + path, _headers(self.api_key, self.api_secret, data), data
        )

    # -------- Authenticated --------
    def status(self) -> Dict[str, Any]:
        return self._auth_post("/status", {})

    def balances(self) -> Dict[str, Any]:
        return self._auth_post("/my/balances", {})

    # Methods expected by coinspot_execution.py
    def place_market_buy(
        self,
        cointype: str,
        amount: float,
        amounttype: str = "coin",
        rate: float | None = None,
        markettype: str | None = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {
            "cointype": cointype.upper(),
            "amounttype": amounttype,
            "amount": float(amount),
        }
        if rate is not None:
            p["rate"] = float(rate)
        if markettype is not None:
            p["markettype"] = str(markettype).upper()
        return self._auth_post("/my/buy/market", p)

    def place_market_sell(
        self,
        cointype: str,
        amount: float,
        amounttype: str = "coin",
        rate: float | None = None,
        markettype: str | None = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {
            "cointype": cointype.upper(),
            "amounttype": amounttype,
            "amount": float(amount),
        }
        if rate is not None:
            p["rate"] = float(rate)
        if markettype is not None:
            p["markettype"] = str(markettype).upper()
        return self._auth_post("/my/sell/market", p)

    # Your explicit "now" endpoints (kept)
    def place_buy_now(
        self,
        cointype: str,
        amount: float,
        amounttype: str = "coin",
        rate: float | None = None,
        threshold: float | None = None,
        direction: str | None = None,
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {
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
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {
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

    def cancel_buy(self, order_id: str) -> Dict[str, Any]:
        return self._auth_post("/my/buy/cancel", {"id": order_id})

    def cancel_sell(self, order_id: str) -> Dict[str, Any]:
        return self._auth_post("/my/sell/cancel", {"id": order_id})

    # -------- Read-only --------
    def ro_status(self) -> Dict[str, Any]:
        return self._ro_post("/status", {})

    def ro_balances(self) -> Dict[str, Any]:
        return self._ro_post("/my/balances", {})

    def ro_open_market_orders(
        self, cointype: str | None = None, markettype: str | None = None
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {}
        if cointype:
            p["cointype"] = cointype.upper()
        if markettype:
            p["markettype"] = markettype.upper()
        return self._ro_post("/orders/market/open", p)

    def ro_market_order_history(
        self, cointype: str | None = None, markettype: str | None = None
    ) -> Dict[str, Any]:
        p: Dict[str, Any] = {}
        if cointype:
            p["cointype"] = cointype.upper()
        if markettype:
            p["markettype"] = markettype.upper()
        return self._ro_post("/my/marketorders/history", p)


__all__ = ["CoinSpotV2"]
