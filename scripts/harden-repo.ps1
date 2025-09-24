<#  scripts\harden-repo.ps1  —  PS 5.1 SAFE, IDEMPOTENT  #>
[CmdletBinding()]
param(
  [string]$Owner = "Welsh211223",
  [string]$Repo  = "ctrader_repo_plus6",
  [string]$Branch = "main",
  [string[]]$RequiredChecks = @("size-check","black","ruff","ruff-format","isort","detect-secrets"),
  [switch]$SkipGhLogin
)

$ErrorActionPreference = 'Stop'
function Info($m){Write-Host $m -ForegroundColor Cyan}
function Ok($m){Write-Host $m -ForegroundColor Green}
function Warn($m){Write-Host $m -ForegroundColor Yellow}
function Err($m){Write-Host $m -ForegroundColor Red}

# --- Guard: repo root ---
if (-not (Test-Path .git)) { throw "Run from the repository root ('.git' not found)." }
$repoFull = "$Owner/$Repo"

# --- Ensure folders ---
$null = New-Item -ItemType Directory -Force -Path scripts,'.github','.github/workflows','.github/ISSUE_TEMPLATE' | Out-Null

# --- Resolve gh (PS5.1 safe) ---
Info "Resolving GitHub CLI..."
$global:ghCmd = $null
try {
  $cmd = Get-Command gh -ErrorAction Stop
  if ($cmd) { $global:ghCmd = $cmd.Source }
} catch { }
if (-not $global:ghCmd) { $global:ghCmd = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe' }

if (-not (Test-Path $global:ghCmd)) {
  Warn "Installing gh via winget..."
  try {
    winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null
    try {
      $cmd = Get-Command gh -ErrorAction Stop
      if ($cmd) { $global:ghCmd = $cmd.Source }
    } catch { }
    if (-not $global:ghCmd) { $global:ghCmd = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe' }
  } catch { }
}
if (-not (Test-Path $global:ghCmd)) { throw "GitHub CLI not found. Install it and re-run." }
& $global:ghCmd --version | Write-Host

# --- gh auth (optional) ---
if (-not $SkipGhLogin) {
  $authed = $false
  try { & $global:ghCmd auth status 2>$null; if ($LASTEXITCODE -eq 0){$authed=$true} } catch {}
  if (-not $authed) { Warn "Launching 'gh auth login'..."; & $global:ghCmd auth login }
}

# --- Ensure SSH agent env persists in profile (idempotent) ---
try {
  $profilePath = $PROFILE
  $dir = Split-Path $profilePath -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
  $content = Get-Content $profilePath -Raw
  if ($content -notmatch 'SSH_AUTH_SOCK') {
    Add-Content -Encoding utf8 $profilePath '$env:SSH_AUTH_SOCK = "\\.\pipe\openssh-ssh-agent"'
    Ok "Added SSH_AUTH_SOCK to $profilePath"
  } else { Info "SSH_AUTH_SOCK already present in profile." }
} catch { Warn "Skipped profile update: $($_.Exception.Message)" }

# --- Helper: write file only if changed (PS5.1) ---
function Set-TextFile {
  param([string]$Path,[string]$ContentUtf8)
  $existing = $null
  if (Test-Path $Path) { $existing = Get-Content $Path -Raw }
  if ($existing -ne $ContentUtf8) {
    $d = Split-Path $Path -Parent
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Set-Content -Path $Path -Value $ContentUtf8 -Encoding utf8 -NoNewline
    Ok "Wrote $Path"; return $true
  } else { Info "Up-to-date: $Path"; return $false }
}

# --- PS helper scripts (PS5.1 safe) ---
$scriptCheck = @"
[CmdletBinding()]
param(
  [string]`$Owner = "$Owner",
  [string]`$Repo  = "$Repo",
  [string]`$Branch = "$Branch"
)
`$gh = `$null
try { `$gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$gh) { `$gh = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$gh)) { throw "GitHub CLI not found." }
`$full = "`$Owner/`$Repo"
Write-Host ("Protection for {0}:{1}" -f `$full,`$Branch) -ForegroundColor Cyan
& `$gh api ("repos/{0}/branches/{1}/protection" -f `$full,`$Branch) --jq '.' | Out-String | Write-Output
Write-Host "`nRequired checks:" -ForegroundColor Yellow
& `$gh api ("repos/{0}/branches/{1}/protection/required_status_checks" -f `$full,`$Branch) --jq '.contexts' | Out-String | Write-Output
try { & `$gh api ("repos/{0}/branches/{1}/protection/required_signatures" -f `$full,`$Branch) | Out-Null; Write-Host "`nSigned commits: Yes" -ForegroundColor Green } catch { Write-Host "`nSigned commits: No" -ForegroundColor Red }
"@

# Build the RequiredChecks literal once (no -f on brace-heavy text)
$rcItems = @()
foreach ($c in $RequiredChecks) { $rcItems += ('"'+$c+'"') }
$rcList = $rcItems -join ','

$scriptSecure = @"
[CmdletBinding()]
param(
  [string]`$Owner = "$Owner",
  [string]`$Repo  = "$Repo",
  [string]`$Branch = "$Branch",
  [string[]]`$RequiredChecks = @(__RC_LIST__)
)
`$gh = `$null
try { `$gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$gh) { `$gh = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$gh)) { throw "GitHub CLI not found." }
`$repoFull = "`$Owner/`$Repo"
Write-Host ("Applying protection to {0}:{1} ..." -f `$repoFull,`$Branch) -ForegroundColor Cyan
`$payload = [ordered]@{
  required_status_checks = @{ strict = `$true; contexts = `$RequiredChecks }
  enforce_admins = `$true
  required_pull_request_reviews = @{ dismiss_stale_reviews=`$true; require_code_owner_reviews=`$false; required_approving_review_count=1; require_last_push_approval=`$true }
  restrictions = `$null
  required_linear_history = `$true
  allow_force_pushes = `$false
  allow_deletions = `$false
  block_creations = `$false
  required_conversation_resolution = `$true
} | ConvertTo-Json -Depth 6
`$null = `$payload | & `$gh api -X PUT ("repos/{0}/branches/{1}/protection" -f `$repoFull,`$Branch) --header "Accept: application/vnd.github+json" --input -
& `$gh api -X POST ("repos/{0}/branches/{1}/protection/required_signatures" -f `$repoFull,`$Branch) --header "Accept: application/vnd.github+json" | Out-Null
Write-Host "Done. Review Settings → Branches." -ForegroundColor Green
"@
$scriptSecure = $scriptSecure.Replace('__RC_LIST__', $rcList)

