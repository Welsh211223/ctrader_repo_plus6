<# Add ctrader core (models, strategies, rebalancer, CLI), config, tests.
   WinPS 5.1 safe: single-quoted here-strings; closers at column 1.
#>
[CmdletBinding()]
param([switch]$CommitAndPush)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err ([string]$m){ Write-Host "[ERR ] $m" -ForegroundColor Red }

function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

function Save-FileUtf8LF {
  param([string]$Path,[string]$Content,[switch]$SkipIfExists)
  if ($SkipIfExists -and (Test-Path -LiteralPath $Path)) { return }
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Dir $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
  Ok "Wrote: $Path"
}

# --- dirs ---
Ensure-Dir ".\ctrader"
Ensure-Dir ".\ctrader\strategies"
Ensure-Dir ".\ctrader\clients"
Ensure-Dir ".\ctrader\notifiers"
Ensure-Dir ".\configs"
Ensure-Dir ".\tests"

# models.py
$models = @'
from __future__ import annotations
from typing import Dict, List, Literal, Optional
from pydantic import BaseModel, Field, field_validator

class Holding(BaseModel):
    symbol: str = Field(..., description="Asset symbol, e.g., BTC")
    amount: float = Field(..., ge=0.0)
    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()

class Quote(BaseModel):
    symbol: str
    price: float = Field(..., gt=0.0)
    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()

class Allocation(BaseModel):
    weights: Dict[str, float] = Field(default_factory=dict)
    @field_validator("weights")
    @classmethod
    def validate_weights(cls, w: Dict[str, float]) -> Dict[str, float]:
        total = sum(w.values())
        if not w:
            raise ValueError("Allocation weights cannot be empty.")
        if not (0.999 <= total <= 1.001):
            raise ValueError(f"Weights must sum to 1.0 ±0.001, got {total:.6f}")
        if any(x < 0 for x in w.values()):
            raise ValueError("Weights must be non-negative.")
        if abs(total - 1.0) > 1e-9:
            w = {k: v / total for k, v in w.items()}
        return {k.upper(): v for k, v in w.items()}

Side = Literal["buy", "sell"]

class Order(BaseModel):
    side: Side
    symbol: str
    amount: float = Field(..., gt=0.0)
    est_value: float = Field(..., gt=0.0)
    est_fee: float = Field(default=0.0, ge=0.0)
    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()

class TradePlan(BaseModel):
    orders: List[Order] = Field(default_factory=list)
    portfolio_value: float = 0.0
    note: Optional[str] = None
    def summary(self) -> Dict[str, float]:
        buys = sum(o.est_value for o in self.orders if o.side == "buy")
        sells = sum(o.est_value for o in self.orders if o.side == "sell")
        fees = sum(o.est_fee for o in self.orders)
        return {"buys": buys, "sells": sells, "fees": fees}
'@
Save-FileUtf8LF ".\ctrader\models.py" $models

# strategies/base.py
$strat_base = @'
from __future__ import annotations
from typing import Iterable
from ctrader.models import Allocation, Holding

class Strategy:
    name: str = "base"
    def target_allocations(self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs) -> Allocation:
        raise NotImplementedError
'@
Save-FileUtf8LF ".\ctrader\strategies\base.py" $strat_base

# strategies/static.py
$strat_static = @'
from __future__ import annotations
from typing import Dict, Iterable
from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy

class StaticStrategy(Strategy):
    name = "static"
    def target_allocations(self, holdings: Iterable[Holding], universe: Iterable[str], weights: Dict[str, float], **kwargs) -> Allocation:
        return Allocation(weights=dict(weights))
'@
Save-FileUtf8LF ".\ctrader\strategies\static.py" $strat_static

# strategies/equal.py
$strat_equal = @'
from __future__ import annotations
from typing import Iterable
from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy

class EqualWeightStrategy(Strategy):
    name = "equal"
    def target_allocations(self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs) -> Allocation:
        u = [s.upper() for s in universe]
        n = len(u)
        if n == 0:
            raise ValueError("Universe cannot be empty for EqualWeightStrategy.")
        w = 1.0 / n
        return Allocation(weights={s: w for s in u})
'@
Save-FileUtf8LF ".\ctrader\strategies\equal.py" $strat_equal

# rebalancer.py
$rebalancer = @'
from __future__ import annotations
from typing import Dict, Iterable, List
from ctrader.models import Allocation, Holding, Order, TradePlan

