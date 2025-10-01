<# tools/fix-discord-and-notifiers.ps1
   Fix Ruff F401 for notifiers init + make Discord notify pure-PowerShell.
   Compatible: Windows PowerShell 5.1
#>

[CmdletBinding()]
param(
  [string] $DiscordWebhook,   # optional: pass to test immediately
  [switch] $TestNotify,       # optional: send a test message if webhook is given
  [switch] $CommitAndPush     # optional: commit & push after fixes
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $enc  = New-Object System.Text.UTF8Encoding($false)  # no BOM
  $norm = $Content -replace "`r`n","`n"
  $norm = $norm   -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $norm, $enc)
}

# 1) Fix ctrader/notifiers/__init__.py to be an explicit re-export
$notInit = Join-Path $RepoRoot "ctrader\notifiers\__init__.py"
$notInitContent = @'
# package init (explicit re-export for Ruff)
from .discord import send as send
__all__ = ["send"]
'@
Write-Utf8NoBom $notInit $notInitContent
Write-Host "[ OK ] Patched $notInit" -ForegroundColor Green

# 2) Patch tools/operate-ctrader.ps1 to do Discord notify in PowerShell
$op = Join-Path $RepoRoot "tools\operate-ctrader.ps1"
if (-not (Test-Path $op)) {
  throw "Could not find $op"
}
$opText = Get-Content $op -Raw

# Pure PowerShell Notify-Discord function body
$newNotify = @'
function Notify-Discord([string]$Message) {
  # Read webhook from .env (via project helper) OR environment
  try {
    # ensure TLS 1.2+
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {}

  # Try to call project helper if present
  if (Get-Command -Name Get-EnvKV -ErrorAction SilentlyContinue) {
    $url = Get-EnvKV "DISCORD_WEBHOOK_URL"
  } else {
    $envPath = Join-Path $PWD ".env"
    $url = $null
    if (Test-Path $envPath) {
      $kv = Get-Content $envPath -Raw |
        Select-String -Pattern '^DISCORD_WEBHOOK_URL=(.+)$' -AllMatches
      if ($kv.Matches.Count -gt 0) {
        $url = $kv.Matches[0].Groups[1].Value.Trim()
      }
    }
    if (-not $url) { $url = $env:DISCORD_WEBHOOK_URL }
  }

  if (-not $url) {
    if (Get-Command -Name Warn -ErrorAction SilentlyContinue) {
      Warn "DISCORD_WEBHOOK_URL not set"
    } else {
      Write-Warning "DISCORD_WEBHOOK_URL not set"
    }
    return
  }

  $body = @{ content = $Message } | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body $body | Out-Null
    if (Get-Command -Name Ok -ErrorAction SilentlyContinue) {
      Ok "Sent Discord notification"
    } else {
      Write-Host "[ OK ] Sent Discord notification" -ForegroundColor Green
    }
  } catch {
    if (Get-Command -Name Write-Err -ErrorAction SilentlyContinue) {
      Write-Err ("Discord notify failed: " + $_.Exception.Message)
    } else {
      Write-Error ("Discord notify failed: " + $_.Exception.Message)
    }
    throw
  }
}
'@

# Replace existing Notify-Discord function or append if missing
$pattern = '(?s)function\s+Notify-Discord\s*\([^\)]*\)\s*\{.*?\}'
if ($opText -match $pattern) {
  $patched = [regex]::Replace($opText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newNotify })
} else {
  $patched = $opText.TrimEnd() + "`r`n`r`n" + $newNotify + "`r`n"
}
Write-Utf8NoBom $op $patched
Write-Host "[ OK ] Patched $op (Notify-Discord → PowerShell)" -ForegroundColor Green

# 3) Keep repo green
try {
  Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta
  & pre-commit run --all-files
} catch { }
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# 4) Commit & push if requested
if ($CommitAndPush) {
  git add -A
  if (git status --porcelain) {
    git commit -m "fix(notify): explicit re-export in notifiers; PS-based Discord webhook in operate-ctrader"
    git push
    Write-Host "[ OK ] Committed and pushed." -ForegroundColor Green
  } else {
    Write-Host "[INFO] No changes to commit." -ForegroundColor Cyan
  }
}

# 5) Optional immediate test
if ($DiscordWebhook) {
  # persist webhook
  $envPath = Join-Path $RepoRoot ".env"
  $envTxt = if (Test-Path $envPath) { Get-Content $envPath -Raw } else { "" }
  if ($envTxt -notmatch '^DISCORD_WEBHOOK_URL=') {
    Add-Content $envPath "`nDISCORD_WEBHOOK_URL=$DiscordWebhook"
    Write-Host "[ OK ] Added DISCORD_WEBHOOK_URL to .env" -ForegroundColor Green
  } else {
    $envTxt = [regex]::Replace($envTxt, '^DISCORD_WEBHOOK_URL=.*$', "DISCORD_WEBHOOK_URL=$DiscordWebhook", 'Multiline')
    Write-Utf8NoBom $envPath $envTxt
    Write-Host "[ OK ] Updated DISCORD_WEBHOOK_URL in .env" -ForegroundColor Green
  }

  if ($TestNotify) {
    # call the freshly patched function through the main operator script
    & (Join-Path $RepoRoot "tools\operate-ctrader.ps1") -DiscordWebhook $DiscordWebhook -TestNotify
  }
}

# 6) Final summary
Write-Host "`n=== SANITY CHECK ===" -ForegroundColor Cyan
Write-Host ("RepoRoot: " + $RepoRoot)
Write-Host ("Branch: " + (git rev-parse --abbrev-ref HEAD))
Write-Host "Latest commit:"; git --no-pager log -1 --oneline
Write-Host "Untracked files:"; git status --porcelain | Where-Object { $_ -like '?? *' } | ForEach-Object { $_ }
Write-Host "====================`n" -ForegroundColor Cyan
