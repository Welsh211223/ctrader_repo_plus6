[CmdletBinding()]
param(
  [string]$SignalCsv   = ".\logs\latest_crypto_signal.csv",
  [string]$TradesCsv   = ".\logs\paper_trades.csv",
  [string]$DupFlag     = ".\logs\_duplicate_window.flag",

  # Safety gates
  [switch]$Live,
  [switch]$ArmLive,

  # Controls
  [decimal]$MaxSlipPct = 0.50,   # 0.50% slippage tolerance using rate+threshold
  [decimal]$MinAudBuy  = 10.00,  # set your own sensible minimum
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\coinspot.api.ps1"

function Ensure-File([string]$path, [string]$headerLine) {
  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path $path)) {
    $headerLine | Out-File -FilePath $path -Encoding utf8
  }
}

function Get-NowUtcIso() {
  return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function To-Decimal([object]$x) {
  if ($null -eq $x) { return [decimal]0 }
  $s = ([string]$x).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return [decimal]0 }
  $s = $s -replace '^[A-Za-z]\$',''
  $s = $s -replace '[, ]',''
  try { [decimal]$s } catch { [decimal]0 }
}

# Kill-switch (either env var or file)
if ($env:COINSPOT_KILL_SWITCH -eq "1" -or (Test-Path ".\logs\_KILL_SWITCH.flag")) {
  Write-Host "[live] KILL SWITCH active. Aborting." -ForegroundColor Red
  exit 2
}

if (-not $Live) {
  Write-Host "[live] Live mode not requested (-Live not set). Exiting." -ForegroundColor Yellow
  exit 0
}

if (-not $ArmLive) {
  throw "SAFETY STOP: Live execution requires -ArmLive."
}

if (-not (Test-Path $SignalCsv)) { throw "[live] Missing signal CSV: $SignalCsv" }
$signals = Import-Csv $SignalCsv
if (-not $signals -or $signals.Count -eq 0) { throw "[live] No rows in $SignalCsv" }

$ws = [string]($signals | Select-Object -First 1).window_start
$we = [string]($signals | Select-Object -First 1).window_end

# If duplicate-window flag exists, refuse (unless -Force)
if ((Test-Path $DupFlag) -and -not $Force) {
  Write-Host "[live] Duplicate window flag present ($ws -> $we). Refusing live exec. Use -Force to override." -ForegroundColor Yellow
  exit 0
}

Ensure-File $TradesCsv "ts_utc,side,base_pair,units,price_aud,notional_aud,run_id,window_start,window_end,mode,exchange_meta"

# Idempotency: if TradesCsv already has live_exec for this window, refuse (unless -Force)
if (Test-Path $TradesCsv) {
  $already = Import-Csv $TradesCsv | Where-Object {
    $_.mode -eq "live_exec" -and $_.window_start -eq $ws -and $_.window_end -eq $we
  }
  if ($already -and $already.Count -gt 0 -and -not $Force) {
    Write-Host "[live] Trades already exist for this window ($ws -> $we). Refusing live exec. Use -Force to override." -ForegroundColor Yellow
    exit 0
  }
}

# Optional: check AUD balance (CoinSpot provides balances via API; implement once you confirm endpoint you want)
# For now, we proceed and rely on CoinSpot rejecting if insufficient.

$runId = (Get-Date -Format "yyyyMMdd_HHmmss")

foreach ($s in $signals) {
  $pair = [string]$s.base_pair
  if ([string]::IsNullOrWhiteSpace($pair)) { continue }

  # Expect base_pair like BTC/AUD
  $coin = ($pair -split "/")[0].Trim().ToUpperInvariant()
  if ([string]::IsNullOrWhiteSpace($coin)) { continue }

  $act = ([string]$s.action).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($act)) { $act = "hold" }

  if ($act -ne "buy") { continue }

  $buyAud = To-Decimal $s.buy_aud
  if ($buyAud -lt $MinAudBuy) {
    Write-Host "[live] Skip $coin: buy_aud A$$buyAud below MinAudBuy A$$MinAudBuy" -ForegroundColor DarkYellow
    continue
  }

  # Round AUD to 2dp
  $buyAud = [decimal]::Round($buyAud, 2)

  Write-Host "[live] Quote buy-now: $coin for A$$buyAud ..." -ForegroundColor Cyan
  $q = Invoke-CoinSpotV2 -Path "/quote/buy/now" -Body @{
    cointype    = $coin
    amounttype  = "aud"
    amount      = $buyAud
  }

  if (-not $q -or $q.status -ne "ok") {
    throw "[live] Quote failed for $coin: $($q | ConvertTo-Json -Compress)"
  }

  $rate = To-Decimal $q.rate
  if ($rate -le 0) { throw "[live] Bad quote rate for $coin: $rate" }

  Write-Host "[live] Place buy-now: $coin for A$$buyAud (rate=$rate, threshold=$MaxSlipPct%) ..." -ForegroundColor Green
  $o = Invoke-CoinSpotV2 -Path "/my/buy/now" -Body @{
    cointype    = $coin
    amounttype  = "aud"
    amount      = $buyAud
    rate        = $rate
    threshold   = $MaxSlipPct
    direction   = "BOTH"
  }

  if (-not $o -or $o.status -ne "ok") {
    throw "[live] Order failed for $coin: $($o | ConvertTo-Json -Compress)"
  }

  # Buy-now response contains coin/market/amount/total (not an order_id per docs) :contentReference[oaicite:4]{index=4}
  $filledUnits = To-Decimal $o.amount
  $totalAud    = To-Decimal $o.total
  $ts = Get-NowUtcIso

  $meta = @{
    exchange = "coinspot"
    market   = $o.market
    rate     = $rate
  } | ConvertTo-Json -Compress

  "$ts,buy,$pair,$filledUnits,$rate,$totalAud,$runId,$ws,$we,live_exec,""$meta""" |
    Out-File -FilePath $TradesCsv -Append -Encoding utf8

  Write-Host "[live] OK $coin: units=$filledUnits total=A$$totalAud" -ForegroundColor Green
}

Write-Host "[live] DONE live execution for window $ws -> $we (run_id=$runId)" -ForegroundColor Green
