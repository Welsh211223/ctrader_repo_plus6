$ErrorActionPreference = "Stop"

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK]  $m"  -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# Repo root is one level up from tools\
$toolsDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $toolsDir
$update   = Join-Path $toolsDir "update-crypto-prices.ps1"

if (-not (Test-Path $update)) {
    Write-Host "[ERR] update-crypto-prices.ps1 not found at $update" -ForegroundColor Red
    exit 1
}

Info "Repo root: $repoRoot"
Info "Updater:  $update"

$taskName = "cTrader-CryptoPrices"

# Remove any old task with same name
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Warn "Task $taskName already exists – removing it first."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Run every 5 minutes; Windows needs a finite RepetitionDuration (e.g. 30 days)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 30)

# Use pwsh if available, otherwise powershell
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) {
    $exe = $pwsh.Source
} else {
    $exe = "powershell.exe"
}

# Wrap paths in quotes
$arg = "-NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$update`""

$action = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $repoRoot

Info "Registering scheduled task $taskName..."
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal `
    -Description "Update BTC/ETH prices for cTrader dashboard (writes logs\crypto_prices.csv)."

Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

Ok "Scheduled task $taskName registered."
