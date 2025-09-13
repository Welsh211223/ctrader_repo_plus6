Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U black isort flake8 | Out-Null
& $py -m black --check .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $py -m isort --check-only .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $py -m flake8
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "âœ… Lints clean."