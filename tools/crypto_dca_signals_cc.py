import csv
import datetime as dt
import os
from typing import List, Tuple

BASE_DIR = os.path.dirname(__file__)
LOGS_DIR = os.path.join(BASE_DIR, "..", "logs")

CSV_PATH = os.path.join(LOGS_DIR, "sim_backtest_multi_trend_cc.csv")
OUT_TEXT = os.path.join(LOGS_DIR, "latest_crypto_signal.txt")
OUT_CSV = os.path.join(LOGS_DIR, "latest_crypto_signal.csv")

# Must match WEEKLY_BUDGET_AUD in multicoin_dca_backtest_trend_cc.py
WEEKLY_BUDGET_AUD = 1000.0


def load_rows(path: str) -> List[dict]:
    if not os.path.exists(path):
        raise SystemExit(f"[ERROR] CSV not found: {path}")
    rows: List[dict] = []
    with open(path, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)
    if not rows:
        raise SystemExit(f"[ERROR] No rows found in {path}")
    return rows


def get_latest_window(rows: List[dict]) -> Tuple[str, str]:
    candidates = []
    for r in rows:
        ws = r.get("window_start")
        we = r.get("window_end")
        if not ws or not we:
            continue
        candidates.append((ws, we))
    if not candidates:
        raise SystemExit("[ERROR] No window_start/window_end values found.")
    candidates = sorted(set(candidates))
    return candidates[-1]


def filter_window_rows(rows: List[dict], ws: str, we: str) -> List[dict]:
    out = []
    for r in rows:
        if r.get("window_start") == ws and r.get("window_end") == we:
            out.append(r)
    return out


def build_invest_rows(window_rows: List[dict]):
    invest_rows = []
    for r in window_rows:
        try:
            invested = float(r.get("invested_aud", "0") or "0")
        except ValueError:
            invested = 0.0
        if invested > 0:
            invest_rows.append((r, invested))
    return invest_rows


def write_text_report(
    invest_rows,
    latest_start: str,
    latest_end: str,
    weekly_budget: float,
) -> None:
    now_utc = dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
    lines: List[str] = []

    lines.append("=== Crypto DCA Signals (Trend Filter + Dynamic Allocation) ===")
    lines.append(f"Generated at (UTC): {now_utc}")
    lines.append(f"Window: {latest_start} -> {latest_end}")
    lines.append(f"Source: {os.path.basename(CSV_PATH)}")
    lines.append("")

    if not invest_rows:
        lines.append(
            "No coins in trend for this week " "(price <= MA50 or MA50 <= MA200)."
        )
        lines.append("-> Signal: HOLD CASH (no DCA orders).")
        lines.append("")
        lines.append(
            "NOTE: Capital is preserved this week because no coin meets the "
            "MA50 > MA200 trend criteria."
        )
        text = "\n".join(lines)
        os.makedirs(LOGS_DIR, exist_ok=True)
        with open(OUT_TEXT, "w", encoding="utf-8") as f:
            f.write(text)
        print(text)
        print(f"[OK] Saved HOLD CASH signal to {OUT_TEXT}")
        return

    # Sort by invested amount descending for nicer display
    invest_rows = sorted(invest_rows, key=lambda t: t[1], reverse=True)
    total_invested = sum(inv for _, inv in invest_rows)
    cash_unalloc = weekly_budget - total_invested

    lines.append(f"Weekly budget (model): A${weekly_budget:.2f}")
    lines.append(f"Amount actually allocated this week: A${total_invested:.2f}")
    lines.append(f"Cash not allocated (approx): A${cash_unalloc:.2f}")
    lines.append("")
    lines.append("Per-coin suggested DCA for this window:")
    lines.append("----------------------------------------")

    for r, invested in invest_rows:
        symbol_label = r.get("symbol", "")
        base_pair = symbol_label.split(" ")[0] if symbol_label else "UNKNOWN"

        try:
            units = float(r.get("units", "0") or "0")
        except ValueError:
            units = 0.0
        try:
            last_price = float(r.get("last_price", "0") or "0")
        except ValueError:
            last_price = 0.0
        try:
            pnl_pct = float(r.get("pnl_pct", "0") or "0")
        except ValueError:
            pnl_pct = 0.0

        lines.append(
            f"- {base_pair}: buy ≈ A${invested:.2f} "
            f"(units ~ {units:.6f}, last_price ~ A${last_price:.2f}, "
            f"window PnL% ~ {pnl_pct:.2f})"
        )

    lines.append("")
    lines.append("NOTE:")
    lines.append("  • This is a *weekly* signal based on MA50>MA200 trend regime.")
    lines.append("  • Budget is dynamically reallocated only across in-trend coins.")
    lines.append("  • Some weeks you will be partially or fully in cash.")
    lines.append("  • Always consider fees, slippage and your personal risk tolerance.")
    lines.append("")

    text = "\n".join(lines)
    os.makedirs(LOGS_DIR, exist_ok=True)
    with open(OUT_TEXT, "w", encoding="utf-8") as f:
        f.write(text)

    print(text)
    print(f"[OK] Saved signal text report to {OUT_TEXT}")


