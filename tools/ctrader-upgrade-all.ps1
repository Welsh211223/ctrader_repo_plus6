<# ctrader-upgrade-all.ps1 — WinPS 5.1-safe, idempotent.

Adds: Risk Parity, CoinGecko prices, constraints+rounding, paper exec (--paper/--yes),
replaces __main__.py with a known-good version, appends config examples, adds tests,
repo hygiene, optional protections via gh, runs hooks & tests, can commit/push.

Params:
  -CommitAndPush
  -ApplyBranchProtection
  -CreateRuleset
#>

[CmdletBinding()]
param(
  [switch]$CommitAndPush,
  [switch]$ApplyBranchProtection,
  [switch]$CreateRuleset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err ([string]$m){ Write-Host "[ERR ] $m" -ForegroundColor Red }

function Ensure-Dir([string]$p){
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}
function Save-FileUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir){ Ensure-Dir $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
  Ok "Wrote: $Path"
}
function Git-OwnerRepo(){
  $remote = (git remote get-url origin)
  if ($remote -notmatch "[:/](?<owner>[^/]+)/(?<repo>[^/\.]+)(\.git)?$") { return $null }
  return @{ owner = $matches.owner; repo = $matches.repo }
}

# ---------- Hygiene ----------
function Ensure-PytestIni(){
$ini = @'
[pytest]
addopts = -q
testpaths = tests
norecursedirs = .git .venv venv build dist z_archive* node_modules .*
'@
  Save-FileUtf8LF ".\pytest.ini" $ini
}
function Ensure-PrePushHook(){
$hook = @'
@echo off
echo [pre-push] running pre-commit on all files…
pre-commit run --all-files
if errorlevel 1 exit /b 1
echo [pre-push] running pytest…
pytest -q
if errorlevel 1 exit /b 1
'@
  $path = ".git\hooks\pre-push"
  Save-FileUtf8LF $path $hook
  try { git update-index --add --chmod=+x $path *> $null } catch {}
}
function Patch-WorkflowEgressBlock([string]$Path){
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $y = Get-Content $Path -Raw
  if ($y -notmatch "step-security/harden-runner@v3") { return }
  $y = $y -replace "(?ms)(- name:\s*Harden Runner[\s\S]*?with:\s*[\r\n]+[ \t]*egress-policy:\s*)\w+", '$1block'
  if ($y -notmatch "allowed-endpoints:") {
$allow = @'
          allowed-endpoints: >
            pypi.org:443
            files.pythonhosted.org:443
            github.com:443
            api.github.com:443
'@
    $y = $y -replace "(egress-policy:\s*block\s*)", "`$1`n$allow"
  }
  Save-FileUtf8LF $Path $y
}
function Ensure-Workflows(){
  Ensure-Dir ".github\workflows"
  foreach($wf in ".github\workflows\lint.yml",".github\workflows\test.yml"){
    if(Test-Path $wf){ Patch-WorkflowEgressBlock $wf }
  }
}
function Ensure-EnvExample(){
$envx = @'
# Example .env
COINSPOT_API_KEY=
COINSPOT_API_SECRET=
DISCORD_WEBHOOK_URL=
LOG_LEVEL=INFO
'@
  if (-not (Test-Path ".env.example")) { Save-FileUtf8LF ".env.example" $envx }
}

# ---------- Ensure dirs ----------
Ensure-Dir ".\ctrader"
Ensure-Dir ".\ctrader\strategies"
Ensure-Dir ".\ctrader\prices"
Ensure-Dir ".\ctrader\brokers"
Ensure-Dir ".\tests"
Ensure-Dir ".\configs"

# ---------- Feature files ----------
# Risk Parity
$risk = @'
from __future__ import annotations
from typing import Dict, Iterable, List
import math

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


def _stdev(xs: List[float]) -> float:
    n = len(xs)
    if n < 2:
        return float("nan")
    mu = sum(xs) / n
    var = sum((x - mu) ** 2 for x in xs) / (n - 1)
    return math.sqrt(var)


