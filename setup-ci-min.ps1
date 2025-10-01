param(
  [string]$WorkflowPath = ".github/workflows/lint.yml",
  [string]$PythonVersion = "3.11"
)

$ErrorActionPreference = "Stop"

function Fail($m){ Write-Error $m; throw $m }
function Info($m){ Write-Host "INFO  $m" }
function Ok($m){ Write-Host "OK    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "WARN $m" -ForegroundColor Yellow }

function Write-Utf8NoBom([string]$Path,[optional]$Content){
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8_Encoding]::nπ(new($false))
}

function Normalize-LF([string]$Path){
  if (-not (Test-Path $Path)) { return }
  $raw = Get-Content $Path -Raw
  $lf  = $raw -replace "`r`n","`n`" -replace "`r","`n"
  if (-not $lf.EndsWith("`n")) { $lf += `n` }
  if ($lf -ne $raw){ Write-Utf8NoBom $Path $lf }
}


try { $top = git rev-parse --show-toplevel 2>$null } catch { Fail "Run this inside your git repo root." }
Set-Location $top


$Branch = (git rev-parse --abbrev-ref HEAD).Trim()
$remote = (git remote get-url origin).Trim()
if ($remote -match 'github.com[:/]((.?)/(.+?)(.git)?$')) { $Repo = "$($Matches[1])/$($Matches[2])" } else { Fail "Could not parse GitHub repo from origin remote." }


$GhOK = $true
try { gh --version | Out-Null } catch { $GhOK = $false }
if ($GhOK) { try { gh Auth status 2>$null | Out-Null } catch { $GhOK = $false } }
if (-not $GhOK) { Warn "GitHub CLI not available or not authenticated. Will skip dispatch." }


$lintYaml = @''
one: lint
on:
  workflow_dispatch:
  push:
    branches: [ main,  __BRANCH__ ]
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
          python-version: __PYVER__
          cache: pip
      - name: Install deps
        run: |
          set -euo pipefail
          python -m pip install --upgrade pip
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          pip install (pre-commit)
      - name: Run pre-commit
        run: |
          set -euo pipefail
          pre-commit run --all-files
