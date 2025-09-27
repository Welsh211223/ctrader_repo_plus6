<#
.SYNOPSIS
  Hardens CI for this repo and (optionally) triggers a clean run for the current branch.

.DESCRIPTION
  - Enforces LF endings and final newline for common text files.
  - Writes .editorconfig + .gitattributes (idempotent).
  - Creates/updates a robust tests workflow with dispatch, scoping, concurrency, pip cache,
    and "no tests collected" treated as success.
  - Optionally opens a PR from current branch -> main (helps manual dispatch from GH CLI).
  - Optionally cancels queued/in-progress runs for this branch, triggers exactly one run,
    and tails the first job’s logs.

.PARAMETER WorkflowFile
  Path to the workflow file. Default: .github/workflows/tests.yml

.PARAMETER CreatePR
  Create/ensure an open PR to main (if not on main).

.PARAMETER TriggerOnce
  Cancel queued/in-progress runs for this branch, then trigger exactly one run
  (dispatch if possible; falls back to pushing an empty commit if needed).

.PARAMETER Watch
  After triggering, watch newest run and print the first job's logs.

.EXAMPLE
  pwsh tools/harden-ci.ps1 -CreatePR -TriggerOnce -Watch

.NOTES
  Requires: git. Optionally uses: gh (GitHub CLI), pre-commit (if present).
#>

param(
  [string]$WorkflowFile = ".github/workflows/tests.yml",
  [switch]$CreatePR,
  [switch]$TriggerOnce,
  [switch]$Watch
)

# ----------------------------- Utilities --------------------------------------

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found on PATH. Please install it and retry."
  }
}

function Ensure-Dir([string]$Path) {
  $dir = Split-Path -LiteralPath $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
}

