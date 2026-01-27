param(
  [int]$LookbackDays = 180,
  [int]$StepDays = 7,
  [string]$Strategy = "both",
  [string]$Out = "logs\\sim_backtest.csv"
)
$ErrorActionPreference="Stop"
$root = (Get-Location).Path
$py   = Join-Path $root ".venv\\Scripts\\python.exe"
$csvOut = Join-Path $root $Out
$rows = @()

$todayUtc = [DateTime]::UtcNow.Date
$start0 = $todayUtc.AddDays(-$LookbackDays)

for($d=$start0; $d -lt $todayUtc; $d=$d.AddDays($StepDays)){
  $dStart = $d.ToString("yyyy-MM-dd")
  $dEnd   = $d.AddDays($StepDays-1)
  if($dEnd -gt $todayUtc){ $dEnd = $todayUtc }
  $dEndS = $dEnd.ToString("yyyy-MM-dd")

  $tmp = Join-Path $root "logs\\__tmp_sim.csv"
  & $py (Join-Path $root "simulator.py") --start $dStart --end $dEndS --strategy $Strategy --out $tmp | Out-Null
  if(Test-Path $tmp){
    $part = Import-Csv $tmp
    foreach($r in $part){
      $r | Add-Member -NotePropertyName "window_start" -NotePropertyValue $dStart
      $r | Add-Member -NotePropertyName "window_end"   -NotePropertyValue $dEndS
      $rows += $r
    }
    Remove-Item $tmp -Force
  }
}

if($rows.Count){
  $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $csvOut
  Write-Host "Backtest complete -> $csvOut"
}else{
  Write-Host "No rows produced; check data window & CSVs in ./data"
}
