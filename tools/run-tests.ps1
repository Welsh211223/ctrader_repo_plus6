param([switch]$Coverage)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U pytest | Out-Null
if ($Coverage) { & $py -m pip install -U pytest-cov | Out-Null }
if ($Coverage) { & $py -m pytest --maxfail=1 -q --cov=src --cov-report term-missing }
else { & $py -m pytest -q }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
