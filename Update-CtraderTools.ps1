<#
  Update-CtraderTools.ps1
  One-shot updater for tools\ctrader.tools.psm1

  What it does
  ------------
  1) Backs up the module
  2) Adds/upgrades Get-CtraderTaskRuns2 (supports -Since)
  3) Makes Get-CtraderTaskRuns a wrapper over Runs2 (keeps legacy if present)
  4) Normalizes Export-ModuleMember (single line, no backticks)
  5) Optional persistence: PSModulePath + profile import
  6) “Update Organizer” summary of actions
#>

[CmdletBinding()]
param(
  [switch]$PersistToProfile,   # add Import-Module to $PROFILE
  [switch]$PersistPSModulePath,# add tools folder to PSModulePath (User)
  [switch]$Both,               # shorthand for both persistence flags
  [switch]$WhatIfOnly          # show what would happen, don’t write
)

if ($Both) { $PersistToProfile = $true; $PersistPSModulePath = $true }

# --- paths ---
$repoRoot = Get-Location
$mod      = Join-Path $repoRoot 'tools\ctrader.tools.psm1'
if (-not (Test-Path $mod)) { throw "Module not found: $mod" }

# --- update organizer (collect actions) ---
$changes = New-Object System.Collections.Generic.List[string]
$errors  = New-Object System.Collections.Generic.List[string]

function Add-Change([string]$msg){ [void]$changes.Add($msg) }
function Add-Error ([string]$msg){ [void]$errors.Add($msg) }

# --- backup ---
$bak = "$mod.bak-$(Get-Date -Format yyyyMMddHHmmss)"
try {
  if (-not $WhatIfOnly) { Copy-Item $mod $bak -Force }
  Add-Change "Backed up module => $bak"
} catch {
  Add-Error "Backup failed: $($_.Exception.Message)"
}

# --- read module text ---
try {
  $text = Get-Content -LiteralPath $mod -Raw -ErrorAction Stop
} catch {
  throw "Unable to read module: $($_.Exception.Message)"
}

