param(
  [string]$Path = ".\ctrader",
  [int]$DebounceMs = 350
)

$ErrorActionPreference = "Stop"

function Run-Once(){
  Write-Host ('[RUN ] python -m ctrader') -ForegroundColor Cyan
  & python -m ctrader
}

if (-not (Test-Path -LiteralPath $Path)) { $Path = "." }

$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = (Resolve-Path $Path)
$fsw.Filter = "*.py"
$fsw.IncludeSubdirectories = $true
$fsw.EnableRaisingEvents = $true

$timer = New-Object System.Timers.Timer
$timer.Interval = $DebounceMs
$timer.AutoReset = $false
$script:pending = $false

$action = {
  $script:pending = $true
  $null = $timer.Stop()
  $null = $timer.Start()
}

$created = Register-ObjectEvent $fsw Created -Action $action
$changed = Register-ObjectEvent $fsw Changed -Action $action
$deleted = Register-ObjectEvent $fsw Deleted -Action $action
$renamed = Register-ObjectEvent $fsw Renamed -Action $action

$onTick = Register-ObjectEvent $timer Elapsed -Action {
  if ($script:pending) {
    $script:pending = $false
    try { Run-Once } catch { Write-Host ('[ERR ] ' + $_.Exception.Message) -ForegroundColor Red }
  }
}

Write-Host ('[WATCH] Watching ' + $fsw.Path + ' (Ctrl+C to stop)...') -ForegroundColor Green
try {
  Run-Once
  while ($true) { Start-Sleep -Seconds 1 }
} finally {
  Unregister-Event -SourceIdentifier $created.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $changed.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $deleted.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $renamed.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $onTick.Name -ErrorAction SilentlyContinue
  $fsw.Dispose()
  $timer.Dispose()
}