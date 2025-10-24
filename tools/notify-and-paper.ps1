param(
  [string]$Config = ".\configs\example.yml",
  [switch]$Paper = $true,
  [switch]$AssumeYes = $true,
  [string]$Webhook # if omitted, read from .env (DISCORD_WEBHOOK_URL=...)
,
  [switch]\
)













# === BEGIN: RUN CONTEXT, LOGGING, DISCORD PINGS ===
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
try { . (Join-Path $ScriptRoot 'common-webhook.ps1') 2>$null } catch {}
if (Get-Command Resolve-DiscordWebhook -ErrorAction SilentlyContinue) { $DiscordWebhook = Resolve-DiscordWebhook -Explicit $DiscordWebhook }

# Quiet mode via env (no param needed)
if (-not $PSBoundParameters.ContainsKey('NoDiscord') -and -not $NoDiscord) {
  $NoDiscord = @(
    [Environment]::GetEnvironmentVariable('NO_DISCORD','Process'),
    [Environment]::GetEnvironmentVariable('NO_DISCORD','User'),
    [Environment]::GetEnvironmentVariable('NO_DISCORD','Machine')
  ) -contains '1'
}

function Send-DiscordInfo { param([string]$Text) try {
  if (-not $NoDiscord -and $DiscordWebhook) { Invoke-Discord -WebhookUrl $DiscordWebhook -Text $Text | Out-Null }
} catch {} }

# Logs dir + fallback + rotation
try {
  $logDir = Join-Path (Split-Path -Parent $ScriptRoot) 'logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
} catch {
  $logDir = Join-Path $env:TEMP 'ctrader-logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
}
try {
  Get-ChildItem $logDir -File -Filter 'paper-*.log' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 50 | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

$__stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$__log   = Join-Path $logDir "paper-$__stamp.log"
try { Start-Transcript -Path $__log -Append -ErrorAction SilentlyContinue | Out-Null } catch { try { New-Item -ItemType File -Force -Path $__log | Out-Null } catch {} }

# Single-instance guard (still harmless with Task's IgnoreNew)
$__mutexName = 'Global\ctrader-paper'
$__mutex = $null; $__gotLock = $false
try { $__mutex = New-Object System.Threading.Mutex($false, $__mutexName); $__gotLock = $__mutex.WaitOne(0) } catch {}
if (-not $__gotLock) {
  Write-Host "[SKIP] Another instance is running. Exiting."
  Send-DiscordInfo "ðŸŸ¨ ctrader paper run SKIPPED (another instance running)."
  try { Stop-Transcript | Out-Null } catch {}
  exit 2
}

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
Send-DiscordInfo ("ðŸŸ¦ ctrader paper run STARTED on {0} (`"{1}`")" -f $env:COMPUTERNAME, $__stamp)
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
