# tools/rotate-and-ci.ps1
# Purpose:
#  - Safely rotate CoinSpot API key/secret in .env (with backup + ACL lockdown)
#  - Optionally add a GitHub Actions CI workflow that runs pre-commit + pytest
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\tools\rotate-and-ci.ps1 [-EnableCI]

param(
  [switch]$EnableCI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $rp = $null
  try { $rp = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch {}
  if (-not $rp) { $rp = $Path }
  [System.IO.File]::WriteAllText($rp, $Content, $enc)
}

function Ensure-Line {
  param([string]$Path, [string]$Key, [string]$Value)
  $content = ""
  if (Test-Path $Path) { $content = Get-Content -LiteralPath $Path -Raw }
  if ($content -match "(?m)^\s*$([regex]::Escape($Key))\s*=") {
    $content = [regex]::Replace($content, "(?m)^\s*$([regex]::Escape($Key))\s*=.*$", "$Key=$Value")
  } else {
    if ($content -and -not ($content.TrimEnd().EndsWith("`n"))) { $content += "`r`n" }
    $content += "$Key=$Value`r`n"
  }
  Write-Utf8NoBom -Path $Path -Content $content
}

function Get-EnvVal {
  param([string]$Path, [string]$Key)
  if (-not (Test-Path $Path)) { return $null }
  $m = (Select-String -LiteralPath $Path -Pattern "^\s*$([regex]::Escape($Key))\s*=(.*)$" -AllMatches).Matches
  if ($m.Count -gt 0) { return ($m[0].Groups[2].Value).Trim() }
  return $null
}

function Lockdown-EnvFile {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  try {
    $acl = Get-Acl -LiteralPath $Path
    $id  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    # Stop inheriting; remove existing rules
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    # Grant current user FullControl
    $ar = New-Object System.Security.AccessControl.FileSystemAccessRule($id, "FullControl", "Allow")
    $acl.AddAccessRule($ar) | Out-Null
    Set-Acl -LiteralPath $Path -AclObject $acl
  } catch {
    Write-Warning "Could not restrict ACL on ${Path}: $_"
  }
}

function Run {
  param([string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

# --- Resolve venv python
$RepoRoot = (Get-Location).Path
$VenvPy = Join-Path $RepoRoot ".\.venv\Scripts\python.exe"
if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# --- 1) Rotate CoinSpot keys (guided)
$envPath = Join-Path $RepoRoot ".env"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $envPath)) {
  Write-Host "No .env found; creating a new one." -ForegroundColor Yellow
  Write-Utf8NoBom -Path $envPath -Content "# Local secrets`r`n"
}

# Backup
$backup = "$envPath.$stamp.bak"
Copy-Item -LiteralPath $envPath -Destination $backup -Force
Write-Host "Backed up .env -> $backup" -ForegroundColor DarkGray

# Short instructions
Write-Host @"
=== Manual step required (1-2 minutes) ===
1) In your browser, open your CoinSpot account.
2) Go to Settings -> My API Keys (or API section).
3) Create a NEW API key + secret with the same permissions you use today.
4) DO NOT revoke the old key yet.
5) Copy the NEW key & secret and return here to paste them.

When you're ready, press Enter to continue...
"@
[void][System.Console]::ReadLine()

# Collect new key/secret
$newKey = Read-Host "Paste NEW COINSPOT_API_KEY"
$newSec = Read-Host "Paste NEW COINSPOT_API_SECRET"

if ([string]::IsNullOrWhiteSpace($newKey) -or [string]::IsNullOrWhiteSpace($newSec)) {
  throw "New key/secret cannot be empty."
}

# Preserve old values (for quick rollback)
$oldKey = Get-EnvVal -Path $envPath -Key "COINSPOT_API_KEY"
$oldSec = Get-EnvVal -Path $envPath -Key "COINSPOT_API_SECRET"
if ($oldKey) { Ensure-Line -Path $envPath -Key "COINSPOT_API_KEY_OLD" -Value $oldKey }
if ($oldSec) { Ensure-Line -Path $envPath -Key "COINSPOT_API_SECRET_OLD" -Value $oldSec }

# Set new active values
Ensure-Line -Path $envPath -Key "COINSPOT_API_KEY" -Value $newKey
Ensure-Line -Path $envPath -Key "COINSPOT_API_SECRET" -Value $newSec
Ensure-Line -Path $envPath -Key "SECRETS_ROTATED_AT" -Value $stamp

# Lock down .env ACL to current user only
Lockdown-EnvFile -Path $envPath
Write-Host "Updated + locked down .env. New keys are now active locally." -ForegroundColor Green

Write-Host @"
Next:
 - Restart any running ctrader processes so they pick up the new env vars.
 - Verify basic read-only API calls work (e.g., balances).
 - Once confirmed, go back to CoinSpot and REVOKE the OLD key.

If you need to roll back quickly, your previous key is stored in:
  COINSPOT_API_KEY_OLD / COINSPOT_API_SECRET_OLD (and in .env backup)
"@ -ForegroundColor Yellow

# --- 2) Local sanity checks
try {
  Run $VenvPy @('-m','pip','install','-U','pre-commit','detect-secrets','black','isort','flake8','pytest')
  Run $VenvPy @('-m','black','--','src')
  Run $VenvPy @('-m','isort','--','src')
  Run $VenvPy @('-m','flake8','src')
  Run $VenvPy @('-m','pytest','-q')
  Write-Host "Local checks OK." -ForegroundColor Green
} catch {
  Write-Warning ("Local checks did not pass: {0}" -f $_)
}

# --- 3) Optional CI workflow (GitHub Actions)
if ($EnableCI) {
  $wfDir = Join-Path $RepoRoot ".github\workflows"
  if (-not (Test-Path $wfDir)) { New-Item -ItemType Directory -Force -Path $wfDir | Out-Null }
  $ciPath = Join-Path $wfDir "ci.yml"

  $ci = @"
name: ci

on:
  push:
    branches: [ "**" ]
  pull_request:
    branches: [ "**" ]

jobs:
  lint-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
      - name: Install tools
        run: |
          python -m pip install -U pip
          python -m pip install -U pre-commit detect-secrets black isort flake8 pytest
      - name: Pre-commit (format, lint, secrets)
        run: |
          pre-commit run --all-files
      - name: Tests
        run: |
          pytest -q
"@

  Write-Utf8NoBom -Path $ciPath -Content $ci
  Write-Host "Created .github/workflows/ci.yml" -ForegroundColor Green

  & git add .github/workflows/ci.yml | Out-Null
  if (& git diff --staged --name-only) {
    Run 'git' @('commit','-m','ci: add GitHub Actions workflow (pre-commit + pytest)')
  } else {
    Write-Host "No changes to commit for CI." -ForegroundColor DarkGray
  }
}

Write-Host "`n✅ Rotation script finished." -ForegroundColor Green
if ($EnableCI) { Write-Host "✅ CI workflow added." -ForegroundColor Green }
