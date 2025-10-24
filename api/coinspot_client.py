import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional

import requests


@dataclass
class CoinspotConfig:
    api_key: Optional[str] = None
    api_secret: Optional[str] = None
    base_url: str = os.getenv("COINSPOT_BASE_URL", "https://www.coinspot.com.au/api")
    timeout: int = 15
    dry_run: bool = True  # stays True until you flip --live 1


class CoinspotError(Exception):
    pass


class CoinspotClient:
    """
    Minimal CoinSpot private API client.
    NOTE: Confirm the exact private endpoints and required headers with CoinSpot’s docs.
    This client is structured so you only need to adjust the 'paths' below if names differ.
    """

    paths = {
        "balances": "/my/balances",  # verify
        "place_buy": "/my/buy",  # verify
        "place_sell": "/my/sell",  # verify
        "orders": "/my/orders",  # optional/verify
    }

    def __init__(self, cfg: CoinspotConfig):
        self.cfg = cfg
        self.session = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})

    def _auth_post(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.cfg.dry_run:
            return {"dry_run": True, "path": path, "payload": payload}

        if not self.cfg.api_key or not self.cfg.api_secret:
            raise CoinspotError("Missing API key/secret for live trading.")

        # Typical HMAC scheme: (Confirm with CoinSpot docs)
        # Many exchanges require a 'nonce' and HMAC-SHA512/256 of the JSON payload.
        nonce = str(int(time.time() * 1000))
        body = json.dumps({**payload, "nonce": nonce}, separators=(",", ":")).encode(
            "utf-8"
        )
        sig = hmac.new(
            self.cfg.api_secret.encode("utf-8"), body, hashlib.sha512
        ).hexdigest()

        headers = {
            "key": self.cfg.api_key,
            "sign": sig,
        }

        url = self.cfg.base_url.rstrip("/") + path
        resp = self.session.post(
            url, data=body, headers=headers, timeout=self.cfg.timeout
        )
        if resp.status_code >= 400:
            raise CoinspotError(f"HTTP {resp.status_code} {resp.text}")
        try:
            data = resp.json()
        except Exception as e:
            raise CoinspotError(f"Invalid JSON response: {resp.text}") from e

        # Many APIs have a "status"/"success" field. Adjust per CoinSpot contract.
        if isinstance(data, dict) and data.get("status") in (True, "ok", "success"):
            return data
        return data  # return raw; caller decides

    def get_balances(self) -> Dict[str, Any]:
        return self._auth_post(self.paths["balances"], {})

    def place_order(
        self, market: str, side: str, amount: float, price: Optional[float] = None
    ) -> Dict[str, Any]:
        """
        market: like 'BTC/AUD'
        side: 'buy' or 'sell'
        amount: coin amount (not notional)
        price: optional for limit; omit/None for market if API supports it.
        """
        if side not in ("buy", "sell"):
            raise ValueError("side must be 'buy' or 'sell'")

        p = {
            "cointype": market.split("/")[0],
            "amount": float(amount),
        }  # adjust param names to API
        if price is not None:
            p["rate"] = float(price)  # limit
            path = (
                self.paths["place_buy"] if side == "buy" else self.paths["place_sell"]
            )
        else:
            # If CoinSpot supports market orders: you may need different endpoints/params
            path = (
                self.paths["place_buy"] if side == "buy" else self.paths["place_sell"]
            )

        return self._auth_post(path, p)
