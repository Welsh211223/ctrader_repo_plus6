param(
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

function Die($m){
    Write-Host "[XX] $m" -ForegroundColor Red
    throw $m
}

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$root = (Resolve-Path (Join-Path $here "..")).Path

$pyCandidates = @(
    (Join-Path $root ".venv\Scripts\python.exe"),
    (Join-Path $root "venv\Scripts\python.exe")
)

$py = $null
foreach ($c in $pyCandidates) {
    if (Test-Path $c) { $py = $c; break }
}
if (-not $py) { Die "Python venv not found. Create .venv & install Flask (pip install flask)." }

$env:CTRADER_DASHBOARD_PORT = "$Port"

Write-Host "[..] Starting ctrader dashboard at http://127.0.0.1:$Port" -ForegroundColor Cyan
& $py (Join-Path $root "dashboard.py")
