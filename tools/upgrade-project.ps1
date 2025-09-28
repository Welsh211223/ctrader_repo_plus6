<#
.SYNOPSIS
  One-shot project upgrade for ctrader_repo_plus6 (WinPS 5.1-safe).

  Adds:
    - Debounced watcher (tools\watch.ps1)
    - Pre-commit: ruff, black, isort, detect-secrets (+ baseline)
    - pytest scaffold
    - GitHub Actions: lint + test (harden-runner)
    - .gitignore, .editorconfig, .gitattributes
    - tools\tasks.ps1 (run/lint/format/test/precommit-*)
    - requirements/pyproject and Python package scaffold
#>

[CmdletBinding()]
param(
  [switch]$CommitAndPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "[ERR ] $msg" -ForegroundColor Red }

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
    Write-Ok "Created directory: $Path"
  }
}

function Save-FileUtf8LF {
  param(
    [string]$Path,
    [string]$Content,
    [switch]$SkipIfExists
  )
  if ($SkipIfExists -and (Test-Path -LiteralPath $Path)) { return }
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Directory $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
  Write-Ok "Wrote: $Path"
}

function Ensure-GitRepo {
  try { git rev-parse --is-inside-work-tree *> $null }
  catch { throw "Not inside a Git repository. Run from your repo root." }
}

function Ensure-PythonScaffold {
  Ensure-Directory ".\ctrader"

  $initPy = @'
__all__ = []
'@
  if (-not (Test-Path ".\ctrader\__init__.py")) {
    Save-FileUtf8LF -Path ".\ctrader\__init__.py" -Content $initPy
  }

  $corePy = @'
def run():
    print("ctrader: core.run() placeholder")
'@
  if (-not (Test-Path ".\ctrader\core.py")) {
    Save-FileUtf8LF -Path ".\ctrader\core.py" -Content $corePy
  }

  $mainPy = @'
from .core import run

def main():
    run()

if __name__ == "__main__":
    main()
'@
  if (-not (Test-Path ".\ctrader\__main__.py")) {
    Save-FileUtf8LF -Path ".\ctrader\__main__.py" -Content $mainPy
  }
}

function Ensure-ConfigFiles {
  $gitignore = @'
# Python
__pycache__/
*.pyc
.venv/
.env
.env.*
.pytest_cache/
build/
dist/
*.egg-info/

# IDE
.vscode/
.idea/

# OS
.DS_Store
Thumbs.db
'@
  Save-FileUtf8LF -Path ".gitignore" -Content $gitignore -SkipIfExists

  $editorconfig = @'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 2
trim_trailing_whitespace = true

[*.py]
indent_size = 4
'@
  Save-FileUtf8LF -Path ".editorconfig" -Content $editorconfig -SkipIfExists

  $gitattributes = @'
* text=auto eol=lf
'@
  Save-FileUtf8LF -Path ".gitattributes" -Content $gitattributes -SkipIfExists

  $envExample = @'
# Example .env
COINSPOT_API_KEY=
COINSPOT_API_SECRET=
LOG_LEVEL=INFO
'@
  Save-FileUtf8LF -Path ".env.example" -Content $envExample -SkipIfExists

  if (-not (Test-Path ".env")) {
    Write-Warn "No .env found. Copied template at .env.example — duplicate to .env and fill values."
  }
}

function Ensure-Requirements {
  $req = @'
pydantic>=2.7
requests>=2.32
python-dotenv>=1.0
pandas>=2.2
numpy>=2.0
# Dev tools
pre-commit>=3.7
ruff>=0.5
black>=24.8
isort>=5.13
pytest>=8.3
detect-secrets>=1.5
'@
  Save-FileUtf8LF -Path "requirements.txt" -Content $req -SkipIfExists
}

function Ensure-Pyproject {
  $pyproj = @'
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "ctrader"
version = "0.1.0"
description = "Crypto trader bootstrap"
requires-python = ">=3.10"
dependencies = []

[tool.black]
line-length = 100
target-version = ["py310"]

[tool.isort]
profile = "black"
line_length = 100
known_first_party = ["ctrader"]

[tool.ruff]
line-length = 100
target-version = "py310"
lint.select = ["E","F","I","W","B","Q","UP","S","C90"]
lint.ignore = ["E203","E266","E501","W503"]
lint.per-file-ignores = { "tests/*" = ["S101"] }

[tool.pytest.ini_options]
addopts = "-q"
pythonpath = ["."]
testpaths = ["tests"]
'@
  Save-FileUtf8LF -Path "pyproject.toml" -Content $pyproj -SkipIfExists
}

