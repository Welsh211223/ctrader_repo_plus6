param(
    [switch]$ReallyLive,          # require this flag for real trading
    [string]$Strategy = "default" # label passed into run.py
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die($m){
    Write-Host "[XX] $m" -ForegroundColor Red
    throw $m
}

# Resolve script + repo root
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$root = (Resolve-Path (Join-Path $here "..")).Path

# --- Optional: GitHub helpers ---
$util = Join-Path $here 'gh-token-utils.ps1'
if (Test-Path $util) {
    . $util
    if (-not $env:GITHUB_TOKEN -and (Get-Command Use-TokenFromSecret -ErrorAction SilentlyContinue)) {
        Use-TokenFromSecret | Out-Null
    }
} else {
    Warn "gh-token-utils.ps1 not found; continuing without GitHub helpers."
}

# --- Load LIVE_* secrets from SecretStore (CoinSpot) ---
try {
    $env:EXCHANGE   = (Get-Secret LIVE_EXCHANGE   -AsPlainText)
    $env:API_KEY    = (Get-Secret LIVE_API_KEY    -AsPlainText)
    $env:API_SECRET = (Get-Secret LIVE_API_SECRET -AsPlainText)
    $env:BASE_CCY   = (Get-Secret LIVE_BASE_CCY   -AsPlainText)
} catch {
    Die @"
Could not load LIVE_* secrets.

Set them once with:

  Set-Secret -Name LIVE_EXCHANGE   -Secret 'coinspot'
  Set-Secret -Name LIVE_API_KEY    -Secret '<your coinspot key>'
  Set-Secret -Name LIVE_API_SECRET -Secret '<your coinspot secret>'
  Set-Secret -Name LIVE_BASE_CCY   -Secret 'AUD'
"@
}

# --- Load Discord webhook from SecretStore ---
try {
    $discord = Get-Secret DISCORD_WEBHOOK_URL -AsPlainText
    if ($discord) {
        $env:DISCORD_WEBHOOK_URL = $discord
        Ok "Loaded DISCORD_WEBHOOK_URL from SecretStore."
    } else {
        Warn "DISCORD_WEBHOOK_URL not set in SecretStore (Discord alerts disabled)."
    }
} catch {
    Warn "Could not read DISCORD_WEBHOOK_URL from SecretStore (Discord alerts disabled)."
}

# --- Safety rails ---
if ($ReallyLive) {
    $env:LIVE_TRADING = "1"
    $env:DRY_RUN      = "0"
} else {
    $env:LIVE_TRADING = "0"
    $env:DRY_RUN      = "1"
}

$env:MAX_ORDER_NOTIONAL      = "20"   # max per order in BASE_CCY
$env:DAILY_MAX_LOSS_PCT      = "1.0"  # daily loss cap %
$env:ORDER_RATE_MAX_PER_MIN  = "12"   # anti-spam
$env:KILL_SWITCH             = "0"    # flip to "1" externally to hard stop

Info "Strategy=$Strategy"
Info "LIVE_TRADING=$($env:LIVE_TRADING), DRY_RUN=$($env:DRY_RUN)"
Info "MAX_ORDER_NOTIONAL=$($env:MAX_ORDER_NOTIONAL), DAILY_MAX_LOSS_PCT=$($env:DAILY_MAX_LOSS_PCT)"
Info "ORDER_RATE_MAX_PER_MIN=$($env:ORDER_RATE_MAX_PER_MIN)"

# --- Locate Python in venv ---
$pyCandidates = @(
    (Join-Path $root ".venv\Scripts\python.exe"),
    (Join-Path $root "venv\Scripts\python.exe")
)

$py = $null
foreach ($c in $pyCandidates) {
    if (Test-Path $c) { $py = $c; break }
}
if (-not $py) {
    Die "Python venv not found. Create .venv & install requirements."
}

# --- Entry points ---
$runTop     = Join-Path $root "run.py"
$runCtrader = Join-Path $root "ctrader\run.py"

if (Test-Path $runCtrader) {
    Ok "Using ctrader\run.py"
    & $py $runCtrader --strategy $Strategy
}
elseif (Test-Path $runTop) {
    Ok "Using top-level run.py"
    & $py $runTop --strategy $Strategy
}
else {
    Die "No known bot entrypoint found. Create run.py or ctrader\run.py."
}
