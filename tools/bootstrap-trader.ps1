<#
.SYNOPSIS
  Adds trader scaffolding toward “live-ready”:
  - config split (paper/live) + .env.example
  - basic risk controls
  - paper runner + logging
  - unit tests for guards
  - .editorconfig, .gitignore

.PARAMETER CommitAndPush
.PARAMETER TriggerOnce
.PARAMETER Watch
#>

param(
  [switch]$CommitAndPush,
  [switch]$TriggerOnce,
  [switch]$Watch
)

# --- helpers ------------------------------------------------------------------
function Require-Tool($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "$name not found on PATH. Please install it and retry."
  }
}

function Write-FileUtf8LF([string]$Path, [string]$Content, [switch]$SkipIfExists) {
  if ($SkipIfExists -and (Test-Path -LiteralPath $Path)) { return }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lf = $Content -replace "`r?`n", "`n"
  if (-not $lf.EndsWith("`n")) { $lf += "`n" } # ensure single trailing newline

  if (Test-Path -LiteralPath $Path) {
    $absPath = Convert-Path -LiteralPath $Path
  } else {
    $absPath = [System.IO.Path]::GetFullPath($Path)
  }

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($absPath, $lf, $enc)
}

function Append-UniqueLine([string]$Path, [string[]]$Lines) {
  if (-not (Test-Path $Path)) { Write-FileUtf8LF $Path "" }
  $existing = @()
  try { $existing = Get-Content -LiteralPath $Path -ErrorAction Stop } catch { $existing = @() }
  foreach ($L in $Lines) { if (-not ($existing -contains $L)) { Add-Content -LiteralPath $Path -Value $L } }
}

function Git-StageCommitPush([string]$Message) {
  Require-Tool git
  git add -A | Out-Null
  git diff --cached --quiet; $has = ($LASTEXITCODE -ne 0)
  if ($has) {
    if (Get-Command pre-commit -ErrorAction SilentlyContinue) { pre-commit run --all-files; git add -A | Out-Null }
    git commit -m $Message | Out-Null
    git push
  } else { Write-Host "No changes to commit." }
}

# detect gh
$HasGH = $false; if (Get-Command gh -ErrorAction SilentlyContinue) { $HasGH = $true }

# --- files: editor & ignore ---------------------------------------------------
$editorconfig = @'
root = true

[*]
end_of_line = lf
insert_final_newline = true
charset = utf-8
trim_trailing_whitespace = true

[*.bat]
end_of_line = crlf
'@
Write-FileUtf8LF ".editorconfig" $editorconfig -SkipIfExists

$gitignore = @'
# python
__pycache__/
*.py[cod]
*.pyo
*.pyd
*.so
.venv/
.env
.env.*
.pytest_cache/
.mypy_cache/
.coverage
dist/
build/
*.egg-info/
# IDE
.vscode/
.idea/
# data/logs
data/
logs/
# OS
.DS_Store
'@
Write-FileUtf8LF ".gitignore" $gitignore -SkipIfExists

# --- env & config ------------------------------------------------------------
$envExample = @'
EXCHANGE=paper
API_KEY=
API_SECRET=
RISK_MAX_POSITION_USD=100
RISK_MAX_DAILY_LOSS_USD=50
MAX_SLIPPAGE_BPS=10
MODE=paper
'@
Write-FileUtf8LF ".env.example" $envExample -SkipIfExists

$configPaper = @'
mode: paper
base_asset: BTC
quote_asset: USDT
order_size_usd: 20
max_slippage_bps: 10
'@
Write-FileUtf8LF "configs/config.paper.yaml" $configPaper -SkipIfExists

$configLive = @'
mode: live
base_asset: BTC
quote_asset: USDT
order_size_usd: 10
max_slippage_bps: 5
# NOTE: API keys must come from environment (.env not committed).
'@
Write-FileUtf8LF "configs/config.live.yaml" $configLive -SkipIfExists

# --- python package -----------------------------------------------------------
$pkgInit = @'__all__ = []'@
Write-FileUtf8LF "ctrader/__init__.py" $pkgInit -SkipIfExists

$pkgConfig = @'
from __future__ import annotations
import os, yaml
from dataclasses import dataclass
from typing import Any, Dict
from dotenv import load_dotenv

@dataclass
class AppConfig:
    mode: str
    base_asset: str
    quote_asset: str
    order_size_usd: float
    max_slippage_bps: int