def plan_rebalance(
    holdings: Iterable[Holding],
    prices: Dict[str, float],
    targets: Allocation,
    drift_threshold: float = 0.01,
    min_trade_value: float = 30.0,
    fee_rate: float = 0.001,
) -> TradePlan:
    by_symbol = {h.symbol.upper(): h for h in holdings}
    prices = {k.upper(): float(v) for k, v in prices.items()}
    targets_w = targets.weights

    pv = 0.0
    for sym, h in by_symbol.items():
        if sym in prices:
            pv += h.amount * prices[sym]

    orders: List[Order] = []
    if pv <= 0:
        return TradePlan(orders=[], portfolio_value=0.0, note="No portfolio value")

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
        if abs(diff_val) < min_trade_value:
            continue

        side = "buy" if diff_val > 0 else "sell"
        value = abs(diff_val)
        est_fee = value * fee_rate
        amount = value / price
        if amount <= 0:
            continue

        orders.append(Order(side=side, symbol=sym, amount=amount, est_value=value, est_fee=est_fee))

    return TradePlan(orders=orders, portfolio_value=pv, note="rebalance plan")
'@
Save-FileUtf8LF ".\ctrader\rebalancer.py" $rebalancer

# clients/coinspot.py (stub)
$coinspot = @'
from __future__ import annotations
import hmac, json, time
from hashlib import sha512
from typing import Dict, Optional
import requests
from tenacity import retry, stop_after_attempt, wait_exponential

class CoinSpotClient:
    def __init__(self, api_key: Optional[str] = None, api_secret: Optional[str] = None, base_url: str = "https://www.coinspot.com.au/api"):
        self.api_key = api_key
        self.api_secret = api_secret
        self.base_url = base_url.rstrip("/")

    def _headers(self, payload: Dict) -> Dict[str, str]:
        if not self.api_key or not self.api_secret:
            return {}
        nonce = str(int(time.time() * 1000))
        data = json.dumps(payload)
        sig = hmac.new(self.api_secret.encode("utf-8"), data.encode("utf-8"), sha512).hexdigest()
        return {"Content-Type": "application/json", "sign": sig, "key": self.api_key, "nonce": nonce}

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=0.5, max=4))
    def get_prices(self) -> Dict[str, float]:
        return {}  # TODO: implement

    def get_balances(self) -> Dict[str, float]:
        return {}  # TODO: implement

    def place_order(self, side: str, symbol: str, amount: float):
        raise NotImplementedError("Live trading not implemented yet.")
'@
Save-FileUtf8LF ".\ctrader\clients\coinspot.py" $coinspot

# notifiers/discord.py (stub)
$discord = @'
from __future__ import annotations
import os, requests

def notify(message: str) -> None:
    url = os.getenv("DISCORD_WEBHOOK_URL")
    if not url:
        print("[discord] " + message); return
    try:
        requests.post(url, json={"content": message}, timeout=5)
    except Exception as e:
        print(f"[discord] error: {e}")
'@
Save-FileUtf8LF ".\ctrader\notifiers\discord.py" $discord

# __main__.py
$main = @'
from __future__ import annotations
import argparse, logging, os
from typing import Dict
import yaml
from dotenv import load_dotenv
from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance
from ctrader.strategies.equal import EqualWeightStrategy
from ctrader.strategies.static import StaticStrategy

def setup_logging() -> None:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO), format="%(asctime)s %(levelname)s %(name)s: %(message)s")

