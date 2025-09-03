from __future__ import annotations
import argparse
from pathlib import Path
from ctrader.backtest import run_backtest
from ctrader.analytics import equity_stats

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(Path(__file__).resolve().parents[3] / "config" / "pools.yaml"))
    ap.add_argument("--pool", choices=["conservative","aggressive"], required=True)
    ap.add_argument("--days", type=int, default=365)
    args = ap.parse_args()
    df = run_backtest(args.config, args.pool, bt_days=int(args.days))
    outdir = Path(__file__).resolve().parents[3] / "data" / "backtests"; outdir.mkdir(parents=True, exist_ok=True)
    outfp = outdir / f"bt_{args.pool}_{__import__('datetime').datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}.csv"; df.to_csv(outfp, index=False); print(f"Saved backtest to: {outfp}")
    stats = equity_stats(df["equity"]); print("Backtest stats:", stats)

if __name__ == "__main__":
    main()
