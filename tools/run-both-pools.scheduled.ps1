param(
  [switch]$Live,
  [decimal]$MinNotional = 100,
  [decimal]$ConservativeDailyCapAUD = 100,
  [decimal]$AggressiveDailyCapAUD   = 300
)

$ErrorActionPreference = "Stop"

# --- Resolve paths
$me     = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$root   = Split-Path -Parent (Split-Path -Parent $me)
$tools  = Join-Path $root "tools"
$runner = Join-Path $tools "operate-ctrader.ps1"

# --- Force working dirs (PowerShell + .NET)
[System.IO.Directory]::SetCurrentDirectory($root)
Set-Location -LiteralPath $root

# --- Logs
$logDir = Join-Path $root "out"
New-Item $logDir -ItemType Directory -Force | Out-Null
$log = Join-Path $logDir "run-both-pools.log"
$discordLog = Join-Path $logDir "discord.log"

# Rotate if >5MB
if (Test-Path $log -PathType Leaf) {
  if ((Get-Item $log).Length -gt 5MB) {
    Copy-Item $log "$($log).bak" -Force
    Clear-Content $log
  }
}

"START : $(Get-Date -Format s)" | Out-File -FilePath $log -Append -Encoding UTF8
"DIRS  : PS=$((Get-Location).Path) NET=$([Environment]::CurrentDirectory)" | Out-File -FilePath $log -Append -Encoding UTF8

# --- Minimal .env loader (just DISCORD_WEBHOOK_URL)
try {
  $envPath = Join-Path $root ".env"
  if (Test-Path $envPath) {
    (Get-Content $envPath | Where-Object { $_ -match '^\s*DISCORD_WEBHOOK_URL\s*=' }) | ForEach-Object {
      $v = $_ -replace '^\s*DISCORD_WEBHOOK_URL\s*=\s*', ''
      if (-not [string]::IsNullOrWhiteSpace($v)) { $env:DISCORD_WEBHOOK_URL = $v.Trim() }
    }
  }
} catch {}

