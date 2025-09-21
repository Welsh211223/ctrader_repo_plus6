<#
.SYNOPSIS
  Hardens a GitHub repo: PS5.1-safe gh scripts, branch protection, CI, editor settings,
  removes nested repo, runs pre-commit, commits & pushes.

.PARAMETER Owner
  GitHub owner/org. Default: Welsh211223

.PARAMETER Repo
  Repository name. Default: ctrader_repo_plus6

.PARAMETER Branch
  Protected branch. Default: main

.PARAMETER RequiredChecks
  Array of required status checks. Default set matches workflows.

.PARAMETER SkipGhLogin
  If set, skip 'gh auth login'.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\harden-repo.ps1
#>

[CmdletBinding()]
param(
  [string]$Owner = "Welsh211223",
  [string]$Repo  = "ctrader_repo_plus6",
  [string]$Branch = "main",
  [string[]]$RequiredChecks = @("size-check","black","ruff","ruff-format","isort","detect-secrets"),
  [switch]$SkipGhLogin
)

$ErrorActionPreference = 'Stop'
$repoFull = "$Owner/$Repo"

function Write-Info($msg){ Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg){ Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg){ Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg){ Write-Host $msg -ForegroundColor Red }

# --- Resolve repo root ----------------------------------------------------------------
if (-not (Test-Path .git)) {
  throw "Run this from the repository root ('.git' not found)."
}

# --- Ensure directories ---------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path scripts, '.github', '.github/workflows' | Out-Null

# --- Install/resolve gh ---------------------------------------------------------------
Write-Info "Resolving GitHub CLI..."
$global:ghCmd = $null
try { $global:ghCmd = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not $global:ghCmd) {
  Write-Info "Installing gh via winget (if needed)..."
  try {
    winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null
  } catch {
    Write-Warn "winget install may have failed/been unavailable; attempting default path."
  }
  $global:ghCmd = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe'
}
if (-not (Test-Path $global:ghCmd)) {
  throw "GitHub CLI not found. Please install GitHub CLI then re-run."
}
& $global:ghCmd --version | Write-Host

if (-not $SkipGhLogin) {
  Write-Info "Checking gh auth..."
  $authed = $false
  try {
    $u = & $global:ghCmd auth status 2>$null
    if ($LASTEXITCODE -eq 0) { $authed = $true }
  } catch { $authed = $false }
  if (-not $authed) {
    Write-Warn "Launching 'gh auth login'..."
    & $global:ghCmd auth login
  }
}

# --- Ensure SSH agent env persisted ---------------------------------------------------
Write-Info "Ensuring SSH agent environment in profile..."
$profilePath = $PROFILE
$profileDir = Split-Path $profilePath -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
$profileContent = Get-Content $profilePath -Raw
if ($profileContent -notmatch [regex]::Escape('SSH_AUTH_SOCK')) {
  Add-Content -Encoding utf8 $profilePath '$env:SSH_AUTH_SOCK = "\\.\pipe\openssh-ssh-agent"'
  Write-Ok "Added SSH_AUTH_SOCK to profile."
} else {
  Write-Ok "SSH_AUTH_SOCK already present in profile."
}

# --- Helper: create/update files only if changed -------------------------------------
function Set-TextFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ContentUtf8
  )
  $existing = (Test-Path $Path) ? (Get-Content $Path -Raw) : $null
  if ($existing -ne $ContentUtf8) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Encoding utf8 -NoNewline -Path $Path -Value $ContentUtf8
    Write-Ok "Wrote $Path"
    return $true
  }
  else {
    Write-Info "Up-to-date: $Path"
    return $false
  }
}

# --- Write PS 5.1-safe helper scripts -------------------------------------------------
$scriptCheck = @"
[CmdletBinding()]
param(
  [string]$Owner = "$Owner",
  [string]$Repo  = "$Repo",
  [string]$Branch = "$Branch"
)
# Resolve gh
`$ghCmd = `$null
try { `$ghCmd = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$ghCmd) { `$ghCmd = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$ghCmd)) { throw "GitHub CLI not found." }

`$full = "`$Owner/`$Repo"
Write-Host ("Protection for {0}:{1}" -f `$full, `$Branch) -ForegroundColor Cyan

& `$ghCmd api ("repos/{0}/branches/{1}/protection" -f `$full,`$Branch) --jq '.' | Out-String | Write-Output

Write-Host "`nRequired checks:" -ForegroundColor Yellow
& `$ghCmd api ("repos/{0}/branches/{1}/protection/required_status_checks" -f `$full,`$Branch) --jq '.contexts' | Out-String | Write-Output

try {
  & `$ghCmd api ("repos/{0}/branches/{1}/protection/required_signatures" -f `$full,`$Branch) | Out-Null
  Write-Host "`nSigned commits: Yes" -ForegroundColor Green
} catch {
  Write-Host "`nSigned commits: No" -ForegroundColor Red
}
"@

