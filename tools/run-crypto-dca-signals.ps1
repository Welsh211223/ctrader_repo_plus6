[CmdletBinding()]
param(
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Force UTF-8 for Python/stdout (prevents encoding weirdness)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function _TS { (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') }

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
try {
  $repoRoot = Resolve-Path ".."
  Set-Location $repoRoot

  Write-Host "[$(_TS)] [START] Weekly DCA signal pipeline starting..." -ForegroundColor Green

  # -------- Step 1/5 --------
  Write-Host "[$(_TS)] [STEP] Step 1/5: fetch_crypto_history_cc.py" -ForegroundColor Cyan
  & python .\tools\fetch_crypto_history_cc.py
  if ($LASTEXITCODE -ne 0) { throw "[crypto] fetch_crypto_history_cc.py failed with exit code $LASTEXITCODE" }

  # -------- Step 2/5 --------
  Write-Host "[$(_TS)] [STEP] Step 2/5: multicoin_dca_backtest_trend_cc.py" -ForegroundColor Cyan
  & python .\tools\multicoin_dca_backtest_trend_cc.py
  if ($LASTEXITCODE -ne 0) { throw "[crypto] multicoin_dca_backtest_trend_cc.py failed with exit code $LASTEXITCODE" }

  # -------- Step 3/5 --------
  Write-Host "[$(_TS)] [STEP] Step 3/5: crypto_dca_signals_cc.py" -ForegroundColor Cyan
  & python .\tools\crypto_dca_signals_cc.py
  if ($LASTEXITCODE -ne 0) { throw "[crypto] crypto_dca_signals_cc.py failed with exit code $LASTEXITCODE" }

  # -------- Step 4/5 (dup guard + optional append) --------
  Write-Host "[$(_TS)] [STEP] Step 4/5: duplicate guard + append-paper-ledger.ps1" -ForegroundColor Cyan

  $isDup = $false
  try {
    Write-Host "[crypto] Guard: duplicate-window" -ForegroundColor Yellow
    if ($Force) { & .\tools\guard-duplicate-window.ps1 -Force }
    else        { & .\tools\guard-duplicate-window.ps1 }
  }
  catch {
    $msg = $_.Exception.Message
    if ($msg -match 'DUPLICATE:\s*window') {
      Write-Host $msg -ForegroundColor Yellow
      Write-Host "[crypto] Duplicate window detected. Skipping ledger append." -ForegroundColor Yellow
      $isDup = $true
    } else {
      throw
    }
  }

  if (-not $isDup) {
    & .\tools\append-paper-ledger.ps1
    if ($LASTEXITCODE -ne 0) { throw "[crypto] append-paper-ledger.ps1 failed with exit code $LASTEXITCODE" }
  } else {
    Write-Host "[crypto] Ledger append skipped (duplicate window)." -ForegroundColor Yellow
  }

  # -------- Step 5/5 (always run) --------
  Write-Host "[$(_TS)] [STEP] Step 5/5: update-paper-portfolio.ps1 (paper sells + positions + cash)" -ForegroundColor Cyan
  & .\tools\update-paper-portfolio.ps1
  if ($LASTEXITCODE -ne 0) { throw "[crypto] update-paper-portfolio.ps1 failed with exit code $LASTEXITCODE" }

  Write-Host "[$(_TS)] [DONE] All steps complete." -ForegroundColor Green
}
finally {
  Pop-Location
}
