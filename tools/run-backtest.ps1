# tools\run-backtest.ps1 — try to run backtest in paper mode
param([string[]]$ExtraArgs)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$py = Join-Path (Resolve-Path "$PSScriptRoot\..") ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

# Force paper mode
$env:COINSPOT_LIVE_DANGEROUS = 'false'
Remove-Item Env:\CONFIRM_LIVE -ErrorAction SilentlyContinue

Write-Host "Running backtest in paper mode..." -ForegroundColor Cyan
& $py -m ctrader.backtest @ExtraArgs
$code = $LASTEXITCODE

if ($code -ne 0) {
  Write-Warning "Could not run 'python -m ctrader.backtest' (exit $code)."
  Write-Host  "Tip: If your backtest has a different entry-point, use safe-run:"
  Write-Host  "  .\tools\safe-run.ps1 $py -m your.module --your-args"
}
exit $code