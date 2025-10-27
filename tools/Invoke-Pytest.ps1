param(
  [string]$Args = "-q"
)

$ErrorActionPreference = "Stop"
$repo = Get-Location
# activate venv if needed
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python not found." }
$py = (Get-Command python).Source
if ($py -notlike "*\.venv\*") {
  $venv = Join-Path $repo ".venv\Scripts\Activate.ps1"
  if (Test-Path $venv) { & $venv }
}
# ensure pythonpath=src so imports work even if pytest picks a system install
$env:PYTHONPATH = (Join-Path $repo "src")
python -m pytest $Args