def load_config(path: str) -> AppConfig:
    load_dotenv(override=False)
    with open(path, "r", encoding="utf-8") as f:
        raw: Dict[str, Any] = yaml.safe_load(f) or {}
    mode = str(raw.get("mode", os.getenv("MODE", "paper"))).lower()
    if mode not in {"paper", "live"}:
        raise ValueError(f"Invalid mode: {mode}")
    cfg = AppConfig(
        mode=mode,
        base_asset=str(raw.get("base_asset", "BTC")),
        quote_asset=str(raw.get("quote_asset", "USDT")),
        order_size_usd=float(raw.get("order_size_usd", 10.0)),
        max_slippage_bps=int(raw.get("max_slippage_bps", int(os.getenv("MAX_SLIPPAGE_BPS", "10")))),
    )
    if cfg.mode == "live":
        if not os.getenv("API_KEY") or not os.getenv("API_SECRET"):
            raise RuntimeError("Live mode requires API_KEY and API_SECRET in environment")
    return cfg
'@
Write-FileUtf8LF "ctrader/config.py" $pkgConfig -SkipIfExists

$pkgRisk = @'
def check_max_position_usd(current_position_usd: float, add_size_usd: float, max_position_usd: float) -> bool:
    return abs(current_position_usd + add_size_usd) <= max_position_usd

def check_daily_loss_usd(today_realized_pnl_usd: float, max_daily_loss_usd: float) -> bool:
    return today_realized_pnl_usd >= -abs(max_daily_loss_usd)

def check_slippage_bps(estimated_slippage_bps: float, max_slippage_bps: int) -> bool:
    return estimated_slippage_bps <= max_slippage_bps

def enforce_all(*checks: bool) -> bool:
    return all(checks)
'@
Write-FileUtf8LF "ctrader/risk.py" $pkgRisk -SkipIfExists

$pkgExchange = @'
import random
class PaperExchange:
    def __init__(self, base: str, quote: str):
        self.base = base; self.quote = quote; self._last_price = 50000.0
    def get_price(self) -> float:
        self._last_price *= (1.0 + random.uniform(-0.001, 0.001))
        return self._last_price
    def place_order(self, side: str, usd_size: float, max_slippage_bps: int) -> dict:
        mid = self.get_price()
        slip = random.uniform(0, max_slippage_bps) / 10000.0
        px = mid * (1 + slip) if side.lower() == "buy" else mid * (1 - slip)
        qty = usd_size / px
        return {"side": side, "price": px, "qty": qty, "usd": usd_size}
'@
Write-FileUtf8LF "ctrader/exchange.py" $pkgExchange -SkipIfExists

$pkgStrategy = @'
import pandas as pd
def ema_cross(prices: pd.Series, fast: int = 12, slow: int = 26) -> str:
    if len(prices) < max(fast, slow) + 1:
        return "hold"
    ema_fast = prices.ewm(span=fast, adjust=False).mean()
    ema_slow = prices.ewm(span=slow, adjust=False).mean()
    if ema_fast.iloc[-2] <= ema_slow.iloc[-2] and ema_fast.iloc[-1] > ema_slow.iloc[-1]:
        return "buy"
    if ema_fast.iloc[-2] >= ema_slow.iloc[-2] and ema_fast.iloc[-1] < ema_slow.iloc[-1]:
        return "sell"
    return "hold"
'@
Write-FileUtf8LF "ctrader/strategies/ema_cross.py" $pkgStrategy -SkipIfExists

$pkgRunner = @'
import argparse, os, time, logging
from logging import handlers
import pandas as pd
from ctrader.config import load_config
from ctrader.risk import check_max_position_usd, check_daily_loss_usd, check_slippage_bps, enforce_all
from ctrader.exchange import PaperExchange
from ctrader.strategies.ema_cross import ema_cross

