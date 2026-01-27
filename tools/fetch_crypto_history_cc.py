import csv
import datetime as dt
import os
import time
from pathlib import Path
from typing import Dict, List, cast

import requests

BASE_DIR = Path(__file__).resolve().parent
LOGS_DIR = BASE_DIR / ".." / "logs"
OUT_DIR = LOGS_DIR / "cc_history"

API_KEY_ENV = "CRYPTOCOMPARE_API_KEY"
API_KEY = os.environ.get(API_KEY_ENV)

# How many days of history to request (CryptoCompare histoday max is 2000)
DAYS_BACK = 1825  # ~5 years

# fsym on CryptoCompare, and our label for the file/symbol
ASSETS = [
    ("BTC", "BTC/AUD"),
    ("ETH", "ETH/AUD"),
    ("SOL", "SOL/AUD"),
    ("BNB", "BNB/AUD"),
    ("ADA", "ADA/AUD"),
    ("XRP", "XRP/AUD"),
]


def get_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": "ctrader-multi-year-fetch/1.0"})
    return s


def fetch_histoday(
    session: requests.Session,
    fsym: str,
    tsym: str = "AUD",
    days_back: int = DAYS_BACK,
) -> List[dict]:
    """
    Fetch daily OHLCV from CryptoCompare histoday endpoint.
    """
    limit = min(days_back, 2000) - 1  # limit is number of points - 1
    url = "https://min-api.cryptocompare.com/data/v2/histoday"
    params: dict[str, str | int] = {
        "fsym": fsym,
        "tsym": tsym,
        "limit": int(limit),
    }
    if API_KEY:
        params["api_key"] = API_KEY

    print(f"[INFO] Requesting {fsym}/{tsym} histoday with limit={limit} ...")
    resp = session.get(url, params=params, timeout=30)
    if resp.status_code != 200:
        raise RuntimeError(
            f"HTTP {resp.status_code} from CryptoCompare for {fsym}/{tsym}: {resp.text}"
        )

    data = resp.json()
    if data.get("Response") != "Success":
        raise RuntimeError(f"Bad response for {fsym}/{tsym}: {data}")

    bars = data.get("Data", {}).get("Data", [])
    print(f"[INFO] Got {len(bars)} daily bars for {fsym}/{tsym}")

    bars_typed = cast(list[dict[str, object]], bars)
    return bars_typed


def write_ohlcv_csv(
    out_path: Path,
    fsym: str,
    tsym: str,
    bars: List[dict],
) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "date",
        "fsym",
        "tsym",
        "open",
        "high",
        "low",
        "close",
        "volumefrom",
        "volumeto",
    ]

    rows: List[Dict[str, str]] = []

    for b in bars:
        ts = b.get("time")
        close = b.get("close", 0)
        if ts is None:
            continue
        # Convert unix time -> YYYY-MM-DD
        d = dt.datetime.utcfromtimestamp(ts).date().isoformat()

        rows.append(
            {
                "date": d,
                "fsym": fsym,
                "tsym": tsym,
                "open": str(b.get("open", "")),
                "high": str(b.get("high", "")),
                "low": str(b.get("low", "")),
                "close": str(close),
                "volumefrom": str(b.get("volumefrom", "")),
                "volumeto": str(b.get("volumeto", "")),
            }
        )

    rows.sort(key=lambda r: r["date"])

    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in rows:
            writer.writerow(r)

    print(f"[OK] Wrote {len(rows)} rows to {out_path}")


def main():
    if not API_KEY:
        raise SystemExit(
            f"[ERROR] {API_KEY_ENV} is not set. Please set your CryptoCompare API key "
            f"in the environment first."
        )

    print(f"[INFO] Using {API_KEY_ENV} (length={len(API_KEY)})")
    print(f"[INFO] Logs directory: {LOGS_DIR}")
    print(f"[INFO] Output directory: {OUT_DIR}")

    session = get_session()

    for fsym, label in ASSETS:
        try:
            bars = fetch_histoday(session, fsym, "AUD", DAYS_BACK)
        except Exception as e:
            print(f"[ERROR] Failed to fetch {fsym}/AUD: {e}")
            continue

        out_file = OUT_DIR / f"{fsym.lower()}_aud_cc.csv"
        write_ohlcv_csv(out_file, fsym, "AUD", bars)
        time.sleep(0.5)  # gentle on the API

    print("[DONE] CryptoCompare multi-year fetch complete.")


if __name__ == "__main__":
    main()