def write_csv_report(
    invest_rows,
    latest_start: str,
    latest_end: str,
    weekly_budget: float,
) -> None:
    os.makedirs(LOGS_DIR, exist_ok=True)

    fieldnames = [
        "symbol_label",
        "base_pair",
        "window_start",
        "window_end",
        "invested_aud",
        "units",
        "last_price",
        "window_pnl_pct",
        "weekly_budget_aud",
    ]

    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        if not invest_rows:
            # No rows to write, but we still keep the header for consistency
            return

        for r, invested in invest_rows:
            symbol_label = r.get("symbol", "")
            base_pair = symbol_label.split(" ")[0] if symbol_label else "UNKNOWN"

            try:
                units = float(r.get("units", "0") or "0")
            except ValueError:
                units = 0.0
            try:
                last_price = float(r.get("last_price", "0") or "0")
            except ValueError:
                last_price = 0.0
            try:
                pnl_pct = float(r.get("pnl_pct", "0") or "0")
            except ValueError:
                pnl_pct = 0.0

            writer.writerow(
                {
                    "symbol_label": symbol_label,
                    "base_pair": base_pair,
                    "window_start": latest_start,
                    "window_end": latest_end,
                    "invested_aud": f"{invested:.2f}",
                    "units": f"{units:.8f}",
                    "last_price": f"{last_price:.6f}",
                    "window_pnl_pct": f"{pnl_pct:.2f}",
                    "weekly_budget_aud": f"{weekly_budget:.2f}",
                }
            )

    print(f"[OK] Saved signal CSV to {OUT_CSV}")


def main():
    rows = load_rows(CSV_PATH)
    latest_start, latest_end = get_latest_window(rows)
    window_rows = filter_window_rows(rows, latest_start, latest_end)
    invest_rows = build_invest_rows(window_rows)

    print("=== Crypto DCA Signals (Trend Filter + Dynamic Allocation) ===")
    print(f"Window: {latest_start} -> {latest_end}")
    print(f"Source: {os.path.relpath(CSV_PATH)}")
    print("")

    if not invest_rows:
        # HOLD CASH case – function also prints
        write_text_report(invest_rows, latest_start, latest_end, WEEKLY_BUDGET_AUD)
        # CSV will just contain header, no rows
        write_csv_report(invest_rows, latest_start, latest_end, WEEKLY_BUDGET_AUD)
        return

    # Normal case – write files + console output
    write_text_report(invest_rows, latest_start, latest_end, WEEKLY_BUDGET_AUD)
    write_csv_report(invest_rows, latest_start, latest_end, WEEKLY_BUDGET_AUD)


if __name__ == "__main__":
    main()