def load_config(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

def main() -> None:
    load_dotenv(); setup_logging()
    parser = argparse.ArgumentParser(description="ctrader CLI")
    sub = parser.add_subparsers(dest="cmd")
    p_plan = sub.add_parser("plan", help="Create a rebalance plan (dry-run)")
    p_plan.add_argument("--config", "-c", required=True, help="Path to YAML config")
    args = parser.parse_args()
    if args.cmd == "plan":
        cfg = load_config(args.config)
        symbols = [s.upper() for s in cfg.get("universe", [])]
        holdings_cfg = cfg.get("holdings", [])
        prices = {k.upper(): float(v) for k, v in (cfg.get("prices") or {}).items()}
        min_trade_value = float(cfg.get("min_trade_value", 30.0))
        drift_threshold = float(cfg.get("drift_threshold", 0.01))
        fee_rate = float(cfg.get("fee_rate", 0.001))
        holdings = [Holding(symbol=h["symbol"], amount=float(h["amount"])) for h in holdings_cfg]
        strat_name = (cfg.get("strategy") or "static").lower()
        if strat_name == "equal":
            alloc = EqualWeightStrategy().target_allocations(holdings, symbols)
        elif strat_name == "static":
            alloc = StaticStrategy().target_allocations(holdings, symbols, weights=cfg.get("static_weights", {}))
        else:
            raise SystemExit(f"Unknown strategy: {strat_name}")
        plan = plan_rebalance(holdings=holdings, prices=prices, targets=alloc, drift_threshold=drift_threshold, min_trade_value=min_trade_value, fee_rate=fee_rate)
        print("=== Rebalance Plan ===")
        print(f"Portfolio value: {plan.portfolio_value:.2f}")
        for o in plan.orders:
            print(f"{o.side.upper():4} {o.symbol:6} amount={o.amount:.8f} value={o.est_value:.2f} fee~{o.est_fee:.2f}")
        s = plan.summary()
        print(f"Totals: buys={s['buys']:.2f} sells={s['sells']:.2f} fees~{s['fees']:.2f}")
        return
    parser.print_help()

if __name__ == "__main__":
    main()
'@
Save-FileUtf8LF ".\ctrader\__main__.py" $main

# example config
$cfg = @'
universe: [BTC, ETH]
strategy: static
static_weights:
  BTC: 0.60
  ETH: 0.40
holdings:
  - { symbol: BTC, amount: 0.005 }
  - { symbol: ETH, amount: 0.50 }
prices:
  BTC: 100000
  ETH: 4000
drift_threshold: 0.01
min_trade_value: 30.0
fee_rate: 0.001
'@
Save-FileUtf8LF ".\configs\example.yml" $cfg

# tests
$test_rebal = @'
from ctrader.models import Allocation, Holding
from ctrader.rebalancer import plan_rebalance

def test_rebalance_static_two_assets():
    holdings = [Holding(symbol="BTC", amount=0.005), Holding(symbol="ETH", amount=0.50)]
    prices = {"BTC": 100000.0, "ETH": 4000.0}
    targets = Allocation(weights={"BTC": 0.5, "ETH": 0.5})
    plan = plan_rebalance(holdings, prices, targets, drift_threshold=0.0, min_trade_value=10.0, fee_rate=0.0)
    sides = {o.symbol: o.side for o in plan.orders}
    assert sides["BTC"] == "buy"
    assert sides["ETH"] == "sell"
    amt = {o.symbol: o.amount for o in plan.orders}
    assert abs(amt["BTC"] - 0.0075) < 1e-6
    assert abs(amt["ETH"] - 0.1875) < 1e-6
'@
Save-FileUtf8LF ".\tests\test_rebalancer_basic.py" $test_rebal

# pytest.ini (BOM-free)
$pytest = @'
[pytest]
addopts = -q
testpaths = tests
norecursedirs = .git .venv venv build dist z_archive* node_modules .*
'@
Save-FileUtf8LF ".\pytest.ini" $pytest

# Ensure pydantic >= 2.7 in requirements
$reqPath = "requirements.txt"
if (Test-Path $reqPath) {
  $cur = Get-Content $reqPath -Raw
  if ($cur -notmatch "(?im)^\s*pydantic\s*>=\s*2") {
    $cur = $cur.TrimEnd() + "`n" + "pydantic>=2.7"
    [IO.File]::WriteAllText($reqPath, $cur, [Text.UTF8Encoding]::new($false))
    Ok "Updated requirements.txt with pydantic>=2.7"
  }
} else {
  Save-FileUtf8LF $reqPath "pydantic>=2.7"
}

# install + lint + test
try { Write-Host ">> pip install -r requirements.txt" -ForegroundColor Magenta; & pip install -r requirements.txt | Out-Null } catch { Warn "pip install failed: $($_.Exception.Message)" }
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch { Warn "pre-commit had findings (fixed or warned)." }
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

if ($CommitAndPush) {
  git add -A
  $status = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($status)) {
    git commit -m "feat(core): models, strategies, rebalancer, CLI, config, tests"
    git push
    Ok "Committed and pushed."
  } else {
    Info "No changes to commit."
  }
}

Ok "Core added. Try:  python -m ctrader plan --config configs/example.yml"