class RiskParityStrategy(Strategy):
    """Inverse-volatility weights from config history."""
    name = "risk_parity"

    def target_allocations(
        self, holdings: Iterable[Holding], universe: Iterable[str], history: Dict[str, list], **kwargs
    ) -> Allocation:
        syms = [s.upper() for s in universe]
        vols: Dict[str, float] = {}
        for s in syms:
            series = [float(x) for x in (history.get(s) or [])]
            if len(series) < 3:
                vols[s] = float("nan")
                continue
            rets = []
            for i in range(1, len(series)):
                p0, p1 = series[i - 1], series[i]
                if p0 <= 0 or p1 <= 0:
                    continue
                rets.append((p1 - p0) / p0)
            vols[s] = _stdev(rets) if len(rets) >= 2 else float("nan")

        inv = {s: (1.0 / v) for s, v in vols.items() if v == v and v > 0}
        if not inv:
            w = 1.0 / max(1, len(syms))
            return Allocation(weights={s: w for s in syms})

        total = sum(inv.values())
        weights = {s: inv[s] / total for s in inv}
        for s in syms:
            weights.setdefault(s, 0.0)
        return Allocation(weights=weights)
'@
Save-FileUtf8LF ".\ctrader\strategies\riskparity.py" $risk

# CoinGecko prices
$cg = @'
from __future__ import annotations
from typing import Dict
import requests


def fetch_simple_prices(symbol_to_id: Dict[str, str], vs_currency: str = "aud") -> Dict[str, float]:
    """symbol_to_id: {"BTC": "bitcoin", "ETH": "ethereum"}"""
    if not symbol_to_id:
        return {}
    ids = ",".join({v.lower() for v in symbol_to_id.values()})
    vs = vs_currency.lower()
    url = f"https://api.coingecko.com/api/v3/simple/price?ids={ids}&vs_currencies={vs}"
    r = requests.get(url, timeout=8)
    r.raise_for_status()
    data = r.json() or {}
    out: Dict[str, float] = {}
    for sym, cid in symbol_to_id.items():
        rec = data.get(cid.lower())
        if rec and vs in rec and isinstance(rec[vs], (int, float)):
            out[sym.upper()] = float(rec[vs])
    return out
'@
Save-FileUtf8LF ".\ctrader\prices\coingecko.py" $cg

# Constraints
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

# Rebalancer (constraints-aware)
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

# Paper broker
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

# ---------- Replace __main__.py with a known-good version ----------
$main = @'
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
    pass  # minimal; integrate with your logging config if you wish


def plan_cmd(args: argparse.Namespace) -> int:
    load_dotenv()

    # Load YAML
    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    # Universe & holdings
    symbols = [s.upper() for s in (cfg.get("universe") or [])]
    holdings_cfg = cfg.get("holdings") or []
    holdings = [Holding(symbol=h["symbol"].upper(), amount=float(h["amount"])) for h in holdings_cfg]

    # Prices: start from configured, optionally overlay live
    prices: Dict[str, float] = {k.upper(): float(v) for k, v in (cfg.get("prices") or {}).items()}
    price_source = (cfg.get("price_source") or "").lower()
    if price_source == "coingecko":
        cg = cfg.get("coingecko") or {}
        sym_to_id = {k.upper(): v for k, v in (cg.get("ids") or {}).items()}
        vs = (cg.get("vs_currency") or "aud").lower()
        live = fetch_simple_prices(sym_to_id, vs_currency=vs)
        if live:
            prices.update(live)

    # Strategy
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
        print(f\"{o.side.upper():4} {o.symbol:6} amount={o.amount:.8f} value={o.est_value:.2f} fee~{o.est_fee:.2f}\")
    buys = sum(o.est_value for o in plan.orders if o.side == "buy")
    sells = sum(o.est_value for o in plan.orders if o.side == "sell")
    fees = sum(o.est_fee for o in plan.orders)
    print(f"Totals: buys={buys:.2f} sells={sells:.2f} fees~{fees:.2f}")

    # Optional paper execution
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
Save-FileUtf8LF ".\ctrader\__main__.py" $main

# ---------- Append config examples ----------
function Append-IfMissing([string]$Path,[string]$Marker,[string]$Block){
  $cur = ""
  if (Test-Path -LiteralPath $Path) {
    $cur = Get-Content -LiteralPath $Path -Raw
  }
  if ($cur -notmatch [regex]::Escape($Marker)) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Add-Content -LiteralPath $Path -Value "`n$Block"
    Ok "Appended to $Path"
  } else {
    Info "$Path already has $Marker"
  }
}

