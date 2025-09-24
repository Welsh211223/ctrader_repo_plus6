# tools/restore-extended-toolbox.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Save-IfMissing { param([string]$Path,[string]$Content) if (-not (Test-Path $Path)) { Write-Utf8NoBom -Path $Path -Content $Content } }

$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# --- Root .gitignore (ensure sensible defaults) --------------------------------
if (-not (Test-Path ".gitignore")) { New-Item -ItemType File -Path ".gitignore" | Out-Null }
$gi = Get-Content .gitignore -Raw
$add = @()
if ($gi -notmatch '(?m)^\s*\.env\s*$')                { $add += "# local secrets`n.env" }
if ($gi -notmatch '(?m)^\s*!\.env\.example\s*$')       { $add += "# allow documented example`n!.env.example" }
if ($gi -notmatch '(?m)^\s*\.venv\/?\s*$')             { $add += ".venv" }
if ($gi -notmatch '(?m)^\s*__pycache__\/?\s*$')        { $add += "__pycache__/" }
if ($gi -notmatch '(?m)^\s*\.pytest_cache\/?\s*$')     { $add += ".pytest_cache/" }
if ($gi -notmatch '(?m)^\s*dist\/?\s*$')               { $add += "dist/" }
if ($gi -notmatch '(?m)^\s*build\/?\s*$')              { $add += "build/" }
if ($gi -notmatch '(?m)^\s*\.mypy_cache\/?\s*$')       { $add += ".mypy_cache/" }
if ($add.Count) { Add-Content .gitignore ("`n" + ($add -join "`n") + "`n") }

# --- pyproject.toml (black/isort) ----------------------------------------------
$pyproject = @'
[tool.black]
line-length = 88
target-version = ["py311","py312","py313"]

[tool.isort]
profile = "black"
line_length = 88
'@
Save-IfMissing "pyproject.toml" $pyproject

# --- .env.example ---------------------------------------------------------------
$envExample = @'
# --- CoinSpot ---
COINSPOT_API_KEY=YOUR_KEY_HERE
COINSPOT_API_SECRET=YOUR_SECRET_HERE
COINSPOT_LIVE_DANGEROUS=false  # change to true only when ready to send live orders

# --- Optional notifications ---
DISCORD_WEBHOOK=
'@
Save-IfMissing ".env.example" $envExample

# --- .pre-commit-config.yaml ----------------------------------------------------
$pre = @'
repos:
  - repo: https://github.com/psf/black
    rev: 24.8.0
    hooks: [ { id: black } ]

  - repo: https://github.com/PyCQA/isort
    rev: 5.13.2
    hooks: [ { id: isort } ]

  - repo: https://github.com/PyCQA/flake8
    rev: 7.1.1
    hooks: [ { id: flake8 } ]

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ["--baseline", ".secrets.baseline"]
        exclude: "^\\.secrets\\.baseline$"
'@
Save-IfMissing ".pre-commit-config.yaml" $pre

# --- tools/ scripts -------------------------------------------------------------
New-Item -ItemType Directory -Force -Path "tools" | Out-Null

# 1) precommit-green.ps1
$precommitGreen = @'
param([int]$MaxPasses = 5)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
for ($i=1; $i -le $MaxPasses; $i++) {
  pre-commit run -a
  if ($LASTEXITCODE -eq 0) { Write-Host "✅ Hooks green on pass #$i"; exit 0 }
  git add -A
  if ($i -eq $MaxPasses) { Write-Warning "Hooks still not green after $i passes."; exit 1 }
}
'@
Save-IfMissing "tools\precommit-green.ps1" $precommitGreen

# 2) fix-detect-secrets.ps1
$fixDetect = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U detect-secrets | Out-Null
$scan = & $py -m detect_secrets scan --all-files --exclude-files '^\.secrets\.baseline$'
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText(".secrets.baseline", ($scan -join "`n"), $enc)
Write-Host "✅ .secrets.baseline regenerated."
'@
Save-IfMissing "tools\fix-detect-secrets.ps1" $fixDetect

# 3) repair-coinspot.ps1 (AST-based guard + indent fixer)
$repairCoinspot = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
function Run { param([string]$Exe,[string[]]$Args=@()); Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan; & $Exe @Args; if ($LASTEXITCODE -ne 0){ throw "Failed: $Exe ($LASTEXITCODE)"} }
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }

# Ensure guard module
$guardPath = "src\ctrader\utils\live_guard.py"
$guard = @"
from __future__ import annotations
