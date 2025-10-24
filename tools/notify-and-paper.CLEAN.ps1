# === LOGGING: start transcript to tools\..\logs with timestamp ===
try {
  $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
  if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
  $logDir = Join-Path $scriptRoot '..\logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
  $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
  Start-Transcript -Path (Join-Path $logDir "paper-$stamp.log") -Append -ErrorAction SilentlyContinue | Out-Null
} catch {
  Write-Host "[WARN] Logging setup failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
}
# === /LOGGING ===
# tools/notify-and-paper.ps1
# Runs ctrader plan (optionally --paper) and posts the output to your Discord webhook.

[CmdletBinding()]
param(
  [string]$Config = ".\configs\example.yml",
  [switch]$Paper = $true,
  [switch]$AssumeYes = $true,
  [string]$Webhook # if omitted, read from .env (DISCORD_WEBHOOK_URL=...)
)













# === BEGIN: RUN CONTEXT, LOGGING, DISCORD PINGS ===
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
try { . (Join-Path $ScriptRoot 'common-webhook.ps1') 2>$null } catch {}
if (Get-Command Resolve-DiscordWebhook -ErrorAction SilentlyContinue) { $DiscordWebhook = Resolve-DiscordWebhook -Explicit $DiscordWebhook }
function Send-DiscordInfo { param([string]$Text) try { if ($DiscordWebhook) { Invoke-Discord -WebhookUrl $DiscordWebhook -Text $Text | Out-Null } } catch {} }
try {
  $logDir = Join-Path (Split-Path -Parent $ScriptRoot) 'logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
} catch {
  $logDir = Join-Path $env:TEMP 'ctrader-logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
}
try {
  Get-ChildItem $logDir -File -Filter 'paper-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 50 | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
$__stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$__log   = Join-Path $logDir "paper-$__stamp.log"
try { Start-Transcript -Path $__log -Append -ErrorAction SilentlyContinue | Out-Null } catch { try { New-Item -ItemType File -Force -Path $__log | Out-Null } catch {} }
$__sw = [System.Diagnostics.Stopwatch]::StartNew()
Send-DiscordInfo ("🟦 ctrader paper run STARTED on {0} (`"{1}`")" -f $env:COMPUTERNAME, $__stamp)
# === END: RUN CONTEXT, LOGGING, DISCORD PINGS ===
$ErrorActionPreference = "Stop"

function Read-DotEnvValue([string]$Key){
  if(-not (Test-Path ".\.env")){ return $null }
  $line = Select-String -Path ".\.env" -Pattern ("^\s*{0}\s*=\s*(.+)$" -f [regex]::Escape($Key)) -SimpleMatch:$false -AllMatches | Select-Object -First 1
  if(-not $line){ return $null }
  $m = [regex]::Match($line.Line, "^\s*{0}\s*=\s*(.+)$" -f [regex]::Escape($Key))
  if($m.Success){ return $m.Groups[1].Value.Trim() } else { return $null }
}

function Get-Python(){
  $venvPy = Join-Path (Resolve-Path ".").Path ".venv\Scripts\python.exe"
  if(Test-Path $venvPy){ return $venvPy }
  return "python"
}

function Notify-Discord([string]$Url,[string]$Content){
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $payload = @{ content = $Content } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body $payload | Out-Null
}

# Resolve webhook
if(-not $Webhook){
  $Webhook = Read-DotEnvValue "DISCORD_WEBHOOK_URL"
  if(-not $Webhook){ throw "No webhook provided and DISCORD_WEBHOOK_URL not found in .env" }
}

# Build command line
$py = Get-Python
$absConfig = (Resolve-Path $Config).Path
$cmd = "$py -m ctrader plan --config `"$absConfig`""
if($Paper){ $cmd += " --paper" }
$env:CTRADER_ASSUME_YES = $(if($AssumeYes){ "1" } else { "" })

# Run the plan
Write-Host "[INFO] Running: $cmd"
$out = & $py -m ctrader plan --config $absConfig @(@{Name="--paper";Value="--paper"}[$Paper.IsPresent]).Value
if($LASTEXITCODE -ne 0){ throw "ctrader plan failed ($LASTEXITCODE)" }

# Compose message (wrap in code block)
$msg = "ctrader plan result:`n``````" + "`n" + ($out -join "`n") + "`n" + "``````"
Notify-Discord -Url $Webhook -Content $msg
Write-Host "[ OK ] Posted plan result to Discord"

# === BEGIN: RUN FOOTER ===
try {
  $__sw.Stop()
  $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 0 }
  $status   = if ($exitCode -eq 0) { "✅ SUCCESS" } else { "🟥 FAIL ($exitCode)" }
  Send-DiscordInfo ("{0} ctrader paper run FINISHED in {1:mm\:ss}. Log: {2}" -f $status, $__sw.Elapsed, $__log)
} catch {}
try { Stop-Transcript | Out-Null } catch {}
# === END: RUN FOOTER ===
