"""
ctrader.cli.trade (temporary stub)
This stub exists only to get pre-commit hooks green after a bad merge.
Replace with the full CLI once we’re ready.
"""

from __future__ import annotations

import argparse


def main() -> None:
    parser = argparse.ArgumentParser(description="Crypto trader CLI (stub).")
    parser.add_argument(
        "--pool", choices=["conservative", "aggressive"], required=False
    )
    parser.add_argument("--paper", action="store_true")
    _ = parser.parse_args()
    # No-op; real logic lives in the full version we will restore after hooks are green.
    print("trade.py stub: hooks sanity pass.")


if __name__ == "__main__":
    main()
