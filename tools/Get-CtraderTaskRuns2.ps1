function Get-CtraderTaskRuns2 {
  [CmdletBinding()]
  param(
    [string]$TaskName = '\ctrader-paper-daily',
    [int]   $Hours    = 24,
    [switch]$IncludeExtra,
    [string]$ComputerName
  )

  $minutes = [math]::Abs($Hours) * 60
  $hist = Show-CtraderTaskHistory -TaskName $TaskName -Minutes $minutes -IncludeExtra:$IncludeExtra -ComputerName $ComputerName -Raw
  $prob = Show-CtraderTaskProblems -TaskName $TaskName -Hours $Hours -IncludeQueued -ComputerName $ComputerName -Raw
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
    $completed = if ($t201) { $t201.Time } elseif ($t102) { $t102.Time }

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

    $status = if ($fails) { 'Failed' }
      elseif ($completed) { if ($rc -ne $null -and $rc -ne 0) { "Completed (rc=$rc)" } else { 'Completed' } }
      elseif ($started) { 'In-Progress/Aborted?' }
      else { 'Queued/Triggered' }

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
