[CmdletBinding()]
param([switch]$CommitAndPush)

$ErrorActionPreference = 'Stop'
function OK($m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function INFO($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function WARN($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function SaveUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $norm = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $norm, [Text.UTF8Encoding]::new($false))
  OK "Wrote: $Path"
}

# --- Write a fixed tools/operate-ctrader.ps1 ---
$operate = @'
<#
operate-ctrader.ps1  —  WinPS 5.1-safe helper (fixed Discord quoting & scheduler)
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = ".\configs\example.yml",
  [switch]$DryRun,
  [switch]$Paper,
  [switch]$AssumeYes,

  [switch]$ScheduleDailyPaper,
  [string]$DailyTime = "09:00",

  [string]$DiscordWebhook,
  [switch]$TestNotify,

  [switch]$PrecommitAndTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
function Save-FileUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir){ Ensure-Dir $dir }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
  Ok "Wrote: $Path"
}
function Get-Python(){
  $p1 = Join-Path $PSScriptRoot "..\.venv\Scripts\python.exe"
  if (Test-Path $p1) { return (Resolve-Path $p1).Path }
  return "python"
}
function Ensure-EnvKV([string]$Key,[string]$Value){
  $envPath = ".\.env"
  $cur = ""
  if (Test-Path -LiteralPath $envPath){ $cur = Get-Content -LiteralPath $envPath -Raw }
  if ($cur -match "^\s*$([regex]::Escape($Key))\s*="){
    $new = [regex]::Replace($cur, "^\s*$([regex]::Escape($Key))\s*=.*$", "$Key=$Value", "Multiline")
    Save-FileUtf8LF $envPath $new
    Ok "Updated $Key in .env"
  } else {
    if ($cur -and -not $cur.EndsWith("`n")){ $cur += "`n" }
    Save-FileUtf8LF $envPath ($cur + "$Key=$Value`n")
    Ok "Added $Key to .env"
  }
}

function Run-Plan([switch]$Paper,[switch]$AssumeYes){
  if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
  $py = Get-Python
  $args = @("-m","ctrader","plan","--config",$ConfigPath)
  if ($Paper){ $args += "--paper" }
  if ($AssumeYes){ $env:CTRADER_ASSUME_YES = "1" } else { Remove-Item Env:\CTRADER_ASSUME_YES -ErrorAction SilentlyContinue }
  Info "Running: $py $($args -join ' ')"
  & $py @args
  if ($LASTEXITCODE -ne 0) { throw "ctrader plan exited with code $LASTEXITCODE" }
  if ($Paper){
    $out = "paper_trades.csv"
    if (Test-Path -LiteralPath $out){ Ok "Paper fills written to $out" } else { Warn "No fills written." }
  }
}

function Notify-Discord([string]$Message){
  # Avoid broken QuoteArgument: use env var + tiny Python helper
  $py = Get-Python
  $tmp = Join-Path $env:TEMP "ctrader_notify.py"
  $code = @"
import os
from ctrader.notifiers.discord import send
msg = os.environ.get('CTRADER_NOTIFY_MSG','(empty)')
send(msg)
"@
  Save-FileUtf8LF $tmp $code
  $env:CTRADER_NOTIFY_MSG = $Message
  & $py $tmp
  if ($LASTEXITCODE -ne 0) { throw "discord notify failed ($LASTEXITCODE)" }
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  Ok "Sent Discord notification"
}

function Schedule-DailyPaper([string]$At,[switch]$AssumeYes){
  # Expect "HH:MM" (local time). New-ScheduledTaskTrigger needs a DateTime for -At.
  if ($At -notmatch '^\d{2}:\d{2}$'){ throw "DailyTime must be HH:MM (e.g., 09:00)" }
  $hh = [int]$At.Split(':')[0]; $mm = [int]$At.Split(':')[1]
  $runAt = Get-Date -Hour $hh -Minute $mm -Second 0  # DateTime

  $py = Get-Python
  $absConfig = (Resolve-Path $ConfigPath).Path
  $pyQ = '"' + $py + '"'
  $cfgQ = '"' + $absConfig + '"'
  $cmdLine = $pyQ + ' -m ctrader plan --config ' + $cfgQ + ' --paper'
  if ($AssumeYes){ $cmdLine = 'set CTRADER_ASSUME_YES=1 && ' + $cmdLine }

  # Use cmd.exe to set env (if needed) then run python
  $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ("/c " + $cmdLine)
  $trigger = New-ScheduledTaskTrigger -Daily -At $runAt
  $taskName = "ctrader-paper-daily"
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "Daily paper rebalance for ctrader" -Force | Out-Null
  Ok "Scheduled task '$taskName' at $At daily"
}

function Run-Quality(){
  try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch { }
  Write-Host ">> pytest" -ForegroundColor Magenta
  & pytest -q
  if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }
  Ok "Quality checks passed"
}

# --- Entry flow ---
if ($DiscordWebhook){
  Ensure-EnvKV "DISCORD_WEBHOOK_URL" $DiscordWebhook
  if ($TestNotify){ Notify-Discord "ctrader: webhook wired ✅ ($(Get-Date -Format s))" }
} elseif ($TestNotify){
  Warn "-TestNotify ignored because -DiscordWebhook not provided."
}

if ($DryRun -and $Paper){ Warn "Both -DryRun and -Paper specified; running PAPER."; $Paper = $true }
if ($Paper){ Run-Plan -Paper:$true -AssumeYes:$AssumeYes } elseif ($DryRun){ Run-Plan }

if ($ScheduleDailyPaper){ Schedule-DailyPaper -At $DailyTime -AssumeYes:$AssumeYes }

if ($PrecommitAndTest){ Run-Quality }

Ok "Done."
'@
SaveUtf8LF ".\tools\operate-ctrader.ps1" $operate

# --- Optional: run hooks/tests to keep repo green ---
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch {}
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# --- Commit/push if asked ---
if ($CommitAndPush){
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)){
    git commit -m "fix(ops): Discord notify quoting + scheduler -At DateTime in operate-ctrader.ps1"
    git push
    OK "Committed and pushed."
  } else {
    INFO "No changes to commit."
  }
}

OK "All improvements applied."
