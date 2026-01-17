[CmdletBinding()]
param(
  # execution mode
  [switch]$Live,
  [switch]$ArmLive,

  # override guards (duplicate window, etc.)
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# duplicate flag path (set by pipeline when duplicate window is detected)
$dupFlag = ".\logs\_duplicate_window.flag"

# Force UTF-8 for Python/stdout (prevents encoding weirdness)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function _TS { (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') }

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
try {
  $repoRoot = Resolve-Path ".."
  Set-Location $repoRoot

  # Clear stale dup flag so each run recomputes it
  Remove-Item $dupFlag -ErrorAction SilentlyContinue

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

    # -------- Step 3.5/5 (signal metadata backfill) --------
  Write-Host "[$(_TS)] [STEP] Step 3.5/5: backfill-signal-metadata.ps1" -ForegroundColor Cyan
  & .\tools\backfill-signal-metadata.ps1
  if ($LASTEXITCODE -ne 0) { throw "[crypto] backfill-signal-metadata.ps1 failed with exit code $LASTEXITCODE" }

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
      Write-Host "[crypto] Duplicate window detected." -ForegroundColor Yellow

      "duplicate" | Out-File -FilePath $dupFlag -Encoding utf8 -Force
      $isDup = $true
    } else {
      throw
    }
  }

  if (-not $isDup -or $Force) {
    & .\tools\append-paper-ledger.ps1 -Force:$Force
    if ($LASTEXITCODE -ne 0) { throw "[crypto] append-paper-ledger.ps1 failed with exit code $LASTEXITCODE" }
  } else {
    Write-Host "[crypto] Ledger append skipped (duplicate window). Use -Force to override." -ForegroundColor Yellow
  }

  # -------- Step 4.5/5 (optional LIVE execution) --------
  if ($Live) {
    if (-not $ArmLive) {
      throw "[live] SAFETY STOP: -Live requires -ArmLive"
    }

    $ks = [string]$env:COINSPOT_KILL_SWITCH
    if ($ks -match '^(1|true|yes|on)$') {
      throw "[live] KILL SWITCH ENABLED: COINSPOT_KILL_SWITCH=$ks"
    }

    if ((Test-Path $dupFlag) -and (-not $Force)) {
      Write-Host "[live] Duplicate window flag present — skipping LIVE execution. Use -Force to override." -ForegroundColor Yellow
    } else {
      Write-Host "[$(_TS)] [STEP] Step 4.5/5: LIVE exec via CoinSpot (gated)" -ForegroundColor Magenta

      $cmd = Get-Command .\tools\exec-live-coinspot.ps1 -ErrorAction Stop
      $args = @()

      if ($cmd.Parameters.ContainsKey('Force'))   { $args += @('-Force',  ($Force.IsPresent)) }
      if ($cmd.Parameters.ContainsKey('ArmLive')) { $args += @('-ArmLive', $true) }
      if ($cmd.Parameters.ContainsKey('SignalCsv')) { $args += @('-SignalCsv', '.\logs\latest_crypto_signal.csv') }

      if ($args.Count -gt 0) {
        & .\tools\exec-live-coinspot.ps1 @args
      } else {
        & .\tools\exec-live-coinspot.ps1
      }

      if ($LASTEXITCODE -ne 0) { throw "[live] exec-live-coinspot.ps1 failed with exit code $LASTEXITCODE" }
    }
  }

  # -------- Step 5/5 (paper update) --------
  Write-Host "[$(_TS)] [STEP] Step 5/5: update-paper-portfolio.ps1 (paper sells + positions + cash)" -ForegroundColor Cyan
  & .\tools\update-paper-portfolio.ps1 -Force:$Force
  if ($LASTEXITCODE -ne 0) { throw "[crypto] update-paper-portfolio.ps1 failed with exit code $LASTEXITCODE" }

  Write-Host "[$(_TS)] [DONE] All steps complete." -ForegroundColor Green
}
finally {
  Pop-Location
}