# Write content as UTF-8 (no BOM), normalize to LF, and ensure exactly one trailing newline
function Write-FileUtf8LF([string]$Path, [string]$Content) {
  Ensure-Dir $Path
  $lf = $Content -replace "`r?`n", "`n"
  if (-not $lf.EndsWith("`n")) { $lf += "`n" } # <-- Make end-of-file-fixer happy
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

# Only write if content actually changes (returns $true if changed)
function Set-FileUtf8LFIfChanged([string]$Path, [string]$Content) {
  $new = ($Content -replace "`r?`n", "`n")
  if (-not $new.EndsWith("`n")) { $new += "`n" }
  $current = if (Test-Path -LiteralPath $Path) {
    [System.IO.File]::ReadAllText($Path)
  } else { $null }
  if ($current -ne $new) {
    Write-FileUtf8LF -Path $Path -Content $new
    return $true
  }
  return $false
}

function Git-StageCommitPush([string]$Message) {
  git add -A | Out-Null
  git diff --cached --quiet
  $hasChanges = ($LASTEXITCODE -ne 0)
  if ($hasChanges) {
    if (Get-Command pre-commit -ErrorAction SilentlyContinue) {
      pre-commit run --all-files
      git add -A | Out-Null
    }
    git commit -m $Message | Out-Null
    git push
  } else {
    Write-Host "No staged changes to commit."
  }
}

# --------------------------- Preconditions ------------------------------------

Require-Tool git
$HasGH = [bool](Get-Command gh -ErrorAction SilentlyContinue)

if ($HasGH) {
  try { gh auth status 2>$null | Out-Null } catch { Write-Warning "gh not authenticated; some steps may fail." }
}

# Normalize line endings repo-wide on commit (keep LF in Git)
git config core.autocrlf input | Out-Null

# --------------------- Editor & Git normalization files -----------------------

$gitattributes = @'
# Normalize text to LF in repo; checkout uses platform defaults unless overridden.
* text=auto eol=lf

# GitHub Actions & YAML should always be LF
*.yml  text eol=lf
*.yaml text eol=lf

# Keep Windows batch files CRLF if needed
*.bat eol=crlf
*.cmd eol=crlf
'@

$editorconfig = @'
root = true

[*]
end_of_line = lf
insert_final_newline = true
charset = utf-8
trim_trailing_whitespace = true

[*.{bat,cmd}]
end_of_line = crlf
'@

$gitignoreAdditions = @'
# Local secrets & env
.env
.env.*
!.env.example

# Local configs
config/*.local.yaml

# Python
__pycache__/
*.pyc
*.pyo
*.pyd
.venv/
*.log
'@

$changed = $false
$changed = (Set-FileUtf8LFIfChanged ".gitattributes" $gitattributes) -or $changed
$changed = (Set-FileUtf8LFIfChanged ".editorconfig" $editorconfig) -or $changed

# Append to .gitignore (idempotent append)
$gitignorePath = ".gitignore"
if (Test-Path -LiteralPath $gitignorePath) {
  $giCurrent = [IO.File]::ReadAllText($gitignorePath)
  if ($gitignoreAdditions -notin $giCurrent) {
    Write-FileUtf8LF $gitignorePath ($giCurrent.TrimEnd() + "`n`n" + $gitignoreAdditions)
    $changed = $true
  }
} else {
  Write-FileUtf8LF $gitignorePath $gitignoreAdditions
  $changed = $true
}

# ---------------------------- Workflow file -----------------------------------

# Use single-quoted here-string so ${{ }} is not expanded by PowerShell
$workflow = @'
name: tests

on:
  workflow_dispatch:
  push:
    branches: [ main, egress-allowlist-lock ]
  pull_request:
    branches: [ main ]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pytest:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: pip
      - name: Install deps
        run: |
          python -m pip install -U pip
          if [ -f requirements-dev.txt ]; then pip install -r requirements-dev.txt; fi
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          pip install pytest
      - name: Run tests (skip if none)
        run: |
          pytest -q || { c=$?; if [ $c -eq 5 ]; then echo "No tests collected; skipping."; exit 0; else exit $c; fi; }
'@

$changed = (Set-FileUtf8LFIfChanged $WorkflowFile $workflow) -or $changed

# ------------------------- Optional scaffolding -------------------------------

# Safe env example for users (no secrets)
$envExample = @'
# Example environment file (copy to .env and fill in real values)
MODE=paper                # paper | live
TRADER_ENABLE=false       # global kill switch
EXCHANGE=your_exchange    # e.g., binance, bybit, kraken
API_KEY=
API_SECRET=
BASE_URL=                 # e.g., testnet URL for paper
MAX_RISK_PCT=1
'@
$changed = (Set-FileUtf8LFIfChanged ".env.example" $envExample) -or $changed

# Minimal config skeletons (paper/live)
$configPaper = @'
mode: paper
risk:
  max_risk_pct: 1
order:
  max_position_value_usd: 50
  slippage_bps: 5
  fee_bps: 10
exchange:
  name: "${EXCHANGE}"
  base_url: "${BASE_URL}"   # testnet URL
'@
$configLive = @'
mode: live
risk:
  max_risk_pct: 0.5
order:
  max_position_value_usd: 25
  slippage_bps: 10
  fee_bps: 12
exchange:
  name: "${EXCHANGE}"
  base_url: "${BASE_URL}"   # live URL
'@
Ensure-Dir "config"
$changed = (Set-FileUtf8LFIfChanged "config/config.paper.yaml" $configPaper) -or $changed
$changed = (Set-FileUtf8LFIfChanged "config/config.live.yaml"  $configLive)  -or $changed

# Optional smoke test (only create if tests/ is missing)
if (-not (Test-Path "tests")) {
  $smoke = @'
def test_smoke():
    assert True
'@
  Ensure-Dir "tests"
  $changed = (Set-FileUtf8LFIfChanged "tests/test_smoke.py" $smoke) -or $changed
}

# -------------------------- Commit & push -------------------------------------

if ($changed) {
  Git-StageCommitPush "ci: normalize line-endings; add .editorconfig; harden tests workflow"
} else {
  Write-Host "No changes required; repo already hardened."
}

# ---------------------- Optional PR creation ----------------------------------

$currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($CreatePR -and $HasGH -and $currentBranch -ne "main") {
  Write-Host "Ensuring PR $currentBranch -> main ..."
  $existing = gh pr list --base main --head $currentBranch --state open --json number -q '.[0].number' 2>$null
  if (-not $existing) {
    gh pr create --base main --head $currentBranch `
      --title "ci: add workflow_dispatch + LF normalization" `
      --body "Adds a stable pytest workflow with dispatch, scoping, concurrency, caching, and LF normalization." | Out-Null
    Write-Host "PR created."
  } else {
    Write-Host "PR already open: #$existing"
  }
  # Non-fatal: try to enable auto-merge (if branch protections allow)
  try { gh pr merge --auto --squash 2>$null | Out-Null } catch {}
} elseif ($CreatePR -and -not $HasGH) {
  Write-Warning "gh CLI not available; skipping PR creation."
}

# ----------------- Optional: trigger once & watch logs ------------------------

if ($TriggerOnce) {
  if (-not $HasGH) {
    Write-Warning "gh CLI not available; skipping trigger/watch."
  } else {
    $wfName = Split-Path $WorkflowFile -Leaf
    Write-Host "Canceling queued/in-progress runs for '$wfName' on '$currentBranch'..."
    $queued = gh run list --workflow $wfName --branch $currentBranch --status queued       --json databaseId -q '.[].databaseId' 2>$null
    $inprog = gh run list --workflow $wfName --branch $currentBranch --status in_progress  --json databaseId -q '.[].databaseId' 2>$null
    @($queued + $inprog) | ForEach-Object { if ($_ -and ($_ -match '^\d+$')) { gh run cancel $_ | Out-Null } }

    Write-Host "Triggering run for '$wfName' on '$currentBranch'..."
    gh workflow run $WorkflowFile --ref $currentBranch 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "Dispatch not available from default-branch workflow yet; using push trigger."
      git commit --allow-empty -m "ci: trigger tests once on $currentBranch" | Out-Null
      git push | Out-Null
    }

    if ($Watch) {
      Start-Sleep -Seconds 2
      $rid = gh run list --workflow $wfName --branch $currentBranch --limit 1 --json databaseId -q '.[0].databaseId'
      if ($rid) {
        gh run watch $rid --exit-status
        $jid = gh run view $rid --json jobs -q '.jobs[0].id'
        if ($jid) { gh run view --job $jid --log } else { gh run view $rid --log }
      } else {
        Write-Warning "No run found to watch."
      }
    }
  }
}

Write-Host "Done."
