import csv
import time

rows = [
    {"side": "BUY", "market": "BTC/AUD", "price": 100000, "notional": 75},
    {"side": "SELL", "market": "ETH/AUD", "price": 4000, "notional": 75},
]

out = "out/signals.csv"
with open(out, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=["side", "market", "price", "notional"])
    w.writeheader()
    for r in rows:
        w.writerow(r)

print(f"Wrote {out} with {len(rows)} demo signals at {time.strftime('%H:%M:%S')}.")