# --- Discord helper
function Send-Discord {
  param(
    [Parameter(Mandatory)][string]$Content,
    [string]$Webhook = $env:DISCORD_WEBHOOK_URL,
    [int]$Retries = 3
  )
  if ([string]::IsNullOrWhiteSpace($Webhook)) { return }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  $payload = @{ content = $Content } | ConvertTo-Json -Compress
  for($i=1; $i -le $Retries; $i++){
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Webhook `
           -ContentType 'application/json' -Body $payload -TimeoutSec 10
      "DISCORD OK: try=$i status=$($r.StatusCode)" | Out-File -FilePath $discordLog -Append -Encoding UTF8
      return
    } catch {
      "DISCORD FAIL: try=$i err=$(param(
  [switch]$Live,
  [decimal]$MinNotional = 100,
  [decimal]$ConservativeDailyCapAUD = 100,
  [decimal]$AggressiveDailyCapAUD   = 300
)

$ErrorActionPreference = "Stop"

# --- Resolve paths
$me     = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$root   = Split-Path -Parent (Split-Path -Parent $me)
$tools  = Join-Path $root "tools"
$runner = Join-Path $tools "operate-ctrader.ps1"

# --- Force working dirs (PowerShell + .NET)
[System.IO.Directory]::SetCurrentDirectory($root)
Set-Location -LiteralPath $root

# --- Logs
$logDir = Join-Path $root "out"
New-Item $logDir -ItemType Directory -Force | Out-Null
$log = Join-Path $logDir "run-both-pools.log"
$discordLog = Join-Path $logDir "discord.log"

# Rotate if >5MB
if (Test-Path $log -PathType Leaf) {
  if ((Get-Item $log).Length -gt 5MB) {
    Copy-Item $log "$($log).bak" -Force
    Clear-Content $log
  }
}

"START : $(Get-Date -Format s)" | Out-File -FilePath $log -Append -Encoding UTF8
"DIRS  : PS=$((Get-Location).Path) NET=$([Environment]::CurrentDirectory)" | Out-File -FilePath $log -Append -Encoding UTF8

# --- Minimal .env loader (just DISCORD_WEBHOOK_URL)
try {
  $envPath = Join-Path $root ".env"
  if (Test-Path $envPath) {
    (Get-Content $envPath | Where-Object { $_ -match '^\s*DISCORD_WEBHOOK_URL\s*=' }) | ForEach-Object {
      $v = $_ -replace '^\s*DISCORD_WEBHOOK_URL\s*=\s*', ''
      if (-not [string]::IsNullOrWhiteSpace($v)) { $env:DISCORD_WEBHOOK_URL = $v.Trim() }
    }
  }
} catch {}

# --- Discord helper
function Send-Discord {
  param(
    [Parameter(Mandatory)][string]$Content,
    [string]$Webhook = $env:DISCORD_WEBHOOK_URL,
    [int]$Retries = 3
  )
  if ([string]::IsNullOrWhiteSpace($Webhook)) { return }
  $payload = @{ content = $Content } | ConvertTo-Json -Compress
  for($i=1; $i -le $Retries; $i++){
    try {
      Invoke-RestMethod -Method Post -Uri $Webhook -ContentType 'application/json' -Body $payload -TimeoutSec 10
      return
    } catch {
      Start-Sleep -Seconds ([Math]::Min(5 * $i, 15))
    }
  }
}

# Notify START (best-effort)
try { "DISCORD: start" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content ":green_circle: CTRADER START $(Get-Date -Format s)" } catch {}

# --- Single-instance mutex
try { $mtx = [System.Threading.Mutex]::new($false, 'Global\ctrader_runner_mutex') } catch { $mtx = [System.Threading.Mutex]::new($false, 'Local\ctrader_runner_mutex') }
if (-not $mtx.WaitOne(0,$false)) {
  "Another instance is running; exiting." | Out-File -FilePath $log -Append -Encoding UTF8
  exit 2
}

try {
  $global:LASTEXITCODE = $null
  $ok = $true

  try {
    & $runner `
      -Live:$Live `
      -MinNotional $MinNotional `
      -ConservativeDailyCapAUD $ConservativeDailyCapAUD `
      -AggressiveDailyCapAUD   $AggressiveDailyCapAUD `
      2>&1 | Tee-Object -FilePath $log -Append
    $ok = $?
  }
  catch {
    ("ERROR : " + $_.Exception.ToString()) | Out-File -FilePath $log -Append -Encoding UTF8
    try { "DISCORD: error" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content (":red_circle: CTRADER ERROR: " + $_.Exception.Message) } catch {}
    $ok = $false
  }

  # --- Paper-trade CSV extraction (only when -Live is OFF)
  if (-not $Live) {
    try {
      $csv = Join-Path $logDir 'paper_trades.csv'
      $rx  = '(?<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}).*?(?<side>\bBUY\b|\bSELL\b|\bLONG\b|\bSHORT\b).*?(?<sym>[A-Z]{3,}[-_/]?[A-Z]{3,})?.*?(?<qty>\b\d+(\.\d+)?\b)?'
      $rows = @()
      if (Test-Path $log) {
        Get-Content $log | ForEach-Object {
          if ($_ -match $rx) {
            $rows += [pscustomobject]@{
              Timestamp = $Matches.ts
              Side      = $Matches.side
              Symbol    = if ($Matches.sym) { $Matches.sym } else { '' }
              Qty       = if ($Matches.qty) { $Matches.qty } else { '' }
              Line      = $_
            }
          }
        }
      }
      if ($rows.Count -gt 0) {
        if (Test-Path $csv) { $rows | Export-Csv -Path $csv -NoTypeInformation -Append }
        else { $rows | Export-Csv -Path $csv -NoTypeInformation }
      }
    } catch { }
  }

  if ($null -ne $LASTEXITCODE) { $last = [int]$LASTEXITCODE }
  elseif ($ok) { $last = 0 } else { $last = 1 }

  "EXIT  : $last" | Out-File -FilePath $log -Append -Encoding UTF8
  try { "DISCORD: exit" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content (":white_check_mark: CTRADER EXIT = $last @ $(Get-Date -Format s)") } catch {}
  exit $last
}
finally {
  if ($mtx) { $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose() }
}
.Exception.Message)" | Out-File -FilePath $discordLog -Append -Encoding UTF8
      Start-Sleep -Seconds ([Math]::Min(5 * $i, 15))
    }
  }
}
  $payload = @{ content = $Content } | ConvertTo-Json -Compress
  for($i=1; $i -le $Retries; $i++){
    try {
      Invoke-RestMethod -Method Post -Uri $Webhook -ContentType 'application/json' -Body $payload -TimeoutSec 10
      return
    } catch {
      Start-Sleep -Seconds ([Math]::Min(5 * $i, 15))
    }
  }
}

