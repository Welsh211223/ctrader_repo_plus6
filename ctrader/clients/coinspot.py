from __future__ import annotations

import hmac
import json
import time
from hashlib import sha512
from typing import Dict, Optional

from tenacity import retry, stop_after_attempt, wait_exponential


class CoinSpotClient:
    def __init__(
        self,
        api_key: Optional[str] = None,
        api_secret: Optional[str] = None,
        base_url: str = "https://www.coinspot.com.au/api",
    ):
        self.api_key = api_key
        self.api_secret = api_secret
        self.base_url = base_url.rstrip("/")

    def _headers(self, payload: Dict) -> Dict[str, str]:
        if not self.api_key or not self.api_secret:
            return {}
        nonce = str(int(time.time() * 1000))
        data = json.dumps(payload)
        sig = hmac.new(
            self.api_secret.encode("utf-8"), data.encode("utf-8"), sha512
        ).hexdigest()
        return {
            "Content-Type": "application/json",
            "sign": sig,
            "key": self.api_key,
            "nonce": nonce,
        }

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=0.5, max=4))
    def get_prices(self) -> Dict[str, float]:
        return {}  # TODO: implement

    def get_balances(self) -> Dict[str, float]:
        return {}  # TODO: implement

    def place_order(self, side: str, symbol: str, amount: float):
        raise NotImplementedError("Live trading not implemented yet.")