# --- improved Runs2 with -Since ---
$improvedRuns2 = @'
function Get-CtraderTaskRuns2 {
  [CmdletBinding()]
  param(
    [string]$TaskName = '\ctrader-paper-daily',
    [int]   $Hours    = 24,
    [switch]$IncludeExtra,
    [string]$ComputerName,
    [datetime]$Since  # precise start time; overrides -Hours
  )

  $start = if ($Since) { $Since } else { (Get-Date).AddHours(-[math]::Abs($Hours)) }
  $minutes = [int][math]::Ceiling( ((Get-Date) - $start).TotalMinutes )
  $hoursForProblems = [int][math]::Ceiling( ((Get-Date) - $start).TotalHours )

  $hist = Show-CtraderTaskHistory -TaskName $TaskName -Minutes $minutes -IncludeExtra:$IncludeExtra -ComputerName $ComputerName -Raw
  $prob = Show-CtraderTaskProblems -TaskName $TaskName -Hours $hoursForProblems -IncludeQueued -ComputerName $ComputerName -Raw
  $all  = @($hist + $prob) | Sort-Object TimeCreated
  if (-not $all) { return }

  $rxGuid = [regex]'\{[0-9a-fA-F-]{36}\}'
  function Get-XmlField($e,[string]$name){
    try {
      $x = [xml]$e.ToXml()
      ($x.Event.EventData.Data | Where-Object { $_.Name -eq $name } | Select-Object -First 1 -ExpandProperty '#text')
    } catch { $null }
  }

  $rows = foreach($e in $all){
    if ($e.TimeCreated -lt $start) { continue }
    $id = Get-XmlField $e 'InstanceId'
    if (-not $id) { $id = $rxGuid.Match($e.Message).Value }
    if (-not $id) { continue }

    [pscustomobject]@{
      InstanceId = $id
      TaskName   = (Get-XmlField $e 'TaskName')
      Id         = $e.Id
      Time       = $e.TimeCreated
      Message    = $e.Message
      Level      = $e.LevelDisplayName
      ResultCode = (Get-XmlField $e 'ResultCode')
    }
  }
  if (-not $rows) { return }

  $rows | Group-Object InstanceId | ForEach-Object {
    $events = $_.Group | Sort-Object Time
    $tn     = ($events | Where-Object TaskName | Select-Object -Last 1 -ExpandProperty TaskName); if (-not $tn) { $tn = $TaskName }

    $t325 = $events | Where-Object Id -eq 325 | Select-Object -First 1
    $t110 = $events | Where-Object Id -eq 110 | Select-Object -First 1
    $t100 = $events | Where-Object Id -eq 100 | Select-Object -First 1
    $t200 = $events | Where-Object Id -eq 200 | Select-Object -First 1
    $t129 = $events | Where-Object Id -eq 129 | Select-Object -First 1
    $t201 = $events | Where-Object Id -eq 201 | Select-Object -Last 1
    $t102 = $events | Where-Object Id -eq 102 | Select-Object -Last 1

    $started   = if ($t100) { $t100.Time }
    $completed = if     ($t201) { $t201.Time }
                 elseif ($t102) { $t102.Time }

    $rc = $null
    if ($t201 -and $t201.ResultCode -ne $null) {
      $tmp = $t201.ResultCode -as [int]; if ($tmp -is [int]) { $rc = $tmp }
    }
    if ($null -eq $rc -and $t201) {
      $m = ([regex]'return code\s+(-?\d+)').Match($t201.Message)
      if ($m.Success) { $rc = [int]$m.Groups[1].Value }
    }

    $duration = if ($started -and $completed) { [math]::Round( ($completed - $started).TotalSeconds, 2) }

    $fails = $events | Where-Object { $_.Id -in 101,103,104 }
    $status = if     ($fails)     { 'Failed' }
              elseif ($completed) { if ($rc -ne $null -and $rc -ne 0) { "Completed (rc=$rc)" } else { 'Completed' } }
              elseif ($started)   { 'In-Progress/Aborted?' }
              else                 { 'Queued/Triggered' }

    [pscustomobject]@{
      TaskName     = $tn
      InstanceId   = $_.Name
      QueuedAt     = $t325.Time
      TriggeredAt  = $t110.Time
      StartedAt    = $started
      ActionAt     = $t200.Time
      ProcessAt    = $t129.Time
      CompletedAt  = $completed
      DurationSec  = $duration
      ReturnCode   = $rc
      Status       = $status
      FailCount    = ($fails | Measure-Object).Count
    }
  } | Sort-Object @{ Expression = {
        if     ($_.StartedAt)   { $_.StartedAt }
        elseif ($_.TriggeredAt) { $_.TriggeredAt }
        elseif ($_.QueuedAt)    { $_.QueuedAt }
        elseif ($_.CompletedAt) { $_.CompletedAt }
        else { Get-Date 0 }
      }; Descending = $true }
}
'@

# replace or append Runs2
if ($text -match '(?m)^\s*function\s+Get-CtraderTaskRuns2\b') {
  $text = [regex]::Replace($text, '(?ms)^\s*function\s+Get-CtraderTaskRuns2\b.*?(?=^\s*function\s+|\Z)', $improvedRuns2)
  Add-Change "Upgraded Get-CtraderTaskRuns2 (with -Since)"
} else {
  $text = $text.TrimEnd() + "`r`n`r`n" + $improvedRuns2
  Add-Change "Added Get-CtraderTaskRuns2 (with -Since)"
}

# rename legacy Runs -> RunsLegacy (if any)
if ($text -match '(?m)^\s*function\s+Get-CtraderTaskRuns\b') {
  if ($text -notmatch '(?m)^\s*function\s+Get-CtraderTaskRunsLegacy\b') {
    $text = $text -replace '(?m)^\s*function\s+Get-CtraderTaskRuns\b', 'function Get-CtraderTaskRunsLegacy'
    Add-Change "Preserved old Get-CtraderTaskRuns as Get-CtraderTaskRunsLegacy"
  }
}

# wrapper Runs -> calls Runs2
$wrapper = @'
function Get-CtraderTaskRuns {
  [CmdletBinding(DefaultParameterSetName='ByHours')]
  param(
    [Parameter(ParameterSetName='ByHours')][int]$Hours = 24,
    [Parameter(ParameterSetName='BySince')][datetime]$Since,
    [string]$TaskName = '\ctrader-paper-daily',
    [switch]$IncludeExtra,
    [string]$ComputerName
  )
  if ($PSCmdlet.ParameterSetName -eq 'BySince') {
    Get-CtraderTaskRuns2 -TaskName $TaskName -Since $Since -IncludeExtra:$IncludeExtra -ComputerName $ComputerName
  } else {
    Get-CtraderTaskRuns2 -TaskName $TaskName -Hours $Hours -IncludeExtra:$IncludeExtra -ComputerName $ComputerName
  }
}
'@

