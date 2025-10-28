param(
  [switch]$NoRun
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
Set-Location $repo

function Use-Venv {
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python not found." }
  $py = (Get-Command python).Source
  if ($py -notlike "*\.venv\*") {
    $venv = Join-Path $repo ".venv\Scripts\Activate.ps1"
    if (Test-Path $venv) { & $venv }
  }
}
Use-Venv

# Ensure ignores
$gi = ".gitignore"
if (-not (Test-Path $gi)) { Set-Content -Path $gi -Encoding utf8 -NoNewline -Value "" }
$rules = @("*.egg-info/","src/ctrader.egg-info/",".streamlit/",".pytest_cache/",".ruff_cache/","**/__pycache__/")
$cur = (Get-Content -Raw $gi)
foreach($r in $rules){ if(-not ($cur -split "`r?`n" | Where-Object {$_ -eq $r})){ Add-Content -Path $gi -Encoding utf8 -Value "`n$r" } }
git rm -r --cached src/ctrader.egg-info 2>$null | Out-Null

# Install tools
python -m pip install -U pip setuptools wheel | Out-Null
python -m pip install -e . | Out-Null
python -m pip install pre-commit | Out-Null

# Optional run of hooks
try { pre-commit run -a } catch { }

git add -A
if (git diff --cached --name-only) {
  try { git commit -S -m "chore(dev): dev-fix-and-run; ignore build; apply hook fixes" }
  catch { git commit -m "chore(dev): dev-fix-and-run; ignore build; apply hook fixes" }
  try { git push --force-with-lease } catch { git push -u origin (git branch --show-current) }
}

if (-not $NoRun) {
  $app = "src\ctrader\app.py"
  if (-not (Test-Path $app)) { throw "Streamlit app not found at $app" }
  python -m streamlit run $app
}