# Notify START (best-effort)
try { "DISCORD: start" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content ":green_circle: CTRADER START $(Get-Date -Format s)" } catch {}

# --- Single-instance mutex
try { $mtx = [System.Threading.Mutex]::new($false, 'Global\ctrader_runner_mutex') } catch { $mtx = [System.Threading.Mutex]::new($false, 'Local\ctrader_runner_mutex') }
if (-not $mtx.WaitOne(0,$false)) {
  "Another instance is running; exiting." | Out-File -FilePath $log -Append -Encoding UTF8
  exit 2
}

try {
  $global:LASTEXITCODE = $null
  $ok = $true

  try {
    & $runner `
      -Live:$Live `
      -MinNotional $MinNotional `
      -ConservativeDailyCapAUD $ConservativeDailyCapAUD `
      -AggressiveDailyCapAUD   $AggressiveDailyCapAUD `
      2>&1 | Tee-Object -FilePath $log -Append
    $ok = $?
  }
  catch {
    ("ERROR : " + $_.Exception.ToString()) | Out-File -FilePath $log -Append -Encoding UTF8
    try { "DISCORD: error" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content (":red_circle: CTRADER ERROR: " + $_.Exception.Message) } catch {}
    $ok = $false
  }

  # --- Paper-trade CSV extraction (only when -Live is OFF)
  if (-not $Live) {
    try {
      $csv = Join-Path $logDir 'paper_trades.csv'
      $rx  = '(?<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}).*?(?<side>\bBUY\b|\bSELL\b|\bLONG\b|\bSHORT\b).*?(?<sym>[A-Z]{3,}[-_/]?[A-Z]{3,})?.*?(?<qty>\b\d+(\.\d+)?\b)?'
      $rows = @()
      if (Test-Path $log) {
        Get-Content $log | ForEach-Object {
          if ($_ -match $rx) {
            $rows += [pscustomobject]@{
              Timestamp = $Matches.ts
              Side      = $Matches.side
              Symbol    = if ($Matches.sym) { $Matches.sym } else { '' }
              Qty       = if ($Matches.qty) { $Matches.qty } else { '' }
              Line      = $_
            }
          }
        }
      }
      if ($rows.Count -gt 0) {
        if (Test-Path $csv) { $rows | Export-Csv -Path $csv -NoTypeInformation -Append }
        else { $rows | Export-Csv -Path $csv -NoTypeInformation }
      }
    } catch { }
  }

  if ($null -ne $LASTEXITCODE) { $last = [int]$LASTEXITCODE }
  elseif ($ok) { $last = 0 } else { $last = 1 }

  "EXIT  : $last" | Out-File -FilePath $log -Append -Encoding UTF8
  try { "DISCORD: exit" | Out-File -FilePath $discordLog -Append -Encoding UTF8; Send-Discord -Content (":white_check_mark: CTRADER EXIT = $last @ $(Get-Date -Format s)") } catch {}
  exit $last
}
finally {
  if ($mtx) { $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose() }
}
