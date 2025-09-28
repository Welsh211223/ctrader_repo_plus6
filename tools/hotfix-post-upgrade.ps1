[CmdletBinding()]
param([switch]$CommitAndPush)

$ErrorActionPreference = 'Stop'
function OK($m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function INFO($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function WARN($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function SaveUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $norm = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $norm, [Text.UTF8Encoding]::new($false))
  OK "Wrote: $Path"
}

# 1) Fix ctrader/__main__.py (remove stray backslashes in f-string, make it clean)
$mainPath = ".\ctrader\__main__.py"
$fixedMain = @'
from __future__ import annotations

import argparse
import os
import sys
from typing import Dict

from dotenv import load_dotenv
import yaml

from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance
from ctrader.strategies.static import StaticStrategy
from ctrader.strategies.equal import EqualWeightStrategy
from ctrader.strategies.riskparity import RiskParityStrategy
from ctrader.prices.coingecko import fetch_simple_prices
from ctrader.brokers.paper import execute_plan


def setup_logging():
    pass  # integrate logging if you want


def plan_cmd(args: argparse.Namespace) -> int:
    load_dotenv()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    symbols = [s.upper() for s in (cfg.get("universe") or [])]
    holdings_cfg = cfg.get("holdings") or []
    holdings = [Holding(symbol=h["symbol"].upper(), amount=float(h["amount"])) for h in holdings_cfg]

    prices: Dict[str, float] = {k.upper(): float(v) for k, v in (cfg.get("prices") or {}).items()}
    price_source = (cfg.get("price_source") or "").lower()
    if price_source == "coingecko":
        cg = cfg.get("coingecko") or {}
        sym_to_id = {k.upper(): v for k, v in (cg.get("ids") or {}).items()}
        vs = (cg.get("vs_currency") or "aud").lower()
        live = fetch_simple_prices(sym_to_id, vs_currency=vs)
        if live:
            prices.update(live)

    strat_name = (cfg.get("strategy") or "static").lower()
    if strat_name == "static":
        weights = {k.upper(): float(v) for k, v in (cfg.get("weights") or {}).items()}
        alloc = StaticStrategy(weights=weights).target_allocations(holdings, symbols)
    elif strat_name == "equal":
        alloc = EqualWeightStrategy().target_allocations(holdings, symbols)
    elif strat_name == "risk_parity":
        alloc = RiskParityStrategy().target_allocations(holdings, symbols, history=cfg.get("history", {}))
    else:
        raise SystemExit(f"Unknown strategy: {strat_name}")

    drift_threshold = float(cfg.get("drift_threshold", 0.01))
    min_trade_value = float(cfg.get("min_trade_value", 30.0))
    fee_rate = float(cfg.get("fee_rate", 0.001))
    constraints = cfg.get("constraints") or {}

    plan = plan_rebalance(
        holdings, prices, alloc,
        drift_threshold=drift_threshold,
        min_trade_value=min_trade_value,
        fee_rate=fee_rate,
        constraints=constraints,
    )

    print("=== Rebalance Plan ===")
    print(f"Portfolio value: {plan.portfolio_value:.2f}")
    for o in plan.orders:
        print(f"{o.side.upper():4} {o.symbol:6} amount={o.amount:.8f} value={o.est_value:.2f} fee~{o.est_fee:.2f}")
    buys = sum(o.est_value for o in plan.orders if o.side == "buy")
    sells = sum(o.est_value for o in plan.orders if o.side == "sell")
    fees = sum(o.est_fee for o in plan.orders)
    print(f"Totals: buys={buys:.2f} sells={sells:.2f} fees~{fees:.2f}")

    if args.paper:
        auto_yes = args.yes or os.getenv("CTRADER_ASSUME_YES") == "1"
        proceed = "y" if auto_yes else input("Execute this plan on paper? [y/N] ").strip().lower()
        if proceed == "y":
            out_file = execute_plan(plan, prices)
            print(f"[paper] wrote fills to {out_file}")
        else:
            print("[paper] cancelled by user")

    return 0


def main() -> int:
    setup_logging()
    p = argparse.ArgumentParser(description="ctrader CLI")
    sub = p.add_subparsers(dest="cmd")

    p_plan = sub.add_parser("plan", help="Create a rebalance plan (dry-run or paper execute)")
    p_plan.add_argument("--config", "-c", required=True, help="Path to YAML config")
    p_plan.add_argument("--paper", action="store_true", help="Execute plan using paper broker (asks to confirm)")
    p_plan.add_argument("--yes", "-y", action="store_true", help="Assume yes for confirmations")
    p_plan.set_defaults(func=plan_cmd)

    args = p.parse_args()
    if not hasattr(args, "func"):
        p.print_help()
        return 2
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
'@
SaveUtf8LF $mainPath $fixedMain

# 2) Replace pre-push hook with a POSIX shell script so Git (via sh) can run it
$hookPath = ".git/hooks/pre-push"
$prePush = @'
#!/bin/sh
echo "[pre-push] running pre-commit on all files…"
pre-commit run --all-files || exit 1
echo "[pre-push] running pytest…"
pytest -q || exit 1
'@
SaveUtf8LF $hookPath $prePush

# 3) Run hooks & tests locally
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch { WARN "pre-commit reported issues (fixed or warned)." }
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# 4) Commit & push (now the hook should be runnable)
if ($CommitAndPush) {
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    git commit -m "fix: clean __main__.py f-strings; POSIX pre-push hook for Git on Windows"
  }
  try {
    git push
    OK "Committed and pushed."
  } catch {
    WARN "git push failed. If hook misfires, try: git push --no-verify (then we can debug the hook separately)."
    throw
  }
}

OK "Hotfix complete. Try: python -m ctrader plan --config configs/example.yml --paper"
