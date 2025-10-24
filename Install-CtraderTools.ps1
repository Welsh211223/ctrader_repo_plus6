<#  Install-CtraderTools.ps1
    Purpose: make ctrader.tools reliable to load every session and ensure clean exports (incl. Get-CtraderTaskRuns2)
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = (Get-Location).Path,
  [ValidateSet('Profile','PSModulePath','Both','None')]
  [string]$Persist = 'Profile',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[ctrader.tools] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[ctrader.tools] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[ctrader.tools] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[ctrader.tools] $m" -ForegroundColor Red }

try {
  $toolsDir = Join-Path $RepoRoot 'tools'
  $modPath  = Join-Path $toolsDir 'ctrader.tools.psm1'
  $runs2Src = Join-Path $toolsDir 'Get-CtraderTaskRuns2.ps1'
  if (-not (Test-Path $modPath)) { throw "Module not found: $modPath" }

  # Backup
  $bak = "$modPath.bak-$(Get-Date -f yyyyMMddHHmmss)"
  Copy-Item $modPath $bak -Force
  Info "Backed up module to $bak"

  # Load/patch text
  $text = Get-Content -LiteralPath $modPath -Raw

  # Ensure Get-CtraderTaskRuns2 exists
  if ($text -notmatch '(?m)^\s*function\s+Get-CtraderTaskRuns2\b') {
    if (Test-Path $runs2Src) {
      $func = Get-Content -LiteralPath $runs2Src -Raw
    } else {
      # minimal inline fallback
      $func = @"
function Get-CtraderTaskRuns2 {
  [CmdletBinding()]
  param(
    [string]$TaskName = '\ctrader-paper-daily',
    [int]$Hours = 24,
    [switch]$IncludeExtra,
    [string]$ComputerName
  )
  \$minutes = [math]::Abs(\$Hours) * 60
  \$hist = Show-CtraderTaskHistory -TaskName \$TaskName -Minutes \$minutes -IncludeExtra:\$IncludeExtra -ComputerName \$ComputerName -Raw
  \$prob = Show-CtraderTaskProblems -TaskName \$TaskName -Hours \$Hours -IncludeQueued -ComputerName \$ComputerName -Raw
  \$all  = @(\$hist + \$prob) | Sort-Object TimeCreated
  if (-not \$all) { return }
  \$rxGuid = [regex]'\{[0-9a-fA-F-]{36}\}'
  function Get-XmlField(\$e,[string]\$name){
    try { \$x=[xml]\$e.ToXml(); (\$x.Event.EventData.Data | ? Name -eq \$name | select -First 1 -exp '#text') } catch { \$null }
  }
  \$rows = foreach(\$e in \$all){
    \$id = Get-XmlField \$e 'InstanceId'
    if (-not \$id) { \$id = \$rxGuid.Match(\$e.Message).Value }
    if (-not \$id) { continue }
    [pscustomobject]@{
      InstanceId = \$id; TaskName = (Get-XmlField \$e 'TaskName'); Id = \$e.Id; Time = \$e.TimeCreated;
      Message = \$e.Message; Level = \$e.LevelDisplayName; ResultCode = (Get-XmlField \$e 'ResultCode')
    }
  }
  if (-not \$rows) { return }
  \$rows | Group-Object InstanceId | ForEach-Object {
    \$events = \$_.Group | Sort-Object Time
    \$tn = (\$events | ? TaskName | select -Last 1 -exp TaskName); if (-not \$tn) { \$tn = \$TaskName }
    \$t325 = \$events | ? Id -eq 325 | select -First 1
    \$t110 = \$events | ? Id -eq 110 | select -First 1
    \$t100 = \$events | ? Id -eq 100 | select -First 1
    \$t200 = \$events | ? Id -eq 200 | select -First 1
    \$t129 = \$events | ? Id -eq 129 | select -First 1
    \$t201 = \$events | ? Id -eq 201 | select -Last 1
    \$t102 = \$events | ? Id -eq 102 | select -Last 1
    \$started   = if (\$t100) { \$t100.Time }
    \$completed = if (\$t201) { \$t201.Time } elseif (\$t102) { \$t102.Time }
    \$rc = \$null
    if (\$t201 -and \$t201.ResultCode -ne \$null) { \$tmp = \$t201.ResultCode -as [int]; if (\$tmp -is [int]) { \$rc = \$tmp } }
    if (\$null -eq \$rc -and \$t201) {
      \$m = ([regex]'return code\s+(-?\d+)').Match(\$t201.Message)
      if (\$m.Success) { \$rc = [int]\$m.Groups[1].Value }
    }
    \$duration = if (\$started -and \$completed) { [math]::Round((\$completed-\$started).TotalSeconds,2) }
    \$fails = \$events | ? { \$_.Id -in 101,103,104 }
    \$status = if (\$fails) { 'Failed' }
      elseif (\$completed) { if (\$rc -ne \$null -and \$rc -ne 0) { "Completed (rc=\$rc)" } else { 'Completed' } }
      elseif (\$started) { 'In-Progress/Aborted?' } else { 'Queued/Triggered' }
    [pscustomobject]@{
      TaskName=\$tn; InstanceId=\$_.Name; QueuedAt=\$t325.Time; TriggeredAt=\$t110.Time; StartedAt=\$started;
      ActionAt=\$t200.Time; ProcessAt=\$t129.Time; CompletedAt=\$completed; DurationSec=\$duration;
      ReturnCode=\$rc; Status=\$status; FailCount=(\$fails | measure).Count
    }
  } | Sort-Object @{Expression={
      if (\$_.StartedAt) { \$_.StartedAt } elseif (\$_.TriggeredAt) { \$_.TriggeredAt } elseif (\$_.QueuedAt) { \$_.QueuedAt }
      elseif (\$_.CompletedAt) { \$_.CompletedAt } else { Get-Date 0 }
    }; Descending=\$true}
}
"@
    }
    $text = $text.TrimEnd() + "`r`n`r`n" + $func
    Info "Appended Get-CtraderTaskRuns2 to module"
  }

  # Strip ALL existing Export-ModuleMember lines, then append a clean one
  $text = [regex]::Replace($text,'(?m)^\s*Export-ModuleMember\b.*\r?\n?','')
  $export = @"
`r
Export-ModuleMember -Function @(
  'Show-CtraderTaskHistory',
  'Show-CtraderTaskProblems',
  'Get-CtraderTaskSummary',
  'Get-CtraderTaskRollup',
  'Watch-CtraderTask',
  'Get-CtraderTaskRuns',
  'Get-CtraderTaskRuns2'
)
"@
  $text = $text.TrimEnd() + $export

  # Quick syntax check
  $null=$null; $tokens=$null; $ast=$null; $errs=$null
  [System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errs) | Out-Null
  if ($errs -and -not $Force) { throw "Parser reported errors. Use -Force to write anyway. First error: $($errs[0].Message)" }

  # Write module
  Set-Content -LiteralPath $modPath -Value $text -Encoding UTF8
  Ok "Module file updated"

  # Import by explicit path
  Remove-Module ctrader.tools -ErrorAction SilentlyContinue
  Import-Module $modPath -Force -Scope Global
  Ok "Imported module: $modPath"

  # Persistence options
  if ($Persist -in 'PSModulePath','Both') {
    $toolsDirResolved = (Resolve-Path $toolsDir).Path
    if ($env:PSModulePath -notlike "*$toolsDirResolved*") {
      $newPath = "$toolsDirResolved;$env:PSModulePath"
      [Environment]::SetEnvironmentVariable('PSModulePath',$newPath,'User')
      Ok "Added tools dir to User PSModulePath"
    } else { Info "Tools dir already in PSModulePath" }
  }
  if ($Persist -in 'Profile','Both') {
    $line = 'Import-Module "$((Resolve-Path ''./tools/ctrader.tools.psm1'').Path)" -Force'
    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
    $profileText = Get-Content $PROFILE -Raw
    if ($profileText -notmatch [regex]::Escape($line)) {
      Add-Content -Path $PROFILE -Value $line
      Ok "Added Import-Module line to profile: $PROFILE"
    } else { Info "Profile already imports module" }
  }

  # Show exports
  $exports = (Get-Module ctrader.tools).ExportedFunctions.Keys
  Ok ("Exports: " + ($exports -join ', '))
  Ok "Done."
}
catch {
  Fail $_.Exception.Message
  if (-not $Force) { throw }
}
