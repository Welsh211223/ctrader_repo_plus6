param(
  [string]$Repo = (Get-Location).Path,
  [bool]  $CreateTask = $false,    # set $true in Admin shell to (re)create SYSTEM task
  [bool]  $RunOnce    = $false,    # set $true to run wrapper once immediately
  [int]   $Live       = 0,
  [double]$MinNotional = 25,
  [double]$ConservativeDailyCapAUD = 100,
  [double]$AggressiveDailyCapAUD   = 50
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  try {
    $cur = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prn = New-Object Security.Principal.WindowsPrincipal($cur)
    return $prn.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

$Repo     = (Resolve-Path $Repo).Path
$Tools    = Join-Path $Repo 'tools'
$LogsDir  = Join-Path $Repo 'logs'
$Runner   = Join-Path $Tools 'run-both-pools.ps1'
$Wrapper  = Join-Path $Tools 'run-both-pools.scheduled.ps1'
$Shim     = Join-Path $Tools 'run-both-pools.scheduled.cmd'
$TodayLog = Join-Path $LogsDir ("run-both-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

$null = New-Item -ItemType Directory -Force -Path $Tools,$LogsDir

# Shim
$shimBody  = "@echo off`r`n"
$shimBody += "setlocal`r`n"
$shimBody += "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0run-both-pools.scheduled.ps1`" %*`r`n"
$shimBody += "exit /b %ERRORLEVEL%`r`n"
Set-Content -LiteralPath $Shim -Encoding ASCII -Value $shimBody

# Wrapper (single-quoted here-string; no expansion)
$wrapperBody = @'
[CmdletBinding()]
param(
  [int]   $Live = 0,
  [double]$MinNotional = 25,
  [double]$ConservativeDailyCapAUD = 100,
  [double]$AggressiveDailyCapAUD   = 50
)

$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $here '..')).Path
$runner   = Join-Path $repoRoot 'tools\run-both-pools.ps1'
$logsDir  = Join-Path $repoRoot 'logs'
$log      = Join-Path $logsDir ("run-both-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$venvAct  = Join-Path $repoRoot '.venv\Scripts\Activate.ps1'

if (-not (Test-Path -LiteralPath $runner)) { throw "Runner not found: $runner" }
$null = New-Item -ItemType Directory -Force -Path $logsDir

try {
  Set-Location -LiteralPath $repoRoot
  [System.Environment]::CurrentDirectory = $repoRoot
} catch {
  throw "Failed to set working directory to $repoRoot; $($_.Exception.Message)"
}

Get-ChildItem -LiteralPath $logsDir -Filter 'run-both-*.log' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

$mtxName = 'Global\ctrader_pools_mutex'
$mtx     = New-Object System.Threading.Mutex($false, $mtxName)
$have    = $mtx.WaitOne([TimeSpan]::FromMinutes(4))

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
"==== $stamp ====" | Out-File -FilePath $log -Append -Encoding UTF8
"RUN   : $runner `"-Live $Live -MinNotional $MinNotional -ConservativeDailyCapAUD $ConservativeDailyCapAUD -AggressiveDailyCapAUD $AggressiveDailyCapAUD`"" | Out-File -FilePath $log -Append -Encoding UTF8
"WHO   : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" | Out-File -FilePath $log -Append -Encoding UTF8
"USER  : $env:USERNAME"                                                     | Out-File -FilePath $log -Append -Encoding UTF8
"CWD   : $PWD"                                                              | Out-File -FilePath $log -Append -Encoding UTF8
"PSVER : $($PSVersionTable.PSVersion)"                                      | Out-File -FilePath $log -Append -Encoding UTF8

if (-not $have) {
  "SKIP  : Another run is already in progress (mutex $mtxName)" | Out-File -FilePath $log -Append -Encoding UTF8
  "EXIT  : 0" | Out-File -FilePath $log -Append -Encoding UTF8
  exit 0
}

try {
  if (Test-Path -LiteralPath $venvAct) {
    try { . $venvAct } catch { "WARN  : venv activation failed: $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding UTF8 }
  }

  try {
    $envFile = Join-Path $repoRoot '.env'
    if (Test-Path -LiteralPath $envFile) {
      $loaded = 0
      Get-Content -LiteralPath $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
          $k = $matches[1].Trim()
          $v = $matches[2].Trim()
          if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) { $v = $v.Substring(1, $v.Length-2) }
          [Environment]::SetEnvironmentVariable($k, $v, 'Process'); $loaded++
        }
      }
      "ENV   : loaded $loaded vars from .env" | Out-File -FilePath $log -Append -Encoding UTF8
    } else {
      "ENV   : no .env found at $envFile" | Out-File -FilePath $log -Append -Encoding UTF8
    }
  } catch {
    ("WARN  : failed to load .env - " + $_.Exception.Message) | Out-File -FilePath $log -Append -Encoding UTF8
  }

  $global:LASTEXITCODE = $null
  $ok = $true
  try {
    & $runner `
      -Live $Live `
      -MinNotional $MinNotional `
      -ConservativeDailyCapAUD $ConservativeDailyCapAUD `
      -AggressiveDailyCapAUD   $AggressiveDailyCapAUD `
      2>&1 | Tee-Object -FilePath $log -Append
    $ok = $?
  } catch {
    ("ERROR : " + $_.Exception.ToString()) | Out-File -FilePath $log -Append -Encoding UTF8
    $ok = $false
  }

  if ($null -ne $LASTEXITCODE) { $last = [int]$LASTEXITCODE } else { $last = ($ok ? 0 : 1) }
  "EXIT  : $last" | Out-File -FilePath $log -Append -Encoding UTF8
  exit $last
}
finally {
  if ($mtx) { $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose() }
}
