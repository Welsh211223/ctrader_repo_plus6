#Requires -Version 7
param(
  [string]$Venv = ".venv\Scripts\python.exe",
  [string[]]$BadTerms = @("edgefinder","medai","vnext","edgefinder_v5","EF_","MEDAI_")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Let native tools return non-zero without throwing; we check $LASTEXITCODE ourselves.
$PSNativeCommandUseErrorActionPreference = $false

function Ok($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "[XX] $m" -ForegroundColor Red; exit 1 }

# --- 1) Git hygiene ---
try {
  $branch = (git rev-parse --abbrev-ref HEAD).Trim()
  Info "On branch: $branch"
  git fetch origin | Out-Null
} catch {
  Die "This doesn't look like a git repo (or git not installed)."
}

$status = git status -s
if($status){ Warn "Working tree has changes:`n$status" } else { Ok "Working tree is clean" }

# --- 2) Divergence from remote ---
try {
  $behind = (git rev-list --left-only  --count "HEAD...origin/$branch").Trim()
  $ahead  = (git rev-list --right-only --count "HEAD...origin/$branch").Trim()
  Info "Ahead: $ahead, Behind: $behind vs origin/$branch"
} catch {
  Warn "Could not compute ahead/behind vs origin/$branch"
}

# --- 3) Cross-project contamination scan ---
$hits = @()
foreach($t in $BadTerms){
  $r = git grep -n -I -- "$t" 2>$null
  if($LASTEXITCODE -eq 0 -and $r){
    $hits += ($r -split "`n" | Where-Object {$_})
  }
}
if($hits.Count -gt 0){
  Warn "Found possible cross-project strings in repo:"
  $hits | ForEach-Object { "  $_" }
}else{
  Ok "No obvious cross-project strings found"
}

# --- 4) List changed files vs remote for a quick skim ---
Info "Changed files vs origin/${branch}:"
$stat = git diff --stat "origin/$branch..HEAD"
if($stat){ $stat } else { Ok "No differences vs remote" }

# --- 5) Lightweight tests (if available) ---
$Py = $null
if (Test-Path $Venv) {
  try { $Py = (Resolve-Path $Venv).Path } catch { $Py = $null }
}
if($Py){
  # Detect if pytest.ini includes --cov (needs pytest-cov + plugin autoload)
  $needsCov = $false
  $iniPath = "pytest.ini"
  if (Test-Path $iniPath) {
    try {
      $iniRaw = Get-Content $iniPath -Raw
      if ($iniRaw -match "--cov") { $needsCov = $true }
    } catch {}
  }

  $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = "1"
  if(Test-Path "tests"){
    Info "Running pytest quick check…"
    try {
      if ($needsCov) {
        try {
          & $Py -m pip install -q pytest-cov
          Remove-Item Env:PYTEST_DISABLE_PLUGIN_AUTOLOAD -ErrorAction SilentlyContinue
        } catch { Write-Warning "Could not install pytest-cov: $($_.Exception.Message)" }
      }
      $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = $null
      & $Py -m pytest -q tests
      if($LASTEXITCODE -eq 0){ Ok "Pytest passed" } else { Warn "Pytest failed ($LASTEXITCODE)" }
    } catch {
      Warn "Pytest run threw: $($_.Exception.Message)"
    }
  }else{
    Warn "No 'tests' directory found — skipping pytest"
  }
}else{
  Warn "No virtualenv python at $Venv — skipping tests"
}

# --- 6) Ruff lint (exe or python -m fallback) ---
try{
  $ruffPath = & where.exe ruff 2>$null
  if ($ruffPath) {
    Info "Running ruff check…"
    & ruff check .
    if ($LASTEXITCODE -eq 0) { Ok "ruff clean" } else { Warn "ruff found issues" }
  } else {
    try {
      Info "Running ruff via python -m ruff…"
      if (-not $Py) { $Py = (Get-Command python -ErrorAction SilentlyContinue)?.Source }
      if (-not $Py) { throw "Python not found for ruff fallback." }
      & $Py -m pip install -q ruff
      & $Py -m ruff check .
      if ($LASTEXITCODE -eq 0) { Ok "ruff clean" } else { Warn "ruff found issues" }
    } catch {
      Warn "ruff not available — skipping lint"
    }
  }
} catch {
  Warn "ruff check skipped: $($_.Exception.Message)"
}

# --- Summary ---
if($hits.Count -eq 0 -and -not $status -and -not $stat -and $LASTEXITCODE -eq 0){
  Ok "Everything looks good ✅"
}else{
  Info "Review warnings above to confirm."
}
