import csv
import datetime as dt
import math
import os
from collections import defaultdict
from statistics import mean, pstdev
from typing import Dict, List, Tuple

BASE_DIR = os.path.dirname(__file__)
LOGS_DIR = os.path.join(BASE_DIR, "..", "logs")
CC_DIR = os.path.join(LOGS_DIR, "cc_history")

# Weekly portfolio budget and base weights
WEEKLY_BUDGET_AUD = 1000.0
WEIGHTS = {
    "BTC/AUD": 0.50,
    "ETH/AUD": 0.20,
    "SOL/AUD": 0.10,
    "BNB/AUD": 0.10,
    "ADA/AUD": 0.05,
    "XRP/AUD": 0.05,
}

# Strategy config
WINDOW_DAYS = 7

MA_FAST = 50
MA_SLOW = 200
CONFIRM_DAYS = 2  # anti-whipsaw: require consecutive confirmations
# Phase 5: Core + Satellite allocation
CORE_BUDGET_PCT = 0.25  # 25% always-on core DCA (BTC/ETH)
CORE_WEIGHTS = {
    "BTC/AUD": 0.70,
    "ETH/AUD": 0.30,
}
VOL_LOOKBACK_DAYS = 30  # volatility targeting window
MAX_SINGLE_COIN_PCT = 0.60  # cap any single coin's weekly allocation
FEE_RATE = 0.0010  # 0.10% per buy (edit as you like)
SLIPPAGE_RATE = 0.0005  # 0.05% adverse slippage on buy (edit as you like)

OUT_COINS = os.path.join(LOGS_DIR, "sim_backtest_multi_trend_cc.csv")
OUT_PORTFOLIO = os.path.join(LOGS_DIR, "sim_backtest_portfolio_trend_cc.csv")


