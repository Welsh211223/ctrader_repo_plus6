<#  tools\repo-finalize.ps1
    Purpose: finalize and tidy ctrader_repo_plus6
    Compatible with: Windows PowerShell 5.1
#>

[CmdletBinding()]
param(
  [string] $DiscordWebhook,
  [switch] $TestNotify,
  [switch] $IgnoreHelpers,     # prefer to ignore local helper scripts
  [switch] $RemoveHelpers,     # or remove them instead
  [switch] $CommitAndPush,     # commit and push changes if any
  [switch] $VerifySchedule     # show 'ctrader-paper-daily' task details
)

$ErrorActionPreference = "Stop"

# ------------ Helpers -------------
function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Content
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
  $norm = $Content -replace "`r`n","`n"
  $norm = $norm   -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $norm, $enc)
}

function Ensure-PackageInits {
  $subs = @("brokers","clients","prices","strategies","notifiers")
  foreach ($s in $subs) {
    $dir = Join-Path (Join-Path $RepoRoot "ctrader") $s
    if (Test-Path $dir) {
      $init = Join-Path $dir "__init__.py"
      if (-not (Test-Path $init)) {
        $content = if ($s -eq "notifiers" -and (Test-Path (Join-Path $dir "discord.py"))) {
          "# package init`nfrom .discord import send`n"
        } else { "# package init`n" }
        Write-Utf8NoBom $init $content
        Write-Host "[ OK ] Created $init" -ForegroundColor Green
      }
    }
  }
}

function Ensure-GitignoreEntries {
  param([string[]]$Entries)
  $giPath = Join-Path $RepoRoot ".gitignore"
  $existing = ""
  if (Test-Path $giPath) { $existing = Get-Content $giPath -Raw } else { $existing = "" }
  $added = $false
  foreach ($line in $Entries) {
    if ($existing -notmatch [regex]::Escape($line)) {
      Add-Content $giPath ("`n" + $line)
      $added = $true
    }
  }
  if ($added) { Write-Host "[ OK ] Updated .gitignore" -ForegroundColor Green }
}

function Run-Precommit {
  try {
    Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta
    & pre-commit run --all-files
  } catch {
    # pre-commit not installed or hook error; continue so pytest still runs
  }
}

function Run-Pytest {
  Write-Host ">> pytest" -ForegroundColor Magenta
  & pytest -q
  if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }
}

function Commit-And-Push {
  git add -A
  if (git status --porcelain) {
    git commit -m "chore(repo): finalize; ensure package inits; tidy helpers"
    # your pre-push hook runs pre-commit + pytest already
    git push
    Write-Host "[ OK ] Committed and pushed." -ForegroundColor Green
  } else {
    Write-Host "[INFO] No changes to commit." -ForegroundColor Cyan
  }
}

function Test-Discord {
  param([string]$Webhook)
  $op = Join-Path $RepoRoot "tools\operate-ctrader.ps1"
  if (Test-Path $op) {
    & $op -DiscordWebhook $Webhook -TestNotify
  } else {
    # fallback simple test without project helper
    $body = @{ content = "ctrader webhook test" } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $Webhook -ContentType "application/json" -Body $body | Out-Null
  }
  Write-Host "[ OK ] Discord webhook test sent." -ForegroundColor Green
}

function Show-Schedule {
  $taskName = "ctrader-paper-daily"
  try {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $t | Format-List TaskName, State, Triggers, Actions
  } catch {
    Write-Host "[INFO] Scheduled task '$taskName' not found." -ForegroundColor Yellow
  }
}

# -------- Script body --------
# RepoRoot = parent of this script's folder (tools)
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

Set-Location $RepoRoot

# 1) Ensure package __init__.py files exist (prevents import errors)
Ensure-PackageInits

# 2) Handle local helper scripts: ignore by default unless -RemoveHelpers
$helpers = @(
  "tools/repair-operate-ctrader.ps1",
  "tools/fix-operate-ctrader-ascii.ps1"
)

if ($RemoveHelpers) {
  $toDelete = $helpers | Where-Object { Test-Path (Join-Path $RepoRoot $_) }
  if ($toDelete) {
    Remove-Item ($toDelete | ForEach-Object { Join-Path $RepoRoot $_ }) -Force
    Write-Host "[ OK ] Deleted local helper scripts" -ForegroundColor Green
  }
} else {
  Ensure-GitignoreEntries -Entries $helpers
}

# 3) Keep repo green
Run-Precommit
Run-Pytest

# 4) Commit & push (optional)
if ($CommitAndPush) { Commit-And-Push }

# 5) Discord webhook test (optional)
if ($DiscordWebhook) {
  Test-Discord -Webhook $DiscordWebhook
} elseif ($TestNotify) {
  Write-Host "[WARN] -TestNotify ignored because -DiscordWebhook not provided." -ForegroundColor Yellow
}

# 6) Verify scheduler (optional)
if ($VerifySchedule) { Show-Schedule }

# 7) Sanity summary
Write-Host "`n=== SANITY CHECK ===" -ForegroundColor Cyan
Write-Host ("RepoRoot: " + $RepoRoot)
Write-Host ("Branch: " + (git rev-parse --abbrev-ref HEAD))
Write-Host "Latest commit:"; git --no-pager log -1 --oneline
Write-Host "Untracked files:"; git status --porcelain | Where-Object { $_ -like '?? *' } | ForEach-Object { $_ }
Write-Host "====================`n" -ForegroundColor Cyan
