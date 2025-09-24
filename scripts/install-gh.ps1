[CmdletBinding()]
param([switch]$SkipLogin)
Write-Host "Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null
$gh = $null
try { $gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not $gh) { $gh = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path $gh)) { throw "GitHub CLI not found after install." }
& $gh --version
if (-not $SkipLogin) { Write-Host "
Launching gh auth login..." -ForegroundColor Yellow; & $gh auth login }
Write-Host "Done." -ForegroundColor Green