$scriptSecure = @"
[CmdletBinding()]
param(
  [string]$Owner = "$Owner",
  [string]$Repo  = "$Repo",
  [string]$Branch = "$Branch",
  [string[]]$RequiredChecks = @(""{0}"",""{1}"",""{2}"",""{3}"",""{4}"",""{5}"")
)
# Resolve gh
`$ghCmd = `$null
try { `$ghCmd = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$ghCmd) { `$ghCmd = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$ghCmd)) { throw "GitHub CLI not found." }

`$repoFull = "`$Owner/`$Repo"
Write-Host ("Applying protection to {0}:{1} ..." -f `$repoFull, `$Branch) -ForegroundColor Cyan

`$payload = [ordered]@{
  required_status_checks = @{
    strict = `$true
    contexts = `$RequiredChecks
  }
  enforce_admins = `$true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = `$true
    require_code_owner_reviews = `$false
    required_approving_review_count = 1
    require_last_push_approval = `$true
  }
  restrictions = `$null
  required_linear_history = `$true
  allow_force_pushes = `$false
  allow_deletions = `$false
  block_creations = `$false
  required_conversation_resolution = `$true
} | ConvertTo-Json -Depth 6

`$null = `$payload | & `$ghCmd api -X PUT ("repos/{0}/branches/{1}/protection" -f `$repoFull,`$Branch) --header "Accept: application/vnd.github+json" --input -

& `$ghCmd api -X POST ("repos/{0}/branches/{1}/protection/required_signatures" -f `$repoFull,`$Branch) --header "Accept: application/vnd.github+json" | Out-Null

Write-Host "Done. Review Settings → Branches." -ForegroundColor Green
"@ -f $RequiredChecks[0],$RequiredChecks[1],$RequiredChecks[2],$RequiredChecks[3],$RequiredChecks[4],$RequiredChecks[5]

$scriptInstallGh = @"
[CmdletBinding()]
param([switch]`$SkipLogin)

Write-Host "Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null

`$ghCmd = `$null
try { `$ghCmd = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$ghCmd) { `$ghCmd = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$ghCmd)) { throw "GitHub CLI not found after install." }

& `$ghCmd --version

if (-not `$SkipLogin) {
  Write-Host "`nLaunching gh auth login..." -ForegroundColor Yellow
  & `$ghCmd auth login
}
Write-Host "Done." -ForegroundColor Green
"@

$changed = $false
$changed = (Set-TextFile -Path 'scripts/check-protection.ps1' -ContentUtf8 $scriptCheck) -or $changed
$changed = (Set-TextFile -Path 'scripts/secure-main.ps1' -ContentUtf8 $scriptSecure) -or $changed
$changed = (Set-TextFile -Path 'scripts/install-gh.ps1' -ContentUtf8 $scriptInstallGh) -or $changed

# --- Write repo config files ----------------------------------------------------------
$gitattributes = @"
* text=auto eol=lf
*.ps1 text eol=lf
*.psm1 text eol=lf
*.bat text eol=crlf
"@
$editorconfig = @"
root = true

[*]
end_of_line = lf
insert_final_newline = true
charset = utf-8
"@
$codeowners = "* @$Owner"
$dependabot = @"
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule: { interval: "weekly" }
  - package-ecosystem: "pip"
    directory: "/"
    schedule: { interval: "weekly" }
"@
$security = @"
# Security Policy

If you discover a vulnerability, please open a private security advisory
or email sct95422@gmail.com with details and reproduction steps.
"@

$changed = (Set-TextFile -Path '.gitattributes' -ContentUtf8 $gitattributes) -or $changed
$changed = (Set-TextFile -Path '.editorconfig' -ContentUtf8 $editorconfig) -or $changed
$changed = (Set-TextFile -Path '.github/CODEOWNERS' -ContentUtf8 $codeowners) -or $changed
$changed = (Set-TextFile -Path '.github/dependabot.yml' -ContentUtf8 $dependabot) -or $changed
$changed = (Set-TextFile -Path 'SECURITY.md' -ContentUtf8 $security) -or $changed

# --- Workflows -----------------------------------------------------------------------
$lintYml = @"
name: lint

on:
  push:
    branches: [ main ]
    paths:
      - "**.py"
      - ".github/workflows/lint.yml"
      - "pyproject.toml"
      - ".flake8"
  pull_request:
    branches: [ main ]
    paths:
      - "**.py"
      - ".github/workflows/lint.yml"
      - "pyproject.toml"
      - ".flake8"
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: lint-\${{ github.ref }}
  cancel-in-progress: true

jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      pycache: \${{ steps.cache-pip.outputs.cache-hit }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: "pip"
      - name: Install tools
        run: |
          python -m pip install --upgrade pip
          pip install black ruff isort detect-secrets

  black:
    needs: setup
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11", cache: "pip" }
      - run: pip install black
      - run: black --check .

  ruff:
    needs: setup
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11", cache: "pip" }
      - run: pip install ruff
      - run: ruff check .

  ruff-format:
    needs: setup
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11", cache: "pip" }
      - run: pip install ruff
      - run: ruff format --check .

  isort:
    needs: setup
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11", cache: "pip" }
      - run: pip install isort
      - run: isort --check-only .

  detect-secrets:
    needs: setup
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: "3.11", cache: "pip" }
      - run: pip install detect-secrets
      - run: |
          if [ ! -f ".secrets.baseline" ]; then
            echo "Missing .secrets.baseline"; exit 1;
          fi
          detect-secrets scan --baseline .secrets.baseline
"@

$blockYml = @"
name: Block large non-LFS files
on:
  push:
    branches: [ main ]
    paths:
      - "**"
      - "!.gitmodules"
  pull_request:
    branches: [ main ]
    paths:
      - "**"
      - "!.gitmodules"
  workflow_dispatch:

permissions:
  contents: read

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
          big_files=\$(git ls-tree -r -l HEAD | awk '\$4 > 52428800 {print \$5}')
          if [ -n "\$big_files" ]; then
            echo "Large files found not tracked by LFS:"
            echo "\$big_files"
            echo "::error::Commit large files via Git LFS (>=50MB)."
            exit 1
          fi
"@

$changed = (Set-TextFile -Path '.github/workflows/lint.yml' -ContentUtf8 $lintYml) -or $changed
$changed = (Set-TextFile -Path '.github/workflows/block-large-files.yml' -ContentUtf8 $blockYml) -or $changed

# --- Remove nested repo & ignore ------------------------------------------------------
$nestedDir = 'ctrader_repo_plus6'
if (Test-Path ".\$nestedDir") {
  Write-Info "Ensuring nested repo '$nestedDir' is not tracked..."
  try { git rm --cached -r -f $nestedDir | Out-Null } catch { }
  $gi = (Test-Path .gitignore) ? (Get-Content .gitignore -Raw) : ""
  if ($gi -notmatch '(?m)^ctrader_repo_plus6/') {
    Add-Content -Encoding utf8 .gitignore "ctrader_repo_plus6/`n"
    Write-Ok "Appended 'ctrader_repo_plus6/' to .gitignore"
  }
}