function Ensure-PreCommit {
  $yml = @'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.9
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
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ["--baseline", ".secrets.baseline"]
'@
  Save-FileUtf8LF -Path ".pre-commit-config.yaml" -Content $yml

  $baseline = @'
{
  "version": "1.5.0",
  "plugins_used": [
    { "name": "Base64HighEntropyString", "limit": 4.5 },
    { "name": "HexHighEntropyString",   "limit": 3.0 },
    { "name": "KeywordDetector",         "keyword_exclude": "" }
  ],
  "results": {}
}
'@
  Save-FileUtf8LF -Path ".secrets.baseline" -Content $baseline -SkipIfExists
}

function Ensure-Tests {
  Ensure-Directory ".\tests"
  $testSample = @'
from ctrader.core import run

def test_smoke(capsys):
    run()
    captured = capsys.readouterr()
    assert "ctrader: core.run() placeholder" in captured.out
'@
  Save-FileUtf8LF -Path ".\tests\test_smoke.py" -Content $testSample -SkipIfExists
}

function Ensure-Tasks {
  $ps1 = @'
param(
  [ValidateSet("run","lint","format","test","precommit-install","precommit-run")]
  [string]$Task="run"
)

function Exec([string]$cmd){
  Write-Host ">> $cmd"
  & cmd /c $cmd
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $cmd" }
}

switch ($Task) {
  "run"                { Exec "python -m ctrader" }
  "lint"               { Exec "ruff check ."; Exec "isort --check-only ."; Exec "black --check ." }
  "format"             { Exec "ruff check --fix ."; Exec "isort ."; Exec "black ." }
  "test"               { Exec "pytest" }
  "precommit-install"  { Exec "pre-commit install"; Exec "pre-commit install --hook-type commit-msg" }
  "precommit-run"      { Exec "pre-commit run --all-files" }
  default              { Write-Host "Unknown task: $Task"; exit 1 }
}
'@
  Save-FileUtf8LF -Path ".\tools\tasks.ps1" -Content $ps1
}

function Ensure-Watcher {
  $watch = @'
param(
  [string]$Path = ".\ctrader",
  [int]$DebounceMs = 350
)

$ErrorActionPreference = "Stop"

function Run-Once(){
  Write-Host ('[RUN ] python -m ctrader') -ForegroundColor Cyan
  & python -m ctrader
}

if (-not (Test-Path -LiteralPath $Path)) { $Path = "." }

$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = (Resolve-Path $Path)
$fsw.Filter = "*.py"
$fsw.IncludeSubdirectories = $true
$fsw.EnableRaisingEvents = $true

$timer = New-Object System.Timers.Timer
$timer.Interval = $DebounceMs
$timer.AutoReset = $false
$script:pending = $false

$action = {
  $script:pending = $true
  $null = $timer.Stop()
  $null = $timer.Start()
}

$created = Register-ObjectEvent $fsw Created -Action $action
$changed = Register-ObjectEvent $fsw Changed -Action $action
$deleted = Register-ObjectEvent $fsw Deleted -Action $action
$renamed = Register-ObjectEvent $fsw Renamed -Action $action

$onTick = Register-ObjectEvent $timer Elapsed -Action {
  if ($script:pending) {
    $script:pending = $false
    try { Run-Once } catch { Write-Host ('[ERR ] ' + $_.Exception.Message) -ForegroundColor Red }
  }
}

Write-Host ('[WATCH] Watching ' + $fsw.Path + ' (Ctrl+C to stop)...') -ForegroundColor Green
try {
  Run-Once
  while ($true) { Start-Sleep -Seconds 1 }
} finally {
  Unregister-Event -SourceIdentifier $created.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $changed.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $deleted.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $renamed.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $onTick.Name -ErrorAction SilentlyContinue
  $fsw.Dispose()
  $timer.Dispose()
}
'@
  Save-FileUtf8LF -Path ".\tools\watch.ps1" -Content $watch
}

