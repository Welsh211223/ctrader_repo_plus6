param(
    [switch]$ReallyLive,          # require this flag for real trading
    [string]$Strategy = "default" # adapt to your code
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die($m){  Write-Host "[XX] $m" -ForegroundColor Red; throw $m }

# Resolve paths relative to this script (tools/)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path $ScriptDir -Parent

# Load token helpers if present
$util = Join-Path $ScriptDir 'gh-token-utils.ps1'
if (Test-Path $util) {
    . $util
} else {
    Warn "gh-token-utils.ps1 not found; continuing without GitHub helpers."
}

# Try to ensure GITHUB_TOKEN is present (optional, for GitHub API / CI)
if (Get-Command Use-TokenFromSecret -ErrorAction SilentlyContinue) {
    Use-TokenFromSecret | Out-Null
}

# Load LIVE exchange secrets from SecretStore
try {
    $env:EXCHANGE   = (Get-Secret LIVE_EXCHANGE   -AsPlainText)
    $env:API_KEY    = (Get-Secret LIVE_API_KEY    -AsPlainText)
    $env:API_SECRET = (Get-Secret LIVE_API_SECRET -AsPlainText)
    $env:BASE_CCY   = (Get-Secret LIVE_BASE_CCY   -AsPlainText)
} catch {
    Die "Could not load LIVE_* secrets from SecretStore. Run:
  Set-Secret -Name LIVE_EXCHANGE -Secret 'binance'
  Set-Secret -Name LIVE_API_KEY -Secret '<key>'
  Set-Secret -Name LIVE_API_SECRET -Secret '<secret>'
  Set-Secret -Name LIVE_BASE_CCY -Secret 'USDT'"
}

# Safety rails
if ($ReallyLive) {
    $env:LIVE_TRADING = "1"
    $env:DRY_RUN      = "0"
} else {
    $env:LIVE_TRADING = "0"
    $env:DRY_RUN      = "1"
}

$env:MAX_ORDER_NOTIONAL      = "20"
$env:DAILY_MAX_LOSS_PCT      = "1.0"
$env:ORDER_RATE_MAX_PER_MIN  = "12"
$env:KILL_SWITCH             = "0"

Info "Strategy=$Strategy"
Info "LIVE_TRADING=$($env:LIVE_TRADING), DRY_RUN=$($env:DRY_RUN)"
Info "MAX_ORDER_NOTIONAL=$($env:MAX_ORDER_NOTIONAL), DAILY_MAX_LOSS_PCT=$($env:DAILY_MAX_LOSS_PCT)"
Info "ORDER_RATE_MAX_PER_MIN=$($env:ORDER_RATE_MAX_PER_MIN)"

# Python venv
$py = Join-Path $RepoRoot ".venv\Scripts\python.exe"
if (!(Test-Path $py)) {
    Die "Python venv not found at .venv\Scripts\python.exe"
}

# Locate a plausible entrypoint for your bot.
# Adjust this once you know the correct one.
if (Test-Path (Join-Path $RepoRoot "ctrader\run.py")) {
    & $py (Join-Path $RepoRoot "ctrader\run.py") --strategy $Strategy
}
elseif (Test-Path (Join-Path $RepoRoot "run.py")) {
    & $py (Join-Path $RepoRoot "run.py") --strategy $Strategy
}
else {
    Die "No known bot entrypoint found.
Edit tools\run-live.ps1 to call your actual main script/module."
}
