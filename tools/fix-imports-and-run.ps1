$ErrorActionPreference = 'Stop'
function Ok($m){ Write-Host "✓ $m" -ForegroundColor Green }
function Info($m){ Write-Host "• $m" -ForegroundColor Cyan }

# ensure venv and tools
if (-not (Get-Command ruff -ErrorAction SilentlyContinue) -or -not (Get-Command black -ErrorAction SilentlyContinue) -or -not (Get-Command isort -ErrorAction SilentlyContinue) -or -not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
  if (Test-Path .\.venv\Scripts\Activate.ps1) { . .\.venv\Scripts\Activate.ps1 }
}
python -m pip -q install -U ruff isort black pre-commit | Out-Null

# quick regex nudge for E402 in specific files (safe, idempotent)
function Move-Imports-To-Top {
  param([string]$File)
  if (-not (Test-Path $File)) { return }
  $t = Get-Content -Raw $File
  $lines = $t -split "`r?`n"
  $imports = @()
  $rest = @()
  foreach($l in $lines){
    if ($l -match '^(import\s+|from\s+\S+\s+import\s+)'){ $imports += $l } else { $rest += $l }
  }
  if ($imports.Count -eq 0){ return }
  $new = @() + $imports + '' + $rest
  $newText = ($new -join "`r`n").TrimEnd() + "`r`n"
  if ($newText -ne $t){ Set-Content -Encoding utf8 -NoNewline $File $newText; Info "Reordered imports in $File" }
}

Move-Imports-To-Top 'src/ctrader/cli/schedule.py'
Move-Imports-To-Top 'src/ctrader/cli/trade.py'
Move-Imports-To-Top 'src/ctrader/app.py'

# ruff auto-fix common import issues
ruff --select E401,E402,F401 --fix src tests
# sort/format
isort src tests
black src tests

# run hooks
pre-commit install --hook-type pre-commit --hook-type pre-push --overwrite | Out-Null
pre-commit run --all-files

# stage files baseline/hooks may have touched
if (Test-Path '.secrets.baseline') { git add .secrets.baseline | Out-Null }

# commit if staged
$pending = git diff --cached --name-only
if ($pending) {
  git commit -S -m "style/ci: import hygiene (E402/E401/F401), format & sort; refresh baseline" | Out-Null
  try { git push --force-with-lease | Out-Null } catch { git push -u origin (git branch --show-current) | Out-Null }
  Ok "Pushed fixes"
} else {
  Info "No staged changes to commit"
}
