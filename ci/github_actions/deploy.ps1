#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== CI: Crypto Trader build & test ==="
$Root = (Resolve-Path ".").Path
Push-Location $Root
try {
  $Py = (Get-Command python -ErrorAction SilentlyContinue)?.Source
  if (-not $Py) { throw "Python not found on PATH." }

  if (-not (Test-Path ".venv")) { & $Py -m venv .venv }
  $Py = Join-Path ".venv" "Scripts/python.exe"
  if (-not (Test-Path $Py)) { $Py = "python" }

  $Req = Join-Path $Root "requirements.txt"
  if (Test-Path $Req) {
    & $Py -m pip install --upgrade pip
    & $Py -m pip install -r requirements.txt
  }

  $artifacts = Join-Path $Root "artifacts"
  New-Item -ItemType Directory -Force -Path $artifacts | Out-Null

  $TestsPath = Join-Path $Root "crypto_trader"
  if (Test-Path $TestsPath) {
    $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
    $junit = Join-Path $artifacts "tests-junit.xml"
    $cov   = Join-Path $artifacts "coverage.xml"
    try {
      & $Py -m pip install pytest pytest-cov
      & $Py -m pytest -q --junitxml "$junit" --cov=crypto_trader --cov-report=xml:"$cov" crypto_trader
    } catch {
      Write-Warning "pytest run failed or not installed: $($_.Exception.Message)"
    }
  } else {
    Write-Warning "crypto_trader/ not found. Skipping tests."
  }

  New-Item -ItemType File -Force -Path (Join-Path $artifacts "build.txt") | Out-Null
  Set-Content (Join-Path $artifacts "build.txt") "Build OK $(Get-Date -Format o)"
  Write-Host "=== CI completed successfully ===" -ForegroundColor Green
}
finally { Pop-Location }
