import argparse
import csv
import sys


def read_signals(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def tofloat(v, dflt=0.0):
    try:
        return float(str(v).strip())
    except (ValueError, TypeError):
        return dflt


def normalize_symbol(sym: str) -> str:
    s = (sym or "").strip().upper()
    if "/" in s:
        return s
    return f"{s}/AUD" if s else s


def main():
    ap = argparse.ArgumentParser(description="CoinSpot executor (PREVIEW ONLY).")
    ap.add_argument("--signals", required=True)
    ap.add_argument("--min-notional", type=float, default=25.0)
    ap.add_argument("--default-price", type=float, default=0.0)
    ap.add_argument("--live", type=int, default=0)
    args = ap.parse_args()

    sigs = read_signals(args.signals)
    if not sigs:
        print("No signals found.")
        return

    planned = []
    for r in sigs:
        side = (r.get("side") or r.get("action") or "").strip().lower()
        amount = tofloat(r.get("amount") or r.get("qty") or r.get("quantity"), 0.0)
        price = tofloat(r.get("price"), args.default_price)
        sym = normalize_symbol(r.get("symbol") or r.get("pair") or r.get("asset"))

        if side not in ("buy", "sell"):
            continue
        notional = 0.0 if price <= 0 else amount * price
        if args.min_notional > 0 and notional > 0 and notional < args.min_notional:
            continue

        planned.append(
            {
                "symbol": sym,
                "side": side,
                "amount": amount,
                "price": price,
                "notional": notional,
            }
        )

    print(
        f"Found {len(planned)} eligible signal(s). Mode: {'LIVE' if args.live == 1 else 'PREVIEW'}"
    )
    for p in planned:
        print(
            f" - {p['side'].upper():4} {p['amount']} {p['symbol']} @ {p['price']} (notionalÃ¢â€°Ë†{p['notional']})"
        )

    if args.live == 1:
        print("LIVE requested Ã¢â‚¬â€ but this stub does NOT place real orders.")
        sys.exit(2)


if __name__ == "__main__":
    main()
