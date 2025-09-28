<# Add order constraints + paper execution (regex-safe). WinPS 5.1 OK. #>
[CmdletBinding()]
param([switch]$CommitAndPush)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
function Save-FileUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir){ Ensure-Dir $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
  Ok "Wrote: $Path"
}

# --- Files/dirs ---
Ensure-Dir ".\ctrader"
Ensure-Dir ".\ctrader\brokers"

# constraints.py
$constraints = @'
from __future__ import annotations
import math
from typing import Dict, Optional

def floor_to_step(x: float, step: float) -> float:
    if step is None or step <= 0:
        return x
    q = math.floor(x / step + 1e-12)
    return round(q * step, 12)

def apply_qty_constraints(amount: float, side: str, min_qty: Optional[float], qty_step: Optional[float]) -> float:
    amt = amount
    if qty_step and qty_step > 0:
        sgn = 1.0 if amt >= 0 else -1.0
        amt = floor_to_step(abs(amt), qty_step) * sgn
    if min_qty and min_qty > 0 and abs(amt) < min_qty:
        return 0.0
    return round(amt, 8)

def meets_min_notional(value: float, min_notional: Optional[float]) -> bool:
    if not min_notional or min_notional <= 0:
        return True
    return value >= min_notional

def get_symbol_constraints(symbol: str, cfg: Optional[Dict]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    if not cfg:
        return out
    s = symbol.upper()
    sym = (cfg.get(s) or {}) if isinstance(cfg, dict) else {}
    dflt = (cfg.get("default") or {}) if isinstance(cfg, dict) else {}
    for k in ("min_notional", "min_qty", "qty_step", "price_step"):
        if k in sym and sym[k] is not None:
            out[k] = float(sym[k])
        elif k in dflt and dflt[k] is not None:
            out[k] = float(dflt[k])
    return out
'@
Save-FileUtf8LF ".\ctrader\constraints.py" $constraints

# rebalancer.py (constraints-aware)
$rebalancer = @'
from __future__ import annotations
from typing import Dict, Iterable, List, Optional
from ctrader.constraints import apply_qty_constraints, get_symbol_constraints, meets_min_notional
from ctrader.models import Allocation, Holding, Order, TradePlan

def plan_rebalance(
    holdings: Iterable[Holding],
    prices: Dict[str, float],
    targets: Allocation,
    drift_threshold: float = 0.01,
    min_trade_value: float = 30.0,
    fee_rate: float = 0.001,
    constraints: Optional[Dict] = None,
) -> TradePlan:
    by_symbol = {h.symbol.upper(): h for h in holdings}
    prices = {k.upper(): float(v) for k, v in prices.items()}
    targets_w = targets.weights

    pv = 0.0
    for sym, h in by_symbol.items():
        p = prices.get(sym)
        if p:
            pv += h.amount * p
    if pv <= 0:
        return TradePlan(orders=[], portfolio_value=0.0, note="No portfolio value")

    orders: List[Order] = []

    for sym, w in targets_w.items():
        price = prices.get(sym)
        if not price or price <= 0:
            continue
        cur_amt = by_symbol.get(sym).amount if sym in by_symbol else 0.0
        cur_val = cur_amt * price
        desired_val = w * pv
        diff_val = desired_val - cur_val
        if abs(diff_val) < drift_threshold * pv:
            continue

        side = "buy" if diff_val > 0 else "sell"
        value = abs(diff_val)

        c = get_symbol_constraints(sym, constraints)
        min_notional = float(c.get("min_notional", min_trade_value))
        min_qty = c.get("min_qty")
        qty_step = c.get("qty_step")

        raw_amount = value / price
        amt = apply_qty_constraints(raw_amount, side, min_qty, qty_step)
        adj_value = abs(amt * price)
        if amt <= 0 or not meets_min_notional(adj_value, min_notional):
            continue

        est_fee = adj_value * fee_rate
        orders.append(Order(side=side, symbol=sym, amount=amt, est_value=adj_value, est_fee=est_fee))

    return TradePlan(orders=orders, portfolio_value=pv, note="rebalance plan")
'@
Save-FileUtf8LF ".\ctrader\rebalancer.py" $rebalancer

# paper broker
$paper = @'
from __future__ import annotations
import csv, os, time
from typing import Dict
from ctrader.models import TradePlan

def execute_plan(plan: TradePlan, prices: Dict[str, float], out_path: str = "paper_trades.csv") -> str:
    if not plan.orders:
        return out_path
    exists = os.path.exists(out_path)
    with open(out_path, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if not exists:
            w.writerow(["ts", "side", "symbol", "amount", "price", "value", "est_fee"])
        ts = int(time.time())
        for o in plan.orders:
            price = float(prices.get(o.symbol, 0.0))
            value = float(o.amount * price)
            w.writerow([ts, o.side, o.symbol, o.amount, price, value, o.est_fee])
    return out_path
'@
Save-FileUtf8LF ".\ctrader\brokers\paper.py" $paper

# patch __main__.py safely
$mainPath = ".\ctrader\__main__.py"
if (-not (Test-Path $mainPath)) { throw "__main__.py not found" }
$main = Get-Content $mainPath -Raw

# ensure paper import
if ($main -notmatch 'from ctrader\.brokers\.paper import execute_plan') {
  $main = $main -replace 'from ctrader\.strategies\.static import StaticStrategy',
'from ctrader.strategies.static import StaticStrategy
from ctrader.brokers.paper import execute_plan'
}

# add --paper and --yes by replacing the existing --config line
$marker = 'p_plan.add_argument("--config", "-c", required=True, help="Path to YAML config")'
if ($main -match [regex]::Escape($marker)) {
  $block = @'
p_plan.add_argument("--config", "-c", required=True, help="Path to YAML config")
    p_plan.add_argument("--paper", action="store_true", help="Execute plan using paper broker (asks to confirm)")
    p_plan.add_argument("--yes", "-y", action="store_true", help="Assume yes for confirmations")
'@
  $main = $main -replace [regex]::Escape($marker), ($block.TrimEnd("`r","`n"))
}

# load constraints from config after fee_rate line
$feeMarker = 'fee_rate = float(cfg.get("fee_rate", 0.001))'
if ($main -match [regex]::Escape($feeMarker) -and $main -notmatch 'constraints = cfg\.get\("constraints"') {
  $inject = '        constraints = cfg.get("constraints") or {}'
  $main = $main -replace [regex]::Escape($feeMarker), ($feeMarker + "`n" + $inject)
}

# paper execution block after s = plan.summary()
if ($main -notmatch 'if args\.paper:') {
  $sumMarker = 's = plan.summary()'
  $extra = @'
        # Optional execution (paper)
        if args.paper:
            auto_yes = args.yes or os.getenv("CTRADER_ASSUME_YES") == "1"
            proceed = "y" if auto_yes else input("Execute this plan on paper? [y/N] ").strip().lower()
            if proceed == "y":
                out_file = execute_plan(plan, prices)
                print(f"[paper] wrote fills to {out_file}")
            else:
                print("[paper] cancelled by user")
'@
  if ($main -match [regex]::Escape($sumMarker)) {
    $main = $main -replace [regex]::Escape($sumMarker), ($sumMarker + "`n" + $extra.TrimEnd("`r","`n"))
  }
}

Save-FileUtf8LF $mainPath $main

# append constraints to example config
$cfgAppend = @'
# --- per-exchange style constraints (examples) ---
constraints:
  default:
    min_notional: 30
    min_qty: 0.000001
    qty_step: 0.000001
  BTC:
    min_qty: 0.00001
    qty_step: 0.000001
  ETH:
    min_qty: 0.0001
    qty_step: 0.0001
'@
Add-Content ".\configs\example.yml" "`n$cfgAppend"
Ok "Updated configs\\example.yml with constraints example"

# tests
$test1 = @'
from ctrader.constraints import apply_qty_constraints, floor_to_step, meets_min_notional

def test_floor_to_step_and_apply_qty():
    assert floor_to_step(1.2349, 0.001) == 1.234
    assert apply_qty_constraints(0.00009, "buy", min_qty=0.0001, qty_step=0.0001) == 0.0
    assert apply_qty_constraints(1.2349, "buy", min_qty=None, qty_step=0.01) == 1.23

def test_meets_min_notional():
    assert meets_min_notional(50.0, 30.0) is True
    assert meets_min_notional(10.0, 30.0) is False
'@
Save-FileUtf8LF ".\tests\test_constraints.py" $test1

$test2 = @'
from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance

def test_qty_step_rounding_and_min_notional():
    # PV=1000 via BTC holding
    holdings = [Holding(symbol="BTC", amount=0.1)]
    prices = {"BTC": 10000.0, "ETH": 2000.0}
    targets = Allocation(weights={"BTC": 0.0, "ETH": 1.0})
    plan = plan_rebalance(
        holdings,
        prices,
        targets,
        drift_threshold=0.0,
        min_trade_value=10.0,
        fee_rate=0.0,
        constraints={"default": {"min_notional": 10.0, "min_qty": 0.01, "qty_step": 0.01}},
    )
    assert plan.orders and plan.orders[0].symbol == "ETH"
    assert abs((plan.orders[0].amount / 0.01) - round(plan.orders[0].amount / 0.01)) < 1e-9
'@
Save-FileUtf8LF ".\tests\test_rebalancer_constraints.py" $test2

# hooks + tests
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch {}
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# commit
if ($CommitAndPush) {
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    git commit -m "feat(exec): constraints + paper execution + CLI flags (regex-safe patch)"
    git push
    Ok "Committed and pushed."
  } else { Info "No changes to commit." }
}

Ok "Done. Try: python -m ctrader plan --config configs/example.yml --paper"
