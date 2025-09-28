<# Add Risk-Parity strategy + CoinGecko prices + CLI wiring (regex-free patching). WinPS 5.1 safe. #>
[CmdletBinding()]
param([switch]$CommitAndPush)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Ensure-Dir([string]$p){
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

function Save-FileUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Dir $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
  Ok "Wrote: $Path"
}

# --- Ensure dirs ---
Ensure-Dir ".\ctrader\strategies"
Ensure-Dir ".\ctrader\prices"
Ensure-Dir ".\tests"
Ensure-Dir ".\configs"

# --- Risk Parity strategy ---
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
    """Inverse-volatility weights from config history.
       config:
         history:
           BTC: [p1, p2, ...]
           ETH: [p1, p2, ...]
    """
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

# --- CoinGecko price fetcher ---
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

# --- Patch __main__.py (imports, risk_parity branch, live price injection) ---
$mainPath = ".\ctrader\__main__.py"
if (-not (Test-Path $mainPath)) { throw "__main__.py not found" }
$main = Get-Content $mainPath -Raw

# 1) add imports once
if ($main -notmatch "from ctrader\.strategies\.riskparity import RiskParityStrategy") {
  $needle = "from ctrader.strategies.equal import EqualWeightStrategy"
  if ($main -match [regex]::Escape($needle)) {
    $ins = @'
from ctrader.strategies.equal import EqualWeightStrategy
from ctrader.strategies.riskparity import RiskParityStrategy
from ctrader.prices.coingecko import fetch_simple_prices
'@
    $main = $main -replace [regex]::Escape($needle), ($ins.TrimEnd("`r","`n"))
  } else {
    # fallback: prepend imports after other imports
    $ins2 = @'
from ctrader.strategies.riskparity import RiskParityStrategy
from ctrader.prices.coingecko import fetch_simple_prices
'@
    $main = $main -replace "from ctrader\.strategies\.static import StaticStrategy", "from ctrader.strategies.static import StaticStrategy`n$($ins2.TrimEnd("`r","`n"))"
  }
}

# 2) inject live price support after the existing prices dict
if ($main -notmatch "price_source = ") {
  $priceLine = "prices = {k.upper(): float(v) for k, v in (cfg.get(""prices"") or {}).items()}"
  if ($main -match [regex]::Escape($priceLine)) {
    $inject = @'
        # Optional live prices
        price_source = (cfg.get("price_source") or "").lower()
        if price_source == "coingecko":
            cg = cfg.get("coingecko") or {}
            sym_to_id = {k.upper(): v for k, v in (cg.get("ids") or {}).items()}
            vs = (cg.get("vs_currency") or "aud").lower()
            live = fetch_simple_prices(sym_to_id, vs_currency=vs)
            if live:
                prices.update(live)
'@
    $main = $main -replace [regex]::Escape($priceLine), ($priceLine + "`n" + $inject.TrimEnd("`r","`n"))
  } else {
    Warn "Could not find the 'prices =' line; skipping live price insertion."
  }
}

# 3) add risk_parity elif before the 'else: raise SystemExit(...)' block
if ($main -notmatch "elif strat_name == ""risk_parity""") {
  $elseBlock = @'
        else:
            raise SystemExit(f"Unknown strategy: {strat_name}")
'@
  if ($main -match [regex]::Escape($elseBlock.TrimEnd("`r","`n"))) {
    $rp = @'
        elif strat_name == "risk_parity":
            alloc = RiskParityStrategy().target_allocations(
                holdings, symbols, history=cfg.get("history", {})
            )
        else:
            raise SystemExit(f"Unknown strategy: {strat_name}")
'@
    $main = $main -replace [regex]::Escape($elseBlock.TrimEnd("`r","`n")), ($rp.TrimEnd("`r","`n"))
  } else {
    Warn "Could not find strategy 'else:' block; skipping risk_parity insertion."
  }
}

# 4) write back __main__.py
Save-FileUtf8LF $mainPath $main

# --- Round amounts in rebalancer to 8dp (if not already) ---
$rebPath = ".\ctrader\rebalancer.py"
$reb = Get-Content $rebPath -Raw
if ($reb -notmatch "round\(value / price, 8\)") {
  $reb = $reb -replace "amount = value / price", "amount = round(value / price, 8)"
  Save-FileUtf8LF $rebPath $reb
}

# --- Append examples to example.yml ---
$cfgAppend = @'
# --- live prices example (uncomment to use) ---
# price_source: coingecko
# coingecko:
#   vs_currency: aud
#   ids:
#     BTC: bitcoin
#     ETH: ethereum

# --- risk parity example (uncomment to use) ---
# strategy: risk_parity
# history:
#   BTC: [95000, 96000, 97000, 98000, 99000, 100000, 101000]
#   ETH: [3600, 3650, 3620, 3700, 3800, 3900, 4000]
'@
Add-Content ".\configs\example.yml" "`n$cfgAppend"
Ok "Updated configs\\example.yml with examples"

# --- Test for risk parity behavior (no network) ---
$testRisk = @'
from ctrader.models import Holding
from ctrader.strategies.riskparity import RiskParityStrategy

def test_risk_parity_prefers_lower_vol():
    hist = {
        "BTC": [100, 101, 102, 103, 104, 103, 102],  # lower vol
        "ETH": [100, 120, 80, 140, 90, 160, 100],    # higher vol
    }
    syms = ["BTC", "ETH"]
    alloc = RiskParityStrategy().target_allocations(
        [Holding(symbol="BTC", amount=0), Holding(symbol="ETH", amount=0)],
        syms,
        history=hist,
    )
    assert abs(sum(alloc.weights.values()) - 1.0) < 1e-9
    assert alloc.weights["BTC"] > alloc.weights["ETH"]
'@
Save-FileUtf8LF ".\tests\test_strategy_riskparity.py" $testRisk

# --- Run hooks + tests ---
try {
  Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta
  & pre-commit run --all-files
} catch {
  Warn "pre-commit had findings (fixed or warned)."
}

Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# --- Commit & push ---
if ($CommitAndPush) {
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    git commit -m "feat: risk-parity strategy + CoinGecko prices + CLI wiring + amount rounding"
    git push
    Ok "Committed and pushed."
  } else {
    Info "No changes to commit."
  }
}

Ok "Done. Try:  python -m ctrader plan --config configs/example.yml"
