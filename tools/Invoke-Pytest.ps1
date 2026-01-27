param(
  [string]$Args = "-q",
  [switch]$WithCoverage
)
$ErrorActionPreference = "Stop"
$repo = Get-Location
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python not found." }
$py = (Get-Command python).Source
if ($py -notlike "*\.venv\*") {
  $venv = Join-Path $repo ".venv\Scripts\Activate.ps1"
  if (Test-Path $venv) { & $venv }
}
$env:PYTHONPATH = (Join-Path $repo "src")
if ($WithCoverage) {
  # rely on pytest.ini addopts; just run pytest
  python -m pytest $Args
} else {
  python -m pytest $Args
}