if ($text -match '(?m)^\s*function\s+Get-CtraderTaskRuns\b') {
  $text = [regex]::Replace($text, '(?ms)^\s*function\s+Get-CtraderTaskRuns\b.*?(?=^\s*function\s+|\Z)', $wrapper)
  Add-Change "Replaced Get-CtraderTaskRuns to wrap Runs2"
} else {
  $text = $text.TrimEnd() + "`r`n`r`n" + $wrapper
  Add-Change "Added Get-CtraderTaskRuns wrapper"
}

# clean any prior Export-ModuleMember lines
$text = $text -replace '(?m)^\s*Export-ModuleMember\b.*\r?\n?', ''
$text = $text.TrimEnd() + "`r`n`r`n" +
  'Export-ModuleMember -Function Show-CtraderTaskHistory, Show-CtraderTaskProblems, Get-CtraderTaskSummary, Get-CtraderTaskRollup, Watch-CtraderTask, Get-CtraderTaskRuns, Get-CtraderTaskRuns2' + "`r`n"
Add-Change "Normalized Export-ModuleMember"

# write & syntax check
try {
  if (-not $WhatIfOnly) {
    Set-Content -LiteralPath $mod -Value $text -Encoding UTF8
    $tokens=$null;$ast=$null;$errs=$null
    [System.Management.Automation.Language.Parser]::ParseFile($mod,[ref]$tokens,[ref]$errs) | Out-Null
    if ($errs) { throw "Parser errors. First: $($errs[0].Message)" }
  }
} catch {
  Add-Error "Write/parse failed: $($_.Exception.Message)"
}

# reload module
try {
  if (-not $WhatIfOnly) {
    Remove-Module ctrader.tools -ErrorAction SilentlyContinue
    Import-Module $mod -Force -Scope Global
    Add-Change "Imported module: $mod"
  }
} catch {
  Add-Error "Import failed: $($_.Exception.Message)"
}

# persistence (optional)
if ($PersistPSModulePath -and -not $WhatIfOnly) {
  try {
    $tools = (Resolve-Path (Split-Path $mod)).Path
    if ($env:PSModulePath -notlike "*$tools*") {
      [Environment]::SetEnvironmentVariable('PSModulePath', "$tools;$env:PSModulePath", 'User')
      Add-Change "Added tools to PSModulePath (User): $tools"
    } else {
      Add-Change "PSModulePath already includes tools"
    }
  } catch { Add-Error "PSModulePath update failed: $($_.Exception.Message)" }
}

if ($PersistToProfile -and -not $WhatIfOnly) {
  try {
    $profileLine = 'Import-Module "{0}" -Force' -f $mod
    if (Test-Path $PROFILE) {
      $prof = Get-Content -LiteralPath $PROFILE -Raw
      if ($prof -notmatch [regex]::Escape($profileLine)) {
        Add-Content -LiteralPath $PROFILE -Value $profileLine
        Add-Change "Appended Import-Module line to profile: $PROFILE"
      } else {
        Add-Change "Profile already imports the module"
      }
    } else {
      New-Item -ItemType File -Path $PROFILE -Force | Out-Null
      Add-Content -LiteralPath $PROFILE -Value $profileLine
      Add-Change "Created profile and added Import-Module: $PROFILE"
    }
  } catch { Add-Error "Profile update failed: $($_.Exception.Message)" }
}

# summary
Write-Host "`n=== Update Organizer ===" -ForegroundColor Cyan
if ($changes.Count) {
  $i=0; $changes | ForEach-Object { "{0,2}. {1}" -f (++$i), $_ } | Write-Host -ForegroundColor Green
} else {
  Write-Host "No changes applied." -ForegroundColor Yellow
}
if ($errors.Count) {
  Write-Host "`nErrors:" -ForegroundColor Red
  $errors | ForEach-Object { "  - $_" } | Write-Host -ForegroundColor Red
}

if (-not $WhatIfOnly -and (Get-Module ctrader.tools)) {
  Write-Host "`nExports:" -ForegroundColor Cyan
  (Get-Module ctrader.tools).ExportedFunctions.Keys | Write-Host
  Write-Host "`nDone." -ForegroundColor Cyan
}