def setup_logging():
    os.makedirs("logs", exist_ok=True)
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    fh = handlers.RotatingFileHandler("logs/paper.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    ch = logging.StreamHandler()
    fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s")
    fh.setFormatter(fmt); ch.setFormatter(fmt)
    logger.addHandler(fh); logger.addHandler(ch)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config", default="configs/config.paper.yaml")
    ap.add_argument("--loops", type=int, default=50)
    args = ap.parse_args()

    setup_logging()
    cfg = load_config(args.config)
    logging.info("Loaded config: %s", cfg)

    if cfg.mode != "paper":
        raise SystemExit("Runner supports paper mode only (safe-by-default).")

    ex = PaperExchange(cfg.base_asset, cfg.quote_asset)
    prices = []
    position_usd = 0.0
    realized_pnl_usd = 0.0

    for _ in range(args.loops):
        px = ex.get_price()
        prices.append(px)
        series = pd.Series(prices[-200:])
        signal = ema_cross(series)

        ok = enforce_all(
            check_max_position_usd(position_usd, cfg.order_size_usd, float(os.getenv("RISK_MAX_POSITION_USD", "100"))),
            check_daily_loss_usd(realized_pnl_usd, float(os.getenv("RISK_MAX_DAILY_LOSS_USD", "50"))),
            check_slippage_bps(cfg.max_slippage_bps, cfg.max_slippage_bps),
        )

        if signal == "buy" and ok:
            fill = ex.place_order("buy", cfg.order_size_usd, cfg.max_slippage_bps)
            position_usd += fill["usd"]
            logging.info("BUY filled @ %.2f for $%.2f", fill["price"], fill["usd"])
        elif signal == "sell" and ok and position_usd > 0:
            fill = ex.place_order("sell", position_usd, cfg.max_slippage_bps)
            logging.info("SELL filled @ %.2f closing $%.2f", fill["price"], position_usd)
            position_usd = 0.0
        else:
            logging.info("HOLD")

        time.sleep(0.05)

    logging.info("Done (paper loop).")

if __name__ == "__main__":
    main()
'@
Write-FileUtf8LF "ctrader/runner.py" $pkgRunner -SkipIfExists

# --- tests -------------------------------------------------------------------
$testConfig = @'
import pytest
from ctrader.config import load_config

def test_live_mode_requires_keys(tmp_path, monkeypatch):
    cfg_file = tmp_path / "live.yaml"
    cfg_file.write_text("mode: live\nbase_asset: BTC\nquote_asset: USDT\norder_size_usd: 1\nmax_slippage_bps: 5\n", encoding="utf-8")
    monkeypatch.delenv("API_KEY", raising=False)
    monkeypatch.delenv("API_SECRET", raising=False)
    with pytest.raises(RuntimeError):
        load_config(str(cfg_file))
'@
Write-FileUtf8LF "tests/test_config_guard.py" $testConfig -SkipIfExists

$testRisk = @'
from ctrader.risk import check_max_position_usd, check_daily_loss_usd, enforce_all

def test_position_cap():
    assert check_max_position_usd(0, 50, 100) is True
    assert check_max_position_usd(90, 20, 100) is False

def test_daily_loss_cap():
    assert check_daily_loss_usd(0, 50) is True
    assert check_daily_loss_usd(-60, 50) is False

def test_enforce_all():
    assert enforce_all(True, True) is True
    assert enforce_all(True, False) is False
'@
Write-FileUtf8LF "tests/test_risk_limits.py" $testRisk -SkipIfExists

# --- run scripts -------------------------------------------------------------
$runPaper = @'
# Run paper-mode loop safely
python -m ctrader.runner -c configs/config.paper.yaml
'@
Write-FileUtf8LF "scripts/run_paper.ps1" $runPaper -SkipIfExists

$runBacktest = @'
Write-Host "Backtest runner not implemented yet."
'@
Write-FileUtf8LF "scripts/run_backtest.ps1" $runBacktest -SkipIfExists

# --- ensure deps present ------------------------------------------------------
Append-UniqueLine "requirements.txt" @(
  "python-dotenv>=1.0.1",
  "PyYAML>=6.0.1",
  "pandas>=2.2.2",
  "numpy>=1.26.4",
  "requests>=2.32.3",
  "tabulate>=0.9.0",
  "tenacity>=8.2.3",
  "matplotlib>=3.9.0",
  "streamlit>=1.36.0",
  "pytest>=8.2.0"
)

# --- commit/push & optional CI trigger --------------------------------------
if ($CommitAndPush) {
  Git-StageCommitPush "feat(scaffold): config split, risk controls, paper runner, logging, tests, editorconfig, gitignore"
}

if ($TriggerOnce) {
  if (-not $HasGH) { Write-Warning "gh CLI not available; skipping trigger/watch." }
  else {
    $wf = ".github/workflows/tests.yml"
    if (-not (Test-Path $wf)) { Write-Warning "Workflow $wf not found; skipping trigger."; }
    else {
      $wfName = Split-Path $wf -Leaf
      $branch = (git rev-parse --abbrev-ref HEAD).Trim()
      Write-Host "Canceling queued/in-progress runs for '$wfName' on '$branch'..."
      $q = gh run list --workflow $wfName --branch $branch --status queued --json databaseId -q '.[].databaseId' 2>$null
      $p = gh run list --workflow $wfName --branch $branch --status in_progress --json databaseId -q '.[].databaseId' 2>$null
      @($q + $p) | ForEach-Object { if ($_ -and ($_ -match '^\d+$')) { gh run cancel $_ | Out-Null } }
      Write-Host "Triggering run for '$wfName' on '$branch'..."
      gh workflow run $wf --ref $branch 2>$null
      if ($LASTEXITCODE -eq 0 -and $Watch) {
        Start-Sleep -Seconds 2
        $rid = gh run list --workflow $wfName --branch $branch --limit 1 --json databaseId -q '.[0].databaseId'
        if ($rid) { gh run watch $rid --exit-status; gh run view $rid --log }
      }
    }
  }
}

Write-Host "Bootstrap complete."
