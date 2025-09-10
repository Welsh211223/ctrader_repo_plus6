from __future__ import annotations

import os
import time
from typing import Callable, Dict, Optional

import pandas as pd

from ctrader.data_providers.coinspot import fetch_buy_price, fetch_sell_price
from ctrader.data_providers.coinspot_v2 import CoinSpotV2


def _bool_env(name: str, default: bool = False) -> bool:
    v = str(os.getenv(name, str(default))).strip().lower()
    return v in ("1", "true", "yes", "y", "on")


def _classify_error(ex: Exception) -> str:
    s = str(ex).lower()
    if any(k in s for k in ("timeout", "timed out")):
        return "network_timeout"
    if "429" in s or "too many requests" in s or "rate limit" in s:
        return "throttle"
    if "401" in s or "403" in s or "unauthorized" in s or "signature" in s:
        return "auth"
    if any(k in s for k in ("insufficient", "not enough", "balance")):
        return "insufficient_funds"
    return "unknown"


def _balance_safeguard(client: CoinSpotV2, sym: str, side: str, qty: float) -> float:
    """
    Clip SELL quantity to available balance to avoid rejects.
    BUY is left unchanged (AUD availability varies by account settings).
    """
    try:
        ro = client.ro_balances()
    except Exception:
        return qty

    bal = 0.0
    for k, v in (ro.get("balances", {}) or {}).items():
        if str(k).strip().upper() == sym.upper():
            try:
                bal = float(v)
            except Exception:
                pass
            break

    if side.upper() == "SELL":
        return max(0.0, min(qty, bal))
    return qty


def place_plan_coinspot(
    plan: pd.DataFrame,
    prices: Dict[str, float],
    quote: str,
    use_quote: bool,
    threshold_pct: float | None,
    direction: str | None,
    mode: str,
    max_trades: int | None,
    notify: Optional[Callable[[dict], None]] = None,
    order_timeout_sec: int = 30,
    poll_interval_sec: int = 2,
):
    """
    Execute a rebalance plan using CoinSpot V2 endpoints.

    - If COINSPOT_LIVE_DANGEROUS is not true or keys are missing, all trades are skipped safely.
    - If use_quote & threshold_pct are provided, uses BUY/SELL NOW with rate+threshold+direction guards.
    - Otherwise uses market buy/sell with a reference rate (public buy/sell or plan price).
    - After each order, polls read-only open orders briefly to detect fill/partial.
    """
    api_key = os.getenv("COINSPOT_API_KEY", "").strip()
    api_secret = os.getenv("COINSPOT_API_SECRET", "").strip()
    client = CoinSpotV2(api_key, api_secret)

    # Safety: skip live orders unless explicitly enabled
    if not (client.live_enabled and api_key and api_secret):
        out = []
        count = 0
        for _, r in plan.iterrows():
            if max_trades is not None and count >= max_trades:
                break
            side = r["side"]
            qty = float(r["qty"])
            if side == "HOLD" or qty <= 0:
                continue
            evt = {
                "ticker": r["ticker"],
                "side": side,
                "qty": qty,
                "status": "skipped (safety guard OFF)",
            }
            out.append(evt)
            if notify:
                notify(evt)
            count += 1
        return out

    def _poll_fill(sym: str, client: CoinSpotV2, timeout: int, interval: int) -> dict:
        """Poll RO open orders for symbol up to `timeout` seconds."""
        deadline = time.time() + max(1, int(timeout))
        open_left = None
        while time.time() < deadline:
            try:
                ro = client.ro_open_market_orders(
                    cointype=sym, markettype=(quote or "AUD")
                )
                orders = (
                    ro.get("orders", [])
                    or ro.get("buyorders", [])
                    or ro.get("sellorders", [])
                )
                open_left = len(orders) if isinstance(orders, list) else 0
                if open_left == 0:
                    return {"filled": True, "open": 0}
            except Exception:
                pass
            time.sleep(max(1, int(interval)))
        return {"filled": False, "open": open_left or 0}

    mkt = (quote or "AUD").upper()
    out = []
    count = 0

    for _, r in plan.iterrows():
        if max_trades is not None and count >= max_trades:
            break

        side = r["side"]
        qty = float(r["qty"])
        sym = r["ticker"]

        if side == "HOLD" or qty <= 0:
            continue
        if mode == "buy" and side != "BUY":
            continue
        if mode == "sell" and side != "SELL":
            continue

        # Balance safeguard (SELLs)
        qty = _balance_safeguard(client, sym, side, qty)

        # Determine reference rate for guards / market
        rate: float | None = None
        if use_quote:
            try:
                rate = (
                    fetch_buy_price(sym, mkt)
                    if side == "BUY"
                    else fetch_sell_price(sym, mkt)
                )
            except Exception:
                rate = None

        # Place order
        try:
            if side == "BUY":
                if use_quote and rate is not None and threshold_pct is not None:
                    resp = client.place_buy_now(
                        sym,
                        amount=qty,
                        amounttype="coin",
                        rate=rate,
                        threshold=float(threshold_pct),
                        direction=(direction or "UP"),
                    )
                else:
                    used_rate = (
                        rate if rate is not None else float(prices.get(sym, 0.0))
                    )
                    resp = client.place_market_buy(
                        sym, amount=qty, rate=used_rate, markettype=mkt
                    )
            else:  # SELL
                if use_quote and rate is not None and threshold_pct is not None:
                    resp = client.place_sell_now(
                        sym,
                        amount=qty,
                        amounttype="coin",
                        rate=rate,
                        threshold=float(threshold_pct),
                        direction=(direction or "DOWN"),
                    )
                else:
                    used_rate = (
                        rate if rate is not None else float(prices.get(sym, 0.0))
                    )
                    resp = client.place_market_sell(
                        sym, amount=qty, rate=used_rate, markettype=mkt
                    )

            ok = bool(resp.get("status", "") == "ok")
            evt = {
                "ticker": sym,
                "side": side,
                "qty": qty,
                "status": "ok" if ok else "error",
                "rate": rate,
                "market": mkt,
                "resp": resp,
            }
        except Exception as e:
            evt = {
                "ticker": sym,
                "side": side,
                "qty": qty,
                "status": "error",
                "error": str(e),
                "error_type": _classify_error(e),
            }

        # Poll for fill status
        try:
            poll = _poll_fill(sym, client, order_timeout_sec, poll_interval_sec)
            evt["fill_status"] = poll
        except Exception:
            evt["fill_status"] = {"filled": None, "open": None}

        out.append(evt)
        if notify:
            notify(evt)

        count += 1

    return out
