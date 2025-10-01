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
$ErrorActionPreference = "Stop"

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Get-Python(){
  $p1 = Join-Path $PSScriptRoot "..\.venv\Scripts\python.exe"
  if (Test-Path $p1) { return (Resolve-Path $p1).Path }
  return "python"
}

function Write-Utf8NoBom([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $normalized = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Ensure-EnvKV([string]$Key,[string]$Value){
  $envPath = ".\.env"
  $cur = ""
  if (Test-Path -LiteralPath $envPath){ $cur = Get-Content -LiteralPath $envPath -Raw }
  if ($cur -match "^\s*$([regex]::Escape($Key))\s*="){
    $new = [regex]::Replace($cur, "^\s*$([regex]::Escape($Key))\s*=.*$", "$Key=$Value", "Multiline")
    Write-Utf8NoBom $envPath $new
    Ok "Updated $Key in .env"
  } else {
    if ($cur -and -not $cur.EndsWith("`n")){ $cur += "`n" }
    Write-Utf8NoBom $envPath ($cur + "$Key=$Value`n")
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
})" -f $LASTEXITCODE) }
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  Ok "Sent Discord notification"
}

function Schedule-DailyPaper([string]$At,[switch]$AssumeYes){
  if ($At -notmatch "^\d{2}:\d{2}$"){ throw "DailyTime must be HH:MM (e.g., 09:00)" }
  $hh = [int]$At.Split(":")[0]; $mm = [int]$At.Split(":")[1]
  $runAt = Get-Date -Hour $hh -Minute $mm -Second 0

  $py = Get-Python
  $absConfig = (Resolve-Path $ConfigPath).Path
  $pyQ = '"' + $py + '"'
  $cfgQ = '"' + $absConfig + '"'
  $cmdLine = $pyQ + " -m ctrader plan --config " + $cfgQ + " --paper"
  if ($AssumeYes){ $cmdLine = "set CTRADER_ASSUME_YES=1 && " + $cmdLine }

  $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ("/c " + $cmdLine)
  $trigger = New-ScheduledTaskTrigger -Daily -At $runAt
  $taskName = "ctrader-paper-daily"
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "Daily paper rebalance for ctrader" -Force | Out-Null
  Ok ("Scheduled task '{0}' at {1} daily" -f $taskName,$At)
}

function Run-Quality(){
  try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch { }
  Write-Host ">> pytest" -ForegroundColor Magenta
  & pytest -q
  if ($LASTEXITCODE -ne 0) { throw ("pytest failed ({0})" -f $LASTEXITCODE) }
  Ok "Quality checks passed"
}

# Entry
if ($DiscordWebhook){
  Ensure-EnvKV "DISCORD_WEBHOOK_URL" $DiscordWebhook
  if ($TestNotify){ Notify-Discord "ctrader webhook test" }
} elseif ($TestNotify){
  Warn "-TestNotify ignored because -DiscordWebhook not provided."
}

if ($DryRun -and $Paper){ Warn "Both -DryRun and -Paper specified; running PAPER."; $Paper = $true }
if ($Paper){ Run-Plan -Paper:$true -AssumeYes:$AssumeYes } elseif ($DryRun){ Run-Plan }

if ($ScheduleDailyPaper){ Schedule-DailyPaper -At $DailyTime -AssumeYes:$AssumeYes }

if ($PrecommitAndTest){ Run-Quality }

Ok "Done."