$ErrorActionPreference = "Stop"
$path = "logs\\decisions.csv"
if(!(Test-Path $path)){ Write-Host "No decisions.csv"; exit 0 }
$rows = Import-Csv $path
if(-not $rows){ Write-Host "Empty decisions.csv"; exit 0 }
$now  = [DateTime]::UtcNow.ToString("s") + "Z"

$fixed = foreach($r in $rows){
  if(-not $r.timestamp -or $r.timestamp -eq ''){ $r.timestamp = $now }
  $r
}
$fixed | Export-Csv -NoTypeInformation -Encoding UTF8 $path
Write-Host "Backfilled timestamps -> $path"