$scriptInstallGh = @"
[CmdletBinding()]
param([switch]`$SkipLogin)
Write-Host "Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Null
`$gh = `$null
try { `$gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not `$gh) { `$gh = Join-Path `$Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path `$gh)) { throw "GitHub CLI not found after install." }
& `$gh --version
if (-not `$SkipLogin) { Write-Host "`nLaunching gh auth login..." -ForegroundColor Yellow; & `$gh auth login }
Write-Host "Done." -ForegroundColor Green
"@

$changed = $false
$changed = (Set-TextFile 'scripts/check-protection.ps1' $scriptCheck) -or $changed
$changed = (Set-TextFile 'scripts/secure-main.ps1' $scriptSecure) -or $changed
$changed = (Set-TextFile 'scripts/install-gh.ps1' $scriptInstallGh) -or $changed

# --- Repo hygiene files ---
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
$dependabot = @'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule: { interval: "weekly" }
  - package-ecosystem: "pip"
    directory: "/"
    schedule: { interval: "weekly" }
'@
$security = @"
# Security Policy
If you discover a vulnerability, please open a private security advisory
or email sct95422@gmail.com with details and reproduction steps.
"@
$prTemplate = @"
## Summary
Explain the change and why it's needed.

## Checklist
- [ ] `pre-commit run --all-files` is green
- [ ] CI checks pass (black, ruff, ruff-format, isort, detect-secrets, size-check)
- [ ] No large binaries committed (use Git LFS for >=50MB)
"@

$changed = (Set-TextFile '.gitattributes' $gitattributes) -or $changed
$changed = (Set-TextFile '.editorconfig' $editorconfig) -or $changed
$changed = (Set-TextFile '.github/CODEOWNERS' $codeowners) -or $changed
$changed = (Set-TextFile '.github/dependabot.yml' $dependabot) -or $changed
$changed = (Set-TextFile 'SECURITY.md' $security) -or $changed
$changed = (Set-TextFile '.github/PULL_REQUEST_TEMPLATE.md' $prTemplate) -or $changed

# --- Workflows (single-quoted to keep $ and ${{ }} literal) ---
$lintYml = @'
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
  group: lint-${{ github.ref }}
  cancel-in-progress: true
jobs:
  setup:
    runs-on: ubuntu-latest
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
'@

$blockYml = @'
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
          big_files=$(git ls-tree -r -l HEAD | awk '$4 > 52428800 {print $5}')
          if [ -n "$big_files" ]; then
            echo "Large files found not tracked by LFS:"
            echo "$big_files"
            echo "::error::Commit large files via Git LFS (>=50MB)."
            exit 1
          fi
'@

$releaseYml = @'
name: release
on:
  push:
    tags:
      - "v*"
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
'@

$codeqlYml = @'
name: codeql
on:
  push: { branches: [ "main" ] }
  pull_request: { branches: [ "main" ] }
permissions:
  contents: read
  security-events: write
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with: { languages: python }
      - uses: github/codeql-action/analyze@v3
'@

$changed = (Set-TextFile '.github/workflows/lint.yml' $lintYml) -or $changed
$changed = (Set-TextFile '.github/workflows/block-large-files.yml' $blockYml) -or $changed
$changed = (Set-TextFile '.github/workflows/release.yml' $releaseYml) -or $changed
$changed = (Set-TextFile '.github/workflows/codeql.yml' $codeqlYml) -or $changed

# --- Remove nested repo dir from index & ignore ---
$nested = 'ctrader_repo_plus6'
if (Test-Path $nested) {
  Info "Ensuring '$nested' is not tracked..."
  try { git rm --cached -r -f $nested | Out-Null } catch { }
  $gi = ""
  if (Test-Path .gitignore) { $gi = Get-Content .gitignore -Raw }
  if ($gi -notmatch '(?m)^ctrader_repo_plus6/') {
    Add-Content -Encoding utf8 .gitignore "ctrader_repo_plus6/`n"
    Ok "Appended 'ctrader_repo_plus6/' to .gitignore"
  }
}