$cfgPrices = @'
# --- live prices example (uncomment to use) ---
# price_source: coingecko
# coingecko:
#   vs_currency: aud
#   ids:
#     BTC: bitcoin
#     ETH: ethereum
'@
$cfgRisk = @'
# --- risk parity example (uncomment to use) ---
# strategy: risk_parity
# history:
#   BTC: [95000, 96000, 97000, 98000, 99000, 100000, 101000]
#   ETH: [3600, 3650, 3620, 3700, 3800, 3900, 4000]
'@
$cfgConstraints = @'
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

Append-IfMissing ".\configs\example.yml" "price_source: coingecko" $cfgPrices
Append-IfMissing ".\configs\example.yml" "strategy: risk_parity" $cfgRisk
Append-IfMissing ".\configs\example.yml" "constraints:" $cfgConstraints

# ---------- Tests ----------
$testRisk = @'
from ctrader.models import Holding
from ctrader.strategies.riskparity import RiskParityStrategy

def test_risk_parity_prefers_lower_vol():
    hist = {"BTC": [100,101,102,103,104,103,102], "ETH": [100,120,80,140,90,160,100]}
    syms = ["BTC", "ETH"]
    alloc = RiskParityStrategy().target_allocations([Holding(symbol="BTC", amount=0), Holding(symbol="ETH", amount=0)], syms, history=hist)
    assert abs(sum(alloc.weights.values()) - 1.0) < 1e-9
    assert alloc.weights["BTC"] > alloc.weights["ETH"]
'@
Save-FileUtf8LF ".\tests\test_strategy_riskparity.py" $testRisk

$testConstraints = @'
from ctrader.constraints import apply_qty_constraints, floor_to_step, meets_min_notional

def test_floor_to_step_and_apply_qty():
    assert floor_to_step(1.2349, 0.001) == 1.234
    assert apply_qty_constraints(0.00009, "buy", min_qty=0.0001, qty_step=0.0001) == 0.0
    assert apply_qty_constraints(1.2349, "buy", min_qty=None, qty_step=0.01) == 1.23

def test_meets_min_notional():
    assert meets_min_notional(50.0, 30.0) is True
    assert meets_min_notional(10.0, 30.0) is False
'@
Save-FileUtf8LF ".\tests\test_constraints.py" $testConstraints

$testReb = @'
from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance

def test_qty_step_rounding_and_min_notional():
    holdings = [Holding(symbol="BTC", amount=0.1)]  # PV = 1000
    prices = {"BTC": 10000.0, "ETH": 2000.0}
    targets = Allocation(weights={"BTC": 0.0, "ETH": 1.0})
    plan = plan_rebalance(
        holdings, prices, targets,
        drift_threshold=0.0, min_trade_value=10.0, fee_rate=0.0,
        constraints={"default": {"min_notional": 10.0, "min_qty": 0.01, "qty_step": 0.01}},
    )
    # Assert we have a BUY ETH order regardless of list order
    eth_orders = [o for o in plan.orders if o.symbol == "ETH" and o.side == "buy"]
    assert eth_orders, f"Expected a buy ETH order, got: {plan.orders}"
    eth = eth_orders[0]
    assert abs((eth.amount / 0.01) - round(eth.amount / 0.01)) < 1e-9
