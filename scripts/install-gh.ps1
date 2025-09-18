param([switch]$SkipLogin)
Write-Host "Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
if (-not $SkipLogin) { Write-Host "`nLaunching gh auth login..." -ForegroundColor Yellow; gh auth login }
Write-Host "Done." -ForegroundColor Green
