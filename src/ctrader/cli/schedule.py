from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
import time
from pathlib import Path

# path shim

SRC_DIR = Path(__file__).resolve().parents[3]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))


def main():
    ap = argparse.ArgumentParser(description="Simple scheduler for ctrader.cli.trade")
    ap.add_argument("--interval-sec", type=int, default=1800, help="How often to run.")
    ap.add_argument("--pool", choices=["conservative", "aggressive"], required=True)
    ap.add_argument(
        "--max-runs", type=int, default=0, help="Stop after N runs (0 = infinite)."
    )
    ap.add_argument(
        "--python", type=str, default=sys.executable, help="Python interpreter to use."
    )
    ap.add_argument(
        "--extra",
        type=str,
        default="",
        help='Extra args for trade, e.g. "--turnover-adaptive --notify"',
    )
    args = ap.parse_args()

    cmd_base = f"{shlex.quote(args.python)} -m ctrader.cli.trade --pool {args.pool} {args.extra}".strip()

    run = 0
    while True:
        run += 1
        print(f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}] Run {run}: {cmd_base}")
        try:
            rc = subprocess.call(cmd_base, shell=True)
            print(f"[run {run}] exit code: {rc}")
        except KeyboardInterrupt:
            print("Scheduler interrupted. Exiting.")
            break
        except Exception as e:
            print(f"[run {run}] error: {e}")

        if args.max_runs and run >= args.max_runs:
            print("Reached max_runs. Exiting.")
            break

        time.sleep(max(5, int(args.interval_sec)))


if __name__ == "__main__":
    main()