def load_cc_prices() -> Dict[str, List[Tuple[dt.date, float]]]:
    """Load daily closes per symbol from logs/cc_history/*_aud_cc.csv (CryptoCompare)."""
    per_symbol: Dict[str, List[Tuple[dt.date, float]]] = defaultdict(list)

    if not os.path.isdir(CC_DIR):
        raise FileNotFoundError(f"CC history directory not found: {CC_DIR}")

    # We expect files like btc_aud_cc.csv with columns: date, fsym, tsym, open, high, low, close, ...
    for sym in WEIGHTS.keys():
        fsym = sym.split("/")[0].lower()
        path = os.path.join(CC_DIR, f"{fsym}_aud_cc.csv")
        if not os.path.exists(path):
            continue

        with open(path, "r", newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                d = row.get("date")
                close = row.get("close")
                if not d or not close:
                    continue
                try:
                    dd = dt.date.fromisoformat(d)
                    p = float(close)
                except Exception:
                    continue
                per_symbol[sym].append((dd, p))

    # sort series
    for s in per_symbol:
        per_symbol[s].sort(key=lambda x: x[0])

    if not per_symbol:
        raise RuntimeError(
            "No CC price history loaded. Check logs/cc_history and filenames."
        )

    return per_symbol


def build_date_index(per_symbol: Dict[str, List[Tuple[dt.date, float]]]):
    price_map: Dict[str, Dict[dt.date, float]] = {}
    all_dates: List[dt.date] = []

    for sym, series in per_symbol.items():
        dmap: Dict[dt.date, float] = {}
        for d, p in series:
            dmap[d] = p
            all_dates.append(d)
        price_map[sym] = dmap

    if not all_dates:
        raise RuntimeError("No dates loaded; cannot backtest.")

    all_dates = sorted(set(all_dates))
    return price_map, all_dates


def compute_ma(
    per_symbol: Dict[str, List[Tuple[dt.date, float]]], window: int
) -> Dict[str, Dict[dt.date, float]]:
    ma_map: Dict[str, Dict[dt.date, float]] = {}
    for sym, series in per_symbol.items():
        dates = [d for d, _ in series]
        prices = [p for _, p in series]
        ma_for_sym: Dict[dt.date, float] = {}

        for i in range(len(series)):
            if i + 1 < window:
                continue
            w = prices[i + 1 - window : i + 1]
            ma_for_sym[dates[i]] = mean(w)

        ma_map[sym] = ma_for_sym
    return ma_map


def _weekday_monday(d: dt.date) -> dt.date:
    # Monday=0..Sunday=6
    return d - dt.timedelta(days=d.weekday())


def build_weekly_windows(all_dates: List[dt.date]):
    """
    Build Monday->Sunday windows, aligned to full weeks only.
    Drops partial trailing week if we don't have full week coverage.
    """
    min_d = all_dates[0]
    max_d = all_dates[-1]

    # align start to Monday
    start = _weekday_monday(min_d)

    windows = []
    cur = start
    while True:
        w_start = cur
        w_end = cur + dt.timedelta(days=6)

        if w_end > max_d:
            break  # don't include partial final week

        # also skip weeks that end before our first actual data date
        if w_end < min_d:
            cur = cur + dt.timedelta(days=7)
            continue

        windows.append((w_start, w_end))
        cur = cur + dt.timedelta(days=7)

    if not windows:
        raise RuntimeError("No full weekly windows available for the dataset.")
    return windows


def _has_confirmed_trend(
    sym: str, d: dt.date, price_map, ma_fast_map, ma_slow_map
) -> bool:
    """
    Confirmation: require CONFIRM_DAYS consecutive days (including d) satisfying:
      price > MA50 and MA50 > MA200
    """
    for k in range(CONFIRM_DAYS):
        dd = d - dt.timedelta(days=k)
        p = price_map.get(sym, {}).get(dd)
        ma_f = ma_fast_map.get(sym, {}).get(dd)
        ma_s = ma_slow_map.get(sym, {}).get(dd)
        if p is None or ma_f is None or ma_s is None:
            return False
        if not (p > ma_f and ma_f > ma_s):
            return False
    return True


def _volatility(sym: str, d: dt.date, price_map) -> float:
    """
    30d volatility proxy: std dev of daily log returns over last VOL_LOOKBACK_DAYS.
    Returns INF if insufficient data.
    """
    closes = []
    for i in range(VOL_LOOKBACK_DAYS + 1):
        dd = d - dt.timedelta(days=i)
        p = price_map.get(sym, {}).get(dd)
        if p is None:
            return float("inf")
        closes.append(p)
    closes = list(reversed(closes))

    rets = []
    for i in range(1, len(closes)):
        if closes[i - 1] <= 0 or closes[i] <= 0:
            return float("inf")
        rets.append(math.log(closes[i] / closes[i - 1]))

    if not rets:
        return float("inf")

    # population std dev is fine for a simple proxy
    return pstdev(rets)


def _apply_costs(invested: float, buy_price: float) -> Tuple[float, float]:
    """
    Apply fee + slippage at entry.
    We treat "invested" as the cash outflow budget for that buy.
    - fee reduces net invested into units
    - slippage increases effective buy price
    Returns: (units, total_cost_aud) where total_cost_aud is fee+slippage impact
    """
    if invested <= 0 or buy_price <= 0:
        return 0.0, 0.0

    fee = invested * FEE_RATE
    net = max(invested - fee, 0.0)

    eff_price = buy_price * (1.0 + SLIPPAGE_RATE)
    units = net / eff_price if eff_price > 0 else 0.0

    # "slippage cost" is conceptual; we can approximate it as net*(slippage_rate/(1+slippage_rate))
    # but we don't need to expose it separately; the units already reflect it.
    total_cost = fee  # slippage is embedded in worse fill
    return units, total_cost


def _allocate_with_caps(
    base_weights: Dict[str, float], weekly_budget: float
) -> Tuple[Dict[str, float], float]:
    """
    Given normalized weights (sum=1), produce per-coin invested amounts with MAX_SINGLE_COIN_PCT cap.
    Returns (allocations, cash_leftover).
    """
    alloc = {sym: weekly_budget * w for sym, w in base_weights.items()}
    cap_amt = weekly_budget * MAX_SINGLE_COIN_PCT

    # cap and compute leftover
    cash = 0.0
    for sym in list(alloc.keys()):
        if alloc[sym] > cap_amt:
            cash += alloc[sym] - cap_amt
            alloc[sym] = cap_amt

    # we do NOT redistribute leftover by default (keeps it simple + prevents concentration)
    return alloc, cash


def run_backtest(per_symbol, ma_fast_map, ma_slow_map, price_map, windows):
    rows_coins: List[dict] = []
    rows_portfolio: List[dict] = []

    symbols = sorted(WEIGHTS.keys())

    for w_start, w_end in windows:
        port_invested = 0.0
        port_value = 0.0
        port_trades = 0

        # 1) Find in-trend coins with confirmation at window start (using last CONFIRM_DAYS)
        in_trend = [
            sym
            for sym in symbols
            if _has_confirmed_trend(sym, w_start, price_map, ma_fast_map, ma_slow_map)
        ]

        # 2) Build dynamic weights across in-trend coins:
        #    base weight * inverse volatility (30d) -> normalized
        dyn_weights: Dict[str, float] = {}
        if in_trend:
            raw = {}
            for sym in in_trend:
                base = WEIGHTS.get(sym, 0.0)
                vol = _volatility(sym, w_start, price_map)
                if base <= 0 or not math.isfinite(vol) or vol <= 0:
                    continue
                raw[sym] = base * (1.0 / vol)

            if raw:
                s = sum(raw.values())
                if s > 0:
                    dyn_weights = {k: v / s for k, v in raw.items()}

        # If we couldn't compute vol weights, fall back to base weights normalized across in_trend
        if in_trend and not dyn_weights:
            s = sum(WEIGHTS[sym] for sym in in_trend)
            if s > 0:
                dyn_weights = {sym: WEIGHTS[sym] / s for sym in in_trend}

        # If nothing in trend, no allocations
        # Phase 5: split into CORE (always-on) + SATELLITE (trend model)
        core_budget = WEEKLY_BUDGET_AUD * CORE_BUDGET_PCT
        satellite_budget = WEEKLY_BUDGET_AUD - core_budget

        allocs = {}
        cash_left = WEEKLY_BUDGET_AUD

        # CORE: BTC/ETH always-on (no trend gating)
        core_total_w = sum(CORE_WEIGHTS.values()) if CORE_WEIGHTS else 0.0
        if core_total_w > 0:
            for s, w in CORE_WEIGHTS.items():
                if s in symbols:
                    allocs[s] = allocs.get(s, 0.0) + (core_budget * (w / core_total_w))
            cash_left -= core_budget

        # SATELLITE: only if in-trend set exists
        if dyn_weights:
            sat_allocs, sat_cash = _allocate_with_caps(dyn_weights, satellite_budget)
            for s, a in sat_allocs.items():
                allocs[s] = allocs.get(s, 0.0) + a
            cash_left -= satellite_budget - sat_cash  # only money actually deployed

        # 3) Per-coin rows + portfolio aggregation
        for sym in symbols:
            prices_for_sym = price_map.get(sym, {})
            price_start = prices_for_sym.get(w_start)
            price_end = prices_for_sym.get(w_end)

            # if missing week endpoints, skip this symbol row
            if price_start is None or price_end is None:
                continue

            invested = float(allocs.get(sym, 0.0))
            trades = 1 if invested > 0 else 0

            units, _fee_cost = _apply_costs(invested, price_start)

            market_value = units * price_end
            pnl_aud = market_value - invested
            pnl_pct = (pnl_aud / invested) * 100.0 if invested > 0 else 0.0

            rows_coins.append(
                {
                    "symbol": f"{sym} (TREND DCA MA50>MA200 + CONFIRM + VOL, CC)",
                    "trades": trades,
                    "invested_aud": round(invested, 2),
                    "units": units,
                    "last_price": price_end,
                    "market_value_aud": round(market_value, 2),
                    "pnl_aud": round(pnl_aud, 2),
                    "pnl_pct": round(pnl_pct, 2),
                    "window_start": w_start.isoformat(),
                    "window_end": w_end.isoformat(),
                }
            )

            port_invested += invested
            port_value += market_value
            port_trades += trades

        port_pnl_aud = port_value - port_invested if port_invested > 0 else 0.0
        port_pnl_pct = (
            (port_pnl_aud / port_invested) * 100.0 if port_invested > 0 else 0.0
        )

        rows_portfolio.append(
            {
                "symbol": "PORTFOLIO_TREND_CC (MA50>MA200 + CONFIRM + VOL + CAP)",
                "trades": port_trades,
                "invested_aud": round(port_invested, 2),
                "units": 0.0,
                "last_price": 0.0,
                "market_value_aud": round(port_value, 2),
                "pnl_aud": round(port_pnl_aud, 2),
                "pnl_pct": round(port_pnl_pct, 2),
                "window_start": w_start.isoformat(),
                "window_end": w_end.isoformat(),
            }
        )

    return rows_coins, rows_portfolio


def write_csv(path: str, rows: List[dict]):
    if not rows:
        print(f"[WARN] No rows to write for {path}")
        return

    fieldnames = [
        "symbol",
        "trades",
        "invested_aud",
        "units",
        "last_price",
        "market_value_aud",
        "pnl_aud",
        "pnl_pct",
        "window_start",
        "window_end",
    ]

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in rows:
            writer.writerow(r)

    print(f"[OK] Wrote {len(rows)} rows to {path}")


def main():
    print(f"[INFO] Loading CC prices from {CC_DIR}")
    per_symbol = load_cc_prices()
    print(f"[INFO] Loaded symbols: {', '.join(sorted(per_symbol.keys()))}")

    price_map, all_dates = build_date_index(per_symbol)
    ma_fast_map = compute_ma(per_symbol, MA_FAST)
    ma_slow_map = compute_ma(per_symbol, MA_SLOW)
    windows = build_weekly_windows(all_dates)
    print(
        f"[INFO] Built {len(windows)} Monday->Sunday weekly windows for CC trend backtest"
    )

    rows_coins, rows_portfolio = run_backtest(
        per_symbol,
        ma_fast_map,
        ma_slow_map,
        price_map,
        windows,
    )

    os.makedirs(LOGS_DIR, exist_ok=True)
    write_csv(OUT_COINS, rows_coins)
    write_csv(OUT_PORTFOLIO, rows_portfolio)


if __name__ == "__main__":
    main()
