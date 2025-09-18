# scripts\repo-harden.ps1
[CmdletBinding()]
param(
  [string]$Owner = "Welsh211223",
  [string]$Repo  = "ctrader_repo_plus6",
  [string]$Branch = "main",
  # Choose which checks you want to protect on main (must match job names below)
  [string[]]$RequiredChecks = @("black","ruff","ruff-format","isort","detect-secrets","size-check"),
  [switch]$SkipGhLogin
)

function Write-Section($t){ Write-Host "`n== $t ==" -ForegroundColor Cyan }

# --- 0) Ensure we're in a git repo -------------------------------------------------------
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run this from the repository root." }

# --- 1) Ensure gh is available (install if needed) --------------------------------------
Write-Section "GitHub CLI"
$ghPath = $null
try { $ghPath = (where.exe gh 2>$null | Select-Object -First 1) } catch {}
if (-not $ghPath) {
  $candidate = Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"
  if (Test-Path $candidate) { $ghPath = $candidate }
}
if (-not $ghPath) {
  Write-Host "Installing GitHub CLI via winget..." -ForegroundColor Yellow
  winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null
  $ghPath = Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"
}
if (-not (Test-Path $ghPath)) { throw "gh.exe not found after install. Re-open PowerShell or verify install." }
# Add to this session PATH so 'gh' works
$env:PATH = "$(Split-Path $ghPath -Parent);$env:PATH"

if (-not $SkipGhLogin) {
  & $ghPath auth status 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Launching 'gh auth login'..." -ForegroundColor Yellow
    & $ghPath auth login
  }
}

# --- 2) Write CI workflows (single-quoted here-strings) ---------------------------------
Write-Section "Writing CI workflows"
New-Item -ItemType Directory -Force ".github/workflows" | Out-Null

# Lint jobs (names must match $RequiredChecks items)
@'
name: lint
on: [push, pull_request]
jobs:
  black:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install black
      - run: black --check .
  ruff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install ruff
      - run: ruff check .
  ruff-format:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install ruff
      - run: ruff format --check .
  isort:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install isort
      - run: isort --check-only .
  detect-secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install detect-secrets
      - run: |
          if [ ! -f ".secrets.baseline" ]; then echo "Missing .secrets.baseline"; exit 1; fi
          detect-secrets scan --baseline .secrets.baseline
'@ | Set-Content -Encoding ascii .github\workflows\lint.yml

# Non-LFS >50MB blocker
@'
name: Block large non-LFS files
on:
  pull_request:
  push:
    branches: [ main ]
jobs:
  size-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Fail if any file > 50MB not in LFS
        shell: bash
        run: |
          big_files=$(git ls-tree -r -l HEAD | awk '$4 > 52428800 {print $5}')
          if [ -n "$big_files" ]; then
            echo "Large files found in repo (not LFS tracked):"
            echo "$big_files"
            echo "::error::Commit large files via Git LFS (>=50MB)."
            exit 1
          fi
'@ | Set-Content -Encoding ascii .github\workflows\block-large-files.yml

# --- 3) Stage & commit with pre-commit-friendly flow ------------------------------------
Write-Section "Staging & committing CI files"
git add .github\workflows\lint.yml, .github\workflows\block-large-files.yml
# run hooks first to avoid mixed-line-ending bouncing
pre-commit run --all-files | Out-Null
git commit -m "ci: add lint + block-large-files workflows" 2>$null
if ($LASTEXITCODE -ne 0) {
  # hooks may have modified files; add again and retry
  git add -A
  git commit -m "ci: add lint + block-large-files workflows (post-hook fixes)" | Out-Null
}
git push

# --- 4) Apply Classic branch protection & required checks --------------------------------
Write-Section "Applying branch protection (Classic)"
$repoFull = "$Owner/$Repo"
$payload = [ordered]@{
  required_status_checks = @{
    strict = $true
    contexts = $RequiredChecks
  }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $false
    required_approving_review_count = 1
    require_last_push_approval = $true
  }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
}
$tmp = New-TemporaryFile
$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding ascii

Write-Host ("Applying protection to {0}:{1} ..." -f $repoFull,$Branch) -ForegroundColor Yellow
& $ghPath api -X PUT "repos/$repoFull/branches/$Branch/protection" `
  --header "Accept: application/vnd.github+json" `
  --input $tmp | Out-Null
Remove-Item $tmp -Force

Write-Host "Requiring signed commits..." -ForegroundColor Yellow
try {
  & $ghPath api -X POST "repos/$repoFull/branches/$Branch/protection/required_signatures" `
    --header "Accept: application/vnd.github+json" | Out-Null
} catch {
  Write-Warning "Could not enable signed-commit requirement (may already be enabled or org policy blocks it)."
}

# --- 5) Show protection summary ----------------------------------------------------------
Write-Section "Protection summary"
& $ghPath api "repos/$repoFull/branches/$Branch/protection" --jq '.'
Write-Host "`nRequired checks:" -ForegroundColor Yellow
& $ghPath api "repos/$repoFull/branches/$Branch/protection/required_status_checks" --jq '.contexts'
try {
  & $ghPath api "repos/$repoFull/branches/$Branch/protection/required_signatures" | Out-Null
  Write-Host "`nSigned commits: Yes" -ForegroundColor Green
} catch {
  Write-Host "`nSigned commits: No" -ForegroundColor Red
}

Write-Host "`n✅ Hardening complete." -ForegroundColor Green
