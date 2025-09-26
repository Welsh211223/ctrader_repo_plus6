param(
  [string]$BranchAlsoRun = "egress-allowlist-lock",  # add your feature branch here
  [switch]$SetBranchProtection                      # needs admin perms on repo
)

$ErrorActionPreference = "Stop"
try { $top = git rev-parse --show-toplevel 2>$null } catch { throw "Run inside your git repo root." }
Set-Location $top

# --- .gitignore: ignore logs/backups/helpers ---
$gi = ".gitignore"
$add = @"
# CI artifacts / helpers
job-*.log
.ci-helper.json
# Workflow backups + helper scripts
*.yml.bak.*
setup-ci-*.ps1
"@
if (Test-Path $gi) {
  $cur = Get-Content $gi -Raw
  $need = $add -split "`n" | Where-Object { $_ -and ($cur -notmatch [regex]::Escape($_)) }
  if ($need) { Add-Content $gi "`n$($need -join "`n")`n" }
} else {
  $add | Set-Content $gi -Encoding utf8
}

# --- lint.yml (hardened + pre-commit) ---
$lint = ".github/workflows/lint.yml"
New-Item -ItemType Directory -Force -Path ".github/workflows" | Out-Null
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
      - name: Harden Runner (audit)
        uses: step-security/harden-runner@v2
        with:
          egress-policy: audit

      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
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

      - name: Optional type-check (mypy if configured)
        if: ${{ hashFiles('mypy.ini','setup.cfg','pyproject.toml') != '' }}
        run: |
          set -euo pipefail
          python -m pip install mypy
          mypy .
'@
$lintYaml = $lintYaml.Replace('__BRANCH__', $BranchAlsoRun)
$lintYaml | Set-Content $lint -Encoding utf8
(Get-Content $lint -Raw).Replace("`r`n","`n").Replace("`r","`n") | Set-Content $lint -Encoding utf8

# --- tests.yml (runs only if tests exist) ---
$tests = ".github/workflows/tests.yml"
$testsYaml = @'
name: tests
on:
  workflow_dispatch:
  push:
    branches: [ main, __BRANCH__ ]
    paths:
      - "**/*.py"
      - "pyproject.toml"
      - "requirements*.txt"
      - ".github/workflows/tests.yml"
  pull_request:
    branches: [ main ]

permissions:
  contents: read

concurrency:
  group: tests-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pytest:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    strategy:
      matrix:
        python-version: [ "3.10", "3.11", "3.12" ]
    steps:
      - name: Harden Runner (audit)
        uses: step-security/harden-runner@v2
        with:
          egress-policy: audit

      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
          cache: pip

      - name: Install deps
        run: |
          set -euo pipefail
          python -m pip install --upgrade pip
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          python -m pip install pytest pytest-cov

      - name: Run tests (skip if none)
        run: |
          set -euo pipefail
          if ls -1 test_*.py *_test.py 2>/dev/null | grep -q . || [ -d tests ]; then
            pytest -q --maxfail=1 --disable-warnings --cov=. --cov-report=xml
          else
            echo "No tests found; skipping."
          fi

      - name: Upload coverage (if produced)
        if: ${{ hashFiles('coverage.xml') != '' }}
        uses: actions/upload-artifact@v4
        with:
          name: coverage-xml
          path: coverage.xml
'@
$testsYaml = $testsYaml.Replace('__BRANCH__', $BranchAlsoRun)
$testsYaml | Set-Content $tests -Encoding utf8
(Get-Content $tests -Raw).Replace("`r`n","`n").Replace("`r","`n") | Set-Content $tests -Encoding utf8

# --- Stage/commit/push ---
git add $lint $tests $gi 2>$null
pre-commit run --all-files
git add -A
if (git diff --cached --name-only) {
  git commit -m "ci: harden lint, add smart tests, tidy .gitignore"
  git push
}

# --- Optional: branch protection (lint + tests + CodeQL) ---
if ($SetBranchProtection) {
  $slug = (git remote get-url origin) -replace '.*github\.com[:/]', '' -replace '\.git$',''
  $body = @'
{
  "required_status_checks": { "strict": true, "contexts": ["lint","tests","CodeQL"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
'@
  $null = $body | gh api -X PUT "repos/$slug/branches/main/protection" -H "Accept: application/vnd.github+json" --input -
  Write-Host "Branch protection updated for 'main'."
}

Write-Host "CI hardening complete."