function Ensure-CI {
  Ensure-Directory ".github\workflows"

  $lint = @'
name: lint

on:
  push:
    branches: [ main ]
    paths: ["**.py", ".pre-commit-config.yaml", "pyproject.toml", ".github/workflows/lint.yml"]
  pull_request:
    paths: ["**.py", ".pre-commit-config.yaml", "pyproject.toml", ".github/workflows/lint.yml"]

permissions:
  contents: read

concurrency:
  group: lint-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@v3
        with:
          egress-policy: audit
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.10"
      - name: Install tools
        run: |
          python -m pip install --upgrade pip
          pip install ruff black isort pre-commit detect-secrets
      - name: Pre-commit (all files)
        run: |
          pre-commit run --all-files
'@
  Save-FileUtf8LF -Path ".github\workflows\lint.yml" -Content $lint

  $test = @'
name: test

on:
  push:
    branches: [ main ]
    paths: ["**.py", "pyproject.toml", "requirements.txt", ".github/workflows/test.yml", "tests/**"]
  pull_request:
    paths: ["**.py", "pyproject.toml", "requirements.txt", ".github/workflows/test.yml", "tests/**"]

permissions:
  contents: read

concurrency:
  group: test-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pytest:
    runs-on: ubuntu-latest
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@v3
        with:
          egress-policy: audit
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.10"
      - name: Install deps
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
      - name: Run tests
        run: |
          pytest -q
'@
  Save-FileUtf8LF -Path ".github\workflows\test.yml" -Content $test
}

function Ensure-BootstrapCompat {
  # Only writes if missing (so we don't clobber an existing one)
  $bootstrap = @'
[CmdletBinding()]
param(
  [switch]$CommitAndPush,
  [switch]$TriggerOnce,
  [switch]$Watch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[ERR ] $m" -ForegroundColor Red }

function Save-FileUtf8LF { param([string]$Path,[string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir) { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null } }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function Run-Once { Write-Info "Running ctrader once..."; python -m ctrader }

function Do-CommitAndPush {
  try {
    git add -A
    $status = git status --porcelain
    if ([string]::IsNullOrWhiteSpace($status)) { Write-Info "No changes to commit."; return }
    git commit -m "chore: project bootstrap/update"
    git push
    Write-Ok "Committed and pushed."
  } catch {
    Write-Err ("Git commit/push failed: " + $_.Exception.Message); throw
  }
}

if ($TriggerOnce) { Run-Once }
if ($Watch) { & ".\tools\watch.ps1" }
if ($CommitAndPush) { Do-CommitAndPush }
'@
  Save-FileUtf8LF -Path ".\tools\bootstrap-trader.ps1" -Content $bootstrap -SkipIfExists
}

function Maybe-Install-DevTools {
  try {
    Write-Info "Ensuring dev tools (pip install)…"
    & python -m pip install --upgrade pip | Out-Null
    & pip install -r requirements.txt | Out-Null
    Write-Ok "Dev tools installed."
  } catch {
    Write-Warn ("pip install skipped/failed: " + $_.Exception.Message)
  }
}

function Do-CommitAndPush {
  try {
    git add -A
    $status = git status --porcelain
    if ([string]::IsNullOrWhiteSpace($status)) {
      Write-Info "No changes to commit."
      return
    }
    $msg = "upgrade: watcher, pre-commit, pytest, CI, configs"
    git commit -m $msg
    git push
    Write-Ok "Committed and pushed."
  } catch {
    Write-Err ("Git commit/push failed: " + $_.Exception.Message)
    throw
  }
}

# ----- Run all steps -----
Ensure-GitRepo
Ensure-PythonScaffold
Ensure-ConfigFiles
Ensure-Requirements
Ensure-Pyproject
Ensure-PreCommit
Ensure-Tests
Ensure-Tasks
Ensure-Watcher
Ensure-CI
Ensure-BootstrapCompat
Maybe-Install-DevTools

$next = @'
Upgrade complete. Next steps:
  1) Activate venv, then run:  pip install -r requirements.txt
  2) Install hooks once:       .\tools\tasks.ps1 precommit-install
  3) Format & lint locally:    .\tools\tasks.ps1 format  ;  .\tools\tasks.ps1 lint
  4) Run tests:                .\tools\tasks.ps1 test
  5) Start watcher:            .\tools\watch.ps1
'@
Write-Host $next -ForegroundColor Cyan

if ($CommitAndPush) { Do-CommitAndPush }
