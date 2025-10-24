param(
  [switch]$DryRun,
  [switch]$Paper,
  [switch]$AssumeYes,
  [string]$ConfigPath = ".\configs\example.yml",
  [string]$DiscordWebhook,
  [switch]$TestNotify,
  [switch]$ScheduleDailyPaper,
  [string]$DailyTime = "09:00",
  [switch]$PrecommitAndTest
)

. "$PSScriptRoot\common-webhook.ps1"
$DiscordWebhook = Resolve-DiscordWebhook -Explicit $DiscordWebhook
$ErrorActionPreference = "Stop"

function Ok($m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err($m){ Write-Host "[ERR ] $m" -ForegroundColor Red }

function Write-Utf8NoBom([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $norm = $Content -replace "`r`n","`n"; $norm = $norm -replace "`r","`n"
  [IO.File]::WriteAllText($Path,$norm,$enc)
}

function Ensure-EnvKV([string]$Key,[string]$Value){
  $envPath = ".\.env"
  $txt = if (Test-Path $envPath) { Get-Content $envPath -Raw } else { "" }
  if ($txt -match ("^" + [regex]::Escape($Key) + "=")){
    $txt = [regex]::Replace($txt, ("^" + [regex]::Escape($Key) + "=.*$"), "$Key=$Value", 'Multiline')
    Write-Utf8NoBom $envPath $txt
  } else {
    Add-Content $envPath "`n$Key=$Value"
  }
  Ok "Added $Key to .env"
}

function Get-Python(){
  $p = Join-Path $PWD ".venv\Scripts\python.exe"
  if (Test-Path $p) { return $p }
  return "python"
}

function Notify-Discord([string]$Message){
  $url = $null
  if ($DiscordWebhook) { $url = $DiscordWebhook }
  if (-not $url -and (Test-Path ".\.env")){
    $m = Select-String -Path ".\.env" -Pattern '^DISCORD_WEBHOOK_URL=(.+)$' -AllMatches
    if ($m.Matches.Count -gt 0){ $url = $m.Matches[0].Groups[1].Value.Trim() }
  }
  if (-not $url) { $url = $env:DISCORD_WEBHOOK_URL }
  if (-not $url) { Warn "DISCORD_WEBHOOK_URL not set"; return }

  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $body = @{ content = $Message } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body $body | Out-Null
  Ok "Sent Discord notification"
}

function Run-Plan([switch]$Paper,[switch]$AssumeYes){
  $py = Get-Python
  $cfg = (Resolve-Path $ConfigPath).Path
  $args = @("-m","ctrader","plan","--config",$cfg)
  if ($Paper){ $args += "--paper" }
  Write-Host ("[INFO] Running: {0} {1}" -f $py, ($args -join " "))

  if ($AssumeYes){ $env:CTRADER_ASSUME_YES = "1" }
  & $py @args
  $code = $LASTEXITCODE
  if ($AssumeYes){ Remove-Item Env:\CTRADER_ASSUME_YES -ErrorAction SilentlyContinue }
  if ($code -ne 0){ throw ("plan failed ({0})" -f $code) }

  if ($Paper -and (Test-Path "paper_trades.csv")){
    Ok "Paper fills written to paper_trades.csv"
  }
}

function Schedule-DailyPaper([string]$At,[switch]$AssumeYes){
  if ($At -notmatch '^\d{2}:\d{2}$'){ throw "DailyTime must be HH:MM (e.g., 09:00)" }
  $hh = [int]$At.Split(":")[0]; $mm = [int]$At.Split(":")[1]
  $runAt = Get-Date -Hour $hh -Minute $mm -Second 0

  $py = Get-Python
  $cfg = (Resolve-Path $ConfigPath).Path
  $log = (Join-Path $PWD "ctrader-paper.log")

  # PowerShell one-liner inside the task (avoid cmd &&)
  $one = "$env:CTRADER_ASSUME_YES='1'; & '$py' -m ctrader plan --config '$cfg' --paper *>> '$log'"

  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-NoProfile -WindowStyle Hidden -Command " + $one)
  $trigger = New-ScheduledTaskTrigger -Daily -At $runAt
  Register-ScheduledTask -TaskName "ctrader-paper-daily" -Action $action -Trigger $trigger -Description "Daily paper rebalance for ctrader" -Force | Out-Null
  Ok ("Scheduled task 'ctrader-paper-daily' at {0} daily" -f $At)
}

function Run-Quality(){
  try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch {}
  Write-Host ">> pytest" -ForegroundColor Magenta
  & pytest -q
  if ($LASTEXITCODE -ne 0){ throw ("pytest failed ({0})" -f $LASTEXITCODE) }
  Ok "Quality checks passed"
}

# ---- Entry ----
if ($DiscordWebhook){
  Ensure-EnvKV "DISCORD_WEBHOOK_URL" $DiscordWebhook
  if ($TestNotify){ Notify-Discord "ctrader webhook test" }
} elseif ($TestNotify){
  Warn "-TestNotify ignored because -DiscordWebhook not provided and .env not set."
}

if ($Paper){ Run-Plan -Paper:$true -AssumeYes:$AssumeYes }
elseif ($DryRun){ Run-Plan }

if ($ScheduleDailyPaper){ Schedule-DailyPaper -At $DailyTime -AssumeYes:$AssumeYes }

if ($PrecommitAndTest){ Run-Quality }

Ok "Done."

function Register-CtraderDailyPaper {
  param(
    [string]$ConfigPath = ".\configs\example.yml",
    [string]$At = "09:00",
    [switch]$AssumeYes
  )
  try {
    if (-not (Get-Command Resolve-DiscordWebhook -ErrorAction SilentlyContinue)) {
      . "$PSScriptRoot\common-webhook.ps1"
    }

    $repo   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $cfgAbs = (Resolve-Path $ConfigPath).Path
    $script = Join-Path $repo "tools\notify-and-paper.ps1"

    # Safe concatenation avoids parser issues
    $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -Config "' + $cfgAbs + '" -Paper'
    if ($AssumeYes) { $args += ' -AssumeYes' }

    if ($At -notmatch '^\d{2}:\d{2}$') { throw 'Daily time must be HH:MM (e.g., 09:00)' }
    $hh = [int]($At.Split(':')[0]); $mm = [int]($At.Split(':')[1])
    $runAt = Get-Date -Hour $hh -Minute $mm -Second 0

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args -WorkingDirectory $repo
    $trigger = New-ScheduledTaskTrigger -Daily -At $runAt
    Register-ScheduledTask -TaskName 'ctrader-paper-daily' -Action $action -Trigger $trigger -Description 'Daily paper rebalance (wrapper)' -Force | Out-Null
    Write-Host "[ OK ] Scheduled 'ctrader-paper-daily' at $At" -ForegroundColor Green
  } catch {
    Write-Host "[WARN] Scheduling failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    throw
  }
}