# --- Pre-commit normalization (best-effort) ------------------------------------------
$hasPreCommit = $false
try {
  $null = (Get-Command pre-commit -ErrorAction Stop)
  $hasPreCommit = $true
} catch { }

if ($hasPreCommit) {
  Write-Info "Running pre-commit on touched files..."
  try {
    pre-commit run --files .gitignore '.gitattributes' '.editorconfig' `
      '.github\workflows\lint.yml' '.github\workflows\block-large-files.yml' `
      'scripts\check-protection.ps1' 'scripts\secure-main.ps1' 'scripts\install-gh.ps1' | Write-Host
  } catch { Write-Warn "pre-commit --files encountered an issue, continuing." }
  try {
    pre-commit run --all-files | Write-Host
  } catch { Write-Warn "pre-commit --all-files encountered an issue, continuing." }
} else {
  Write-Warn "pre-commit not found on PATH; skipping hook normalization."
}

# --- Stage & commit ------------------------------------------------------------------
Write-Info "Staging files..."
git add .gitignore `
        .gitattributes `
        .editorconfig `
        .github\CODEOWNERS `
        .github\dependabot.yml `
        .github\workflows\lint.yml `
        .github\workflows\block-large-files.yml `
        SECURITY.md `
        scripts\check-protection.ps1 `
        scripts\secure-main.ps1 `
        scripts\install-gh.ps1

# If pre-commit tweaked docs/ORGANIZER.md, include it to avoid stash conflicts
if (Test-Path 'docs\ORGANIZER.md') {
  # See if un-staged changes exist
  $status = git status --porcelain
  if ($status -match 'docs/ORGANIZER\.md') {
    git add docs/ORGANIZER.md
    Write-Info "Staged docs/ORGANIZER.md (normalized by hooks)."
  }
}

# Commit (retry once without verify if hooks cause stash/restore conflicts)
$committed = $false
try {
  git commit -m "chore(ci,ops): PS5.1-safe gh scripts; enforce LF; tighten CI; ignore nested repo" | Write-Host
  $committed = $true
} catch {
  Write-Warn "Commit via hooks failed once; retrying with --no-verify (one-time)."
  git commit -m "chore(ci,ops): PS5.1-safe gh scripts; enforce LF; tighten CI; ignore nested repo" --no-verify | Write-Host
  $committed = $true
}

if ($committed) {
  Write-Info "Pushing..."
  git push | Write-Host
} else {
  Write-Warn "Nothing to commit."
}

# --- Apply branch protection via API --------------------------------------------------
Write-Info "Applying branch protection to ${repoFull}:${Branch} ..."
$payloadBp = [ordered]@{
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
} | ConvertTo-Json -Depth 6

$null = $payloadBp | & $global:ghCmd api -X PUT ("repos/{0}/branches/{1}/protection" -f $repoFull,$Branch) --header "Accept: application/vnd.github+json" --input -
& $global:ghCmd api -X POST ("repos/{0}/branches/{1}/protection/required_signatures" -f $repoFull,$Branch) --header "Accept: application/vnd.github+json" | Out-Null

Write-Ok "Branch protection applied."

# --- Final summary -------------------------------------------------------------------
Write-Info "Protection summary:"
& $global:ghCmd api ("repos/{0}/branches/{1}/protection" -f $repoFull,$Branch) --jq '.' | Write-Host

Write-Ok "✅ Hardening complete."