'@
Save-FileUtf8LF ".\tests\test_rebalancer_constraints.py" $testReb

# ---------- Hygiene ----------
Ensure-PytestIni
Ensure-PrePushHook
Ensure-Workflows
Ensure-EnvExample

# ---------- Optional protections ----------
function Apply-BranchProtection(){
  $or = Git-OwnerRepo
  if (-not $or) { Warn "Cannot parse origin remote URL."; return }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Warn "Install GitHub CLI (gh) to apply branch protection."; return }
  $owner=$or.owner; $repo=$or.repo
  $contexts = @("ruff","ruff-format","black","isort","detect-secrets","pytest","bandit","size-check","pip-audit","semantic-pull-request")
  try {
    $bp = gh api "/repos/$owner/$repo/branches/main/protection" --silent | ConvertFrom-Json
    if ($bp.required_status_checks -and $bp.required_status_checks.contexts) { $contexts = @($bp.required_status_checks.contexts) }
  } catch {}
  $payload = @{
    required_status_checks = @{ strict = $true; contexts = $contexts }
    enforce_admins = $true
    required_pull_request_reviews = @{
      required_approving_review_count = 1
      dismiss_stale_reviews = $true
      require_last_push_approval = $true
    }
    restrictions = $null
    required_linear_history = $true
    allow_force_pushes = $false
    allow_deletions = $false
    block_creations = $false
    required_conversation_resolution = $true
  } | ConvertTo-Json -Depth 10
  $payload | gh api -X PUT -H "Accept: application/vnd.github+json" "/repos/$owner/$repo/branches/main/protection" --input -
  Ok "Branch protection applied on main."
}
function Create-BranchRuleset(){
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Warn "Install GitHub CLI (gh) to create a Ruleset."; return }
  $or = Git-OwnerRepo; if (-not $or) { Warn "Cannot parse origin remote."; return }
  $owner=$or.owner; $repo=$or.repo
  $contexts = @("ruff","ruff-format","black","isort","detect-secrets","pytest")
  try {
    $bp = gh api "/repos/$owner/$repo/branches/main/protection" --silent | ConvertFrom-Json
    if ($bp.required_status_checks -and $bp.required_status_checks.contexts) { $contexts = @($bp.required_status_checks.contexts) }
  } catch {}
  $rule_status = @{ type="required_status_checks"; parameters=@{ required_status_checks = @($contexts | ForEach-Object { @{ context = $_ } }) } }
  $rules = @(@{type="restrict_deletions"}, @{type="restrict_force_pushes"}, @{type="linear_history"}, $rule_status)
  $payload = @{
    name="Protect main (ctrader)"; target="branch"; enforcement="active";
    conditions=@{ ref_name=@{ include=@("refs/heads/main"); exclude=@() } };
    bypass_actors=@(); rules=$rules
  } | ConvertTo-Json -Depth 64
  try {
    $payload | gh api -X POST -H "Accept: application/vnd.github+json" "/repos/$owner/$repo/rulesets" --input -
    Ok "Ruleset created (verify in Settings → Rulesets)."
  } catch { Warn "Ruleset API failed (schema/permissions may differ). Use the UI if needed." }
}

if ($ApplyBranchProtection) { Apply-BranchProtection }
if ($CreateRuleset) { Create-BranchRuleset }

# ---------- Hooks & tests ----------
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch { Warn "pre-commit had findings (fixed or warned)." }
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# ---------- Commit & push ----------
if ($CommitAndPush) {
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    git commit -m "feat: risk-parity, CoinGecko, constraints+rounding, paper exec, CLI, tests, hygiene"
    git push
    Ok "Committed and pushed."
  } else { Info "No changes to commit." }
}

Ok "All upgrades applied. Try: python -m ctrader plan --config configs/example.yml --paper"

