# tools\safe-run.ps1 — run any command with live trading forcibly disabled (paper-safe)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($args.Count -eq 0) {
  Write-Host "Usage: .\tools\safe-run.ps1 <command> [args...]" -ForegroundColor Yellow
  Write-Host "Example: .\tools\safe-run.ps1 .\.venv\Scripts\python.exe -m ctrader.backtest"
  exit 1
}

# Force paper mode in this child process
$env:COINSPOT_LIVE_DANGEROUS = 'false'
Remove-Item Env:\CONFIRM_LIVE -ErrorAction SilentlyContinue

# Run the requested command
& $args[0] @($args[1..($args.Count-1)])
exit $LASTEXITCODE