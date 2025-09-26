param(
  [string]$WorkflowPath = ".github/workflows/lint.yml",
  [string]$PythonVersion = "3.11",
  [switch]$AddDependabot,
  [switch]$AddEditorConfig,
  [switch]$AddCodeQL,
  [switch]$RunWorkflow
)

$ErrorActionPreference = "Stop"

# 0) Ensure we're in a git repo and find branch/repo slug
try { $top = git rev-parse --show-toplevel 2>$null } catch { throw "Run this inside your git repo root." }
if (-not $top) { throw "Run this inside your git repo root." }
Set-Location $top

$Branch = (git rev-parse --abbrev-ref HEAD).Trim()
$remote = (git remote get-url origin).Trim()
if ($remote -match 'github\.com[:/](.+?)/(.+?)(\.git)?$') {
  $Repo = "$($Matches[1])/$($Matches[2])"
} else {
  throw "Could not parse GitHub repo from origin remote."
}

# 1) Create workflow folder
$wfDir = Split-Path $WorkflowPath -Parent
if (-not (Test-Path $wfDir)) { New-Item -ItemType Directory -Force -Path $wfDir | Out-Null }

# 2) Write lint workflow (single-quoted here-string preserves ${{ }})
$lintYaml = @'
name: lint
on:
  workflow_dispatch:
  push:
    branches: [ main ]
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
$lintYaml = $lintYaml.Replace('__PYVER__', $PythonVersion)
$lintYaml | Set-Content -Path $WorkflowPath -Encoding utf8

# Normalize to LF endings for YAML (safe no-op on Linux; fixes Windows CRLF)
$raw = Get-Content $WorkflowPath -Raw
$lf  = $raw -replace "`r`n","`n" -replace "`r","`n"
if ($lf -ne $raw) { $lf | Set-Content -Path $WorkflowPath -Encoding utf8 }

# 3) .gitattributes to enforce LF for YAML
$ga = ".gitattributes"
$gaBlock = "*.yml  text eol=lf`n*.yaml text eol=lf`n"
if (Test-Path $ga) {
  $cur = Get-Content $ga -Raw
  if ($cur -notmatch '\*\.yml\s+text eol=lf' -or $cur -notmatch '\*\.yaml\s+text eol=lf') {
    ($cur.TrimEnd() + "`n" + $gaBlock) | Set-Content -Path $ga -Encoding utf8
  }
} else {
  $gaBlock | Set-Content -Path $ga -Encoding utf8
}

# 4) Minimal pre-commit config
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
  $pre | Set-Content -Path $pcfg -Encoding utf8
}

# 5) Optional: Dependabot
if ($AddDependabot) {
  $dep = ".github/dependabot.yml"
  $depDir = Split-Path $dep -Parent
  if (-not (Test-Path $depDir)) { New-Item -ItemType Directory -Force -Path $depDir | Out-Null }
  if (-not (Test-Path $dep)) {
$depTxt = @'
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
    $depTxt | Set-Content -Path $dep -Encoding utf8
  }
}

# 6) Optional: EditorConfig
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
    $ectxt | Set-Content -Path $ec -Encoding utf8
  }
}

# 7) Optional: CodeQL workflow
if ($AddCodeQL) {
  $codeqlPath = ".github/workflows/codeql.yml"
  $codeqlDir = Split-Path $codeqlPath -Parent
  if (-not (Test-Path $codeqlDir)) { New-Item -ItemType Directory -Force -Path $codeqlDir | Out-Null }
$codeql = @'
name: "CodeQL"
on:
  workflow_dispatch:
  push:
    branches: [ main ]
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
  $codeql | Set-Content -Path $codeqlPath -Encoding utf8
}

# 8) Commit and push
$files = @($WorkflowPath, ".gitattributes", "pre-commit-config.yaml")
if ($AddDependabot) { $files += ".github/dependabot.yml" }
if ($AddEditorConfig) { $files += ".editorconfig" }
if ($AddCodeQL) { $files += ".github/workflows/codeql.yml" }

git add $files | Out-Null
# Only commit if something actually changed
$staged = git diff --cached --name-only
if ($staged) {
  git commit -m "ci: add lint workflow and LF normalization (plus optional files)" | Out-Null
  git push | Out-Null
}

# 9) Optional: run workflow now (requires gh)
if ($RunWorkflow) {
  $ghOK = $true
  try { gh --version | Out-Null } catch { $ghOK = $false }
  if ($ghOK) {
    try { gh auth status 2>$null | Out-Null } catch { $ghOK = $false }
  }
  if ($ghOK) {
    gh workflow run $WorkflowPath --ref $Branch | Out-Null
    Write-Host "Triggered workflow on $Branch"
  } else {
    Write-Host "Skipping workflow run (GitHub CLI not available or not authed)."
  }
}

Write-Host "Done."
