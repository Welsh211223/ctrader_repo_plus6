# 1) Create the file content (note the opening @' and the closing '@ on its own line)
$script = @'
param(
  [string]$WorkflowPath = ".github/workflows/lint.yml",
  [string]$PythonVersion = "3.11",
  [switch]$NoPreCommit,
  [switch]$AddDependabot,
  [switch]$AddEditorConfig,
  [switch]$AddCodeQL,
  [switch]$ProtectMain,
  [switch]$RequireLintStatus
)

$ErrorActionPreference = "Stop"

function Fail($m){ Write-Error $m; throw $m }
function Info($m){ Write-Host "INFO  $m" }
function Ok($m){ Write-Host "OK    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "WARN  $m" -ForegroundColor Yellow }

function Write-Utf8NoBom([string]$Path,[string]$Content){
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function Normalize-LF([string]$Path){
  if (-not (Test-Path $Path)) { return }
  $raw = Get-Content $Path -Raw
  $lf  = $raw -replace "`r`n","`n" -replace "`r","`n"
  if (-not $lf.EndsWith("`n")) { $lf += "`n" }
  if ($lf -ne $raw) { Write-Utf8NoBom $Path $lf }
}
function Run-PreCommitIfPresent([string[]]$files){
  try { pre-commit --version | Out-Null } catch { return }
  if ($files -and $files.Count -gt 0) { pre-commit run --files $files } else { pre-commit run --all-files }
}
function Git-Stage-Commit-Push([string]$msg, [string[]]$paths){
  foreach($p in $paths){ if ($p -and (Test-Path $p)) { git add $p | Out-Null } }
  Run-PreCommitIfPresent -files $paths
  foreach($p in $paths){ if ($p -and (Test-Path $p)) { git add $p | Out-Null } }
  $staged = git diff --cached --name-only
  if (-not [string]::IsNullOrWhiteSpace($staged)) { git commit -m $msg | Out-Null; git push | Out-Null }
}

# repo/branch + gh
$top = git rev-parse --show-toplevel 2>$null
if (-not $top) { Fail "Run this inside your git repo root." }
Set-Location $top

$Branch = (git rev-parse --abbrev-ref HEAD).Trim()
$remote = (git remote get-url origin).Trim()
if ($remote -match 'github\.com[:/](.+?)/(.+?)(\.git)?$') {
  $Repo = "$($Matches[1])/$($Matches[2])"
} else {
  Fail "Could not parse GitHub repo from origin remote."
}

$GhOK = $true
try { gh --version | Out-Null } catch { $GhOK = $false }
if ($GhOK) { try { gh auth status 2>$null | Out-Null } catch { $GhOK = $false } }
if (-not $GhOK) { Warn "GitHub CLI not available or not authenticated. Will still write and commit; dispatch/protection steps will be skipped." }

# choose harden-runner ref: try pin to latest v2 SHA, else 'v2'
$HardenRef = "v2"
if ($GhOK) {
  try {
    $tags = gh api repos/step-security/harden-runner/tags | ConvertFrom-Json
    $v2 = $tags | Where-Object { $_.name -like 'v2*' } | Select-Object -First 1
    if ($v2 -and $v2.commit.sha) { $HardenRef = $v2.commit.sha }
  } catch { Warn "Could not fetch harden-runner tags; using v2." }
}

# ensure workflow folder + backup current
$wfDir = Split-Path $WorkflowPath -Parent
if (-not (Test-Path $wfDir)) { New-Item -ItemType Directory -Force -Path $wfDir | Out-Null }
if (Test-Path $WorkflowPath) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backup = ('{0}.bak.{1}' -f $WorkflowPath, $stamp)
  Copy-Item $WorkflowPath $backup -Force
  Warn ("Backed up {0} -> {1}" -f $WorkflowPath, $backup)
}

# render lint workflow (single-quoted here-string keeps ${{ }} literal)
$lintYaml = @'
name: lint
on:
  workflow_dispatch:
  push:
    branches: [ main, __BRANCH__ ]
    paths:
      - ".github/workflows/**"
      - "pre-commit-config.yaml"
      - "pyproject.toml"
      - "requirements*.txt"
      - "**/*.py"
  pull_request:
    branches: [ main ]

permissions:
  contents: read

concurrency:
  group: lint-${{ github.ref }}
  cancel-in-progress: true

defaults:
  run:
    shell: bash

env:
  PIP_DISABLE_PIP_VERSION_CHECK: "1"
  PYTHONUNBUFFERED: "1"

jobs:
  lint:
    timeout-minutes: 20
    runs-on: ubuntu-latest
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@__HARDEN_REF__
        with:
          egress-policy: block
          allowed-endpoints: >
            api.github.com:443
            github.com:443
            uploads.github.com:443
            raw.githubusercontent.com:443
            objects.githubusercontent.com:443
            pypi.org:443
            files.pythonhosted.org:443

      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "__PYVER__"
          cache: pip

      - name: Cache pre-commit
        uses: actions/cache@v4
        with:
          path: |
            ~/.cache/pre-commit
            .cache/pre-commit
          key: ${{ runner.os }}-precommit-${{ hashFiles('pre-commit-config.yaml') }}
          restore-keys: |
            ${{ runner.os }}-precommit-

      - name: Install deps
        run: |
          set -euo pipefail
          python -m pip install --upgrade pip
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          pip install pre-commit

      - name: Run pre-commit
        run: |
          set -euo pipefail
          pre-commit run --all-files
'@

$lintYaml = $lintYaml.Replace('__BRANCH__', $Branch).Replace('__PYVER__', $PythonVersion).Replace('__HARDEN_REF__', $HardenRef)
Write-Utf8NoBom $WorkflowPath $lintYaml
Normalize-LF $WorkflowPath
Ok "Wrote $WorkflowPath"

# .gitattributes (LF for YAML)
$gattr = ".gitattributes"
$gTxt = ""
if (Test-Path $gattr) { $gTxt = Get-Content $gattr -Raw }
if (($gTxt -notmatch '\*\.yml\s+text eol=lf') -or ($gTxt -notmatch '\*\.yaml\s+text eol=lf')) {
  $block = "*.yml  text eol=lf`n*.yaml text eol=lf`n"
  $newGA = ($gTxt.TrimEnd() + "`n" + $block)
  Write-Utf8NoBom $gattr $newGA
  Normalize-LF $gattr
  Ok "Updated .gitattributes (LF for YAML)"
}

# Minimal pre-commit
if (-not $NoPreCommit) {
  $pcfg = "pre-commit-config.yaml"
  if (-not (Test-Path $pcfg)) {
    $pre = @'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: mixed-line-ending
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.4
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
  - repo: https://github.com/psf/black
    rev: 24.8.0
    hooks:
      - id: black
  - repo: https://github.com/pycqa/isort
    rev: 5.13.2
    hooks:
      - id: isort
'@
    Write-Utf8NoBom $pcfg $pre
    Normalize-LF $pcfg
    Ok "Created minimal pre-commit-config.yaml"
  }
}

# Dependabot (optional)
if ($AddDependabot) {
  $dep = ".github/dependabot.yml"
  $depDir = Split-Path $dep -Parent
  if (-not (Test-Path $depDir)) { New-Item -ItemType Directory -Force -Path $depDir | Out-Null }
  if (-not (Test-Path $dep)) {
    $db = @'
version: 2
updates:
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
'@
    Write-Utf8NoBom $dep $db
    Normalize-LF $dep
    Ok "Added .github/dependabot.yml"
  }
}

# EditorConfig (optional)
if ($AddEditorConfig) {
  $ec = ".editorconfig"
  if (-not (Test-Path $ec)) {
    $ectxt = @'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
'@
    Write-Utf8NoBom $ec $ectxt
    Normalize-LF $ec
    Ok "Added .editorconfig"
  }
}

# CodeQL (optional)
if ($AddCodeQL) {
  $codeqlPath = ".github/workflows/codeql.yml"
  $codeqlDir = Split-Path $codeqlPath -Parent
  if (-not (Test-Path $codeqlDir)) { New-Item -ItemType Directory -Force -Path $codeqlDir | Out-Null }
  $cq = @'
name: "CodeQL"
on:
  workflow_dispatch:
  push:
    branches: [ main, __BRANCH__ ]
    paths:
      - "**/*.py"
      - ".github/workflows/codeql.yml"
  pull_request:
    branches: [ main ]
permissions:
  contents: read
  security-events: write
jobs:
  analyze:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v4
      - name: Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: python
      - name: Autobuild
        uses: github/codeql-action/autobuild@v3
      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v3
'@
  $cq = $cq.Replace('__BRANCH__', $Branch)
  Write-Utf8NoBom $codeqlPath $cq
  Normalize-LF $codeqlPath
  Ok "Wrote $codeqlPath"
}

# Commit/push everything we changed
$toCommit = @($WorkflowPath, ".gitattributes")
if (-not $NoPreCommit -and (Test-Path "pre-commit-config.yaml")) { $toCommit += "pre-commit-config.yaml" }
if ($AddDependabot -and (Test-Path ".github/dependabot.yml")) { $toCommit += ".github/dependabot.yml" }
if ($AddEditorConfig -and (Test-Path ".editorconfig")) { $toCommit += ".editorconfig" }
if ($AddCodeQL -and (Test-Path ".github/workflows/codeql.yml")) { $toCommit += ".github/workflows/codeql.yml" }
Git-Stage-Commit-Push -msg "ci: hardened lint + LF normalization (+ optional dependabot/editorconfig/codeql)" -paths $toCommit

# Dispatch + wait + summarize; scan logs; auto-fallback if setup fails
if ($GhOK) {
  gh workflow run $WorkflowPath --ref $Branch | Out-Null
  $run = gh run list --workflow $WorkflowPath --branch $Branch --limit 1 --json databaseId | ConvertFrom-Json
  $runId = $run[0].databaseId
  Info ("Waiting for run {0}..." -f $runId)
  do { Start-Sleep 3; $s = gh run view $runId --json status,conclusion | ConvertFrom-Json; "  - status: $($s.status)" } until ($s.status -eq 'completed')
  "Conclusion: $($s.conclusion)"

  $jobs = (gh api repos/$Repo/actions/runs/$runId/jobs | ConvertFrom-Json).jobs
  $setupFail = $false
  foreach ($j in $jobs) {
    $ji = gh api repos/$Repo/actions/jobs/$($j.id) | ConvertFrom-Json
    foreach ($st in $ji.steps) { "  - $($st.name): $($st.conclusion)" }
    if (($ji.steps | Where-Object { $_.name -eq 'Set up job' -and $_.conclusion -eq 'failure' })) { $setupFail = $true }
    gh api repos/$Repo/actions/jobs/$($j.id)/logs | Out-File -FilePath "job-$($j.id).log" -Encoding utf8
  }
  $hits = Get-ChildItem job-*.log | ForEach-Object { Select-String -Path $_.FullName -Pattern 'Allow these endpoints|Detected egress to' -Context 3 }
  if ($hits) {
    Write-Host "`n=== Potential egress allow-list notes ==="
    $hits | ForEach-Object { $_.ToString() }
    Write-Host "=== End ==="
  }

  if ($setupFail) {
    Warn "Setup failed (policy?). Removing Harden Runner and re-running."
    $y = Get-Content $WorkflowPath -Raw
    $y = [regex]::Replace($y, '(?ms)^\s*-\s*name:\s*Harden Runner.*?(?=^\s*-\s*(name|uses):|\Z)', '')
    Write-Utf8NoBom $WorkflowPath $y
    Normalize-LF $WorkflowPath
    Git-Stage-Commit-Push -msg "ci: temporarily remove harden-runner to satisfy org policy" -paths @($WorkflowPath)
    gh workflow run $WorkflowPath --ref $Branch | Out-Null
    $run = gh run list --workflow $WorkflowPath --branch $Branch --limit 1 --json databaseId | ConvertFrom-Json
    $runId = $run[0].databaseId
    do { Start-Sleep 3; $s = gh run view $runId --json status,conclusion | ConvertFrom-Json; "  - status: $($s.status)" } until ($s.status -eq 'completed')
    "Conclusion (fallback): $($s.conclusion)"
  }

  # Optional: protect main and require lint status
  if ($ProtectMain) {
    $contexts = @()
    if ($RequireLintStatus) { $contexts += "lint" }

    $reqChecks = $null
    if ($contexts.Count -gt 0) { $reqChecks = @{ strict = $true; contexts = $contexts } }

    $body = @{
      required_status_checks        = $reqChecks
      enforce_admins                = $true
      required_pull_request_reviews = @{ required_approving_review_count = 1 }
      restrictions                  = $null
      allow_force_pushes            = $false
      allow_deletions               = $false
    }

    try {
      ($body | ConvertTo-Json -Depth 5) | gh api -X PUT "repos/$Repo/branches/main/protection" -H "Accept: application/vnd.github+json" --input - | Out-Null
      if ($RequireLintStatus) { Ok "Protected 'main' and enabled strict status checks (including 'lint')." } else { Ok "Protected 'main' with defaults." }
    } catch {
      Warn "Failed to set branch protection (needs admin token with repo:admin)."
    }
  }
} else {
  Warn "Skipping dispatch/log collection/protection—GitHub CLI not available."
}

Ok "Done."