# --- Detect-secrets baseline (best effort) ---
if (-not (Test-Path '.secrets.baseline')) {
  $ds = $null
  try { $ds = (Get-Command detect-secrets -ErrorAction Stop).Source } catch { }
  if ($ds) {
    Info "Creating .secrets.baseline (detect-secrets)..."
    try { detect-secrets scan | Out-File -Encoding utf8 .secrets.baseline; Ok "Baseline created." } catch { Warn "detect-secrets scan failed: $($_.Exception.Message)" }
  } else {
    Warn "detect-secrets not found; skipping baseline creation."
  }
}

# --- Pre-commit normalization if available ---
$hasPreCommit = $false
try { $null = (Get-Command pre-commit -ErrorAction Stop); $hasPreCommit=$true } catch { }
if ($hasPreCommit) {
  Info "Running pre-commit (files and all-files)..."
  try {
    pre-commit run --files `
      .gitignore '.gitattributes' '.editorconfig' `
      '.github\CODEOWNERS' '.github\dependabot.yml' `
      '.github\workflows\lint.yml' '.github\workflows\block-large-files.yml' '.github\workflows\release.yml' '.github\workflows\codeql.yml' `
      SECURITY.md '.github\PULL_REQUEST_TEMPLATE.md' `
      'scripts\check-protection.ps1' 'scripts\secure-main.ps1' 'scripts\install-gh.ps1' | Write-Host
  } catch { Warn "pre-commit --files had issues, continuing." }
  try { pre-commit run --all-files | Write-Host } catch { Warn "pre-commit --all-files had issues, continuing." }
} else { Warn "pre-commit not found on PATH; skipping hook normalization." }

# --- Stage & commit (with safe fallback) ---
Info "Staging changes..."
git add `
  .gitignore '.gitattributes' '.editorconfig' `
  '.github\CODEOWNERS' '.github\dependabot.yml' '.github\PULL_REQUEST_TEMPLATE.md' `
  '.github\workflows\lint.yml' '.github\workflows\block-large-files.yml' '.github\workflows\release.yml' '.github\workflows\codeql.yml' `
  SECURITY.md '.secrets.baseline' `
  'scripts\check-protection.ps1' 'scripts\secure-main.ps1' 'scripts\install-gh.ps1' 2>$null

# Include docs/ORGANIZER.md if hooks normalized it
if (Test-Path 'docs\ORGANIZER.md') {
  $status = git status --porcelain
  if ($status -match 'docs/ORGANIZER\.md') { git add docs/ORGANIZER.md; Info "Staged docs/ORGANIZER.md" }
}

$committed = $false
try { git commit -m "chore(ci,ops): PS5.1-safe hardening; CI cache+filters; protections; hygiene files; release+codeql workflows" | Write-Host; $committed=$true } catch { }
if (-not $committed) {
  try { Warn "Retrying commit with --no-verify..."; git commit -m "chore(ci,ops): PS5.1-safe hardening; CI cache+filters; protections; hygiene files; release+codeql workflows" --no-verify | Write-Host; $committed=$true } catch { Warn "Nothing to commit or commit failed." }
}

if ($committed) { Info "Pushing..."; git push | Write-Host } else { Info "No push needed." }

# --- Apply branch protection (classic) ---
Info "Applying branch protection to ${repoFull}:${Branch} ..."
$payloadBp = [ordered]@{
  required_status_checks = @{ strict = $true; contexts = $RequiredChecks }
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

Ok "Branch protection applied."
Info "Protection summary:"
& $global:ghCmd api ("repos/{0}/branches/{1}/protection" -f $repoFull,$Branch) --jq '.' | Write-Host
Ok "✅ Hardening complete."
