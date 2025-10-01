<# Repair pytest collection/import issues:
   - Archive any nested duplicate repo folders (.\ctrader_repo_plus6\*)
   - Move conflicting tests/test_imports.py out of the way
   - Purge __pycache__/ .pytest_cache
   - Ensure tests/conftest.py adds repo root to sys.path
   - Re-run tests and optionally commit/push
#>
[CmdletBinding()]
param(
  [switch]$CommitAndPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err ([string]$m){ Write-Host "[ERR ] $m" -ForegroundColor Red }

function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

# 0) Verify git repo
try { git rev-parse --is-inside-work-tree *> $null } catch { throw "Run from repo root." }

$archive = Join-Path $PWD ("z_archive_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Ensure-Dir $archive

# 1) Archive any nested duplicate repo folders (common culprit: .\ctrader_repo_plus6\*)
$repoName = Split-Path -Leaf $PWD
$dupPath  = Join-Path $PWD $repoName
if (Test-Path -LiteralPath $dupPath) {
  $dest = Join-Path $archive ($repoName + "_nested")
  Info "Archiving nested duplicate repo: $dupPath -> $dest"
  Move-Item -LiteralPath $dupPath -Destination $dest
  Ok "Archived nested folder."
}

# 2) Archive conflicting test file(s) named test_imports.py (keeps your new tests/)
$conflicts = Get-ChildItem -Recurse -ErrorAction SilentlyContinue -Filter "test_imports.py"
foreach ($c in $conflicts) {
  # Keep ONLY if it's inside the top-level .\tests we use now
  if ($c.DirectoryName -notmatch "\\tests$") {
    $dest = Join-Path $archive ("conflict_" + ($c.FullName -replace "[:\\\/ ]","_"))
    Info "Archiving conflicting test file: $($c.FullName)"
    Move-Item -LiteralPath $c.FullName -Destination $dest
    Ok "Archived $($c.Name)"
  }
}

# 3) Purge caches without nuking your venv
Info "Removing __pycache__ and .pytest_cache…"
Get-ChildItem -Recurse -Directory -Force -ErrorAction SilentlyContinue `
  | Where-Object { $_.Name -in @('__pycache__','.pytest_cache') } `
  | ForEach-Object { Remove-Item -Recurse -Force -LiteralPath $_.FullName }
Ok "Caches removed."

# 4) Ensure tests/conftest.py adds repo root to sys.path (belt-and-braces)
Ensure-Dir ".\tests"
$conftest = @'
import sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = str(ROOT)
if p not in sys.path:
    sys.path.insert(0, p)
'@
$confPath = ".\tests\conftest.py"
if (-not (Test-Path -LiteralPath $confPath)) {
  Set-Content -Path $confPath -Value $conftest -Encoding UTF8
  Ok "Wrote tests\\conftest.py"
}

# 5) Run tests
function Run-Pytest {
  Write-Host ">> pytest" -ForegroundColor Magenta
  & pytest -q
  if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }
}
try {
  Run-Pytest
  Ok "Tests passed."
} catch {
  Err $_.Exception.Message
  throw
}

# 6) Commit & push (optional)
if ($CommitAndPush) {
  git add -A
  $status = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($status)) {
    git commit -m "chore(tests): archive conflicts, clear caches, add conftest for sys.path"
    git push
    Ok "Committed and pushed."
  } else {
    Info "No changes to commit."
  }
}
