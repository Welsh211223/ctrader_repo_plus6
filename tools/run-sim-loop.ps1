param(
  [int]$EveryMinutes = 60,
  [string]$Strategy = "both",
  [string]$Out = "logs\\sim_loop_log.csv"
)
$ErrorActionPreference="Stop"
$root = (Get-Location).Path
$py   = Join-Path $root ".venv\\Scripts\\python.exe"
$csvOut = Join-Path $root $Out
if(!(Test-Path (Split-Path $csvOut))){ New-Item -ItemType Directory -Force -Path (Split-Path $csvOut) | Out-Null }

function Run-One {
  $now = [DateTime]::UtcNow
  $tmp = Join-Path $root "logs\\__tmp_loop.csv"
  & $py (Join-Path $root "simulator.py") --strategy $Strategy --out $tmp | Out-Null
  if(Test-Path $tmp){
    $rows = Import-Csv $tmp
    foreach($r in $rows){
      $obj = [PSCustomObject]@{
        ts_run           = $now.ToString("s")+"Z"
        symbol           = $r.symbol
        trades           = $r.trades
        invested_aud     = $r.invested_aud
        units            = $r.units
        last_price       = $r.last_price
        market_value_aud = $r.market_value_aud
        pnl_aud          = $r.pnl_aud
        pnl_pct          = $r.pnl_pct
      }
      $append = -not (Test-Path $csvOut)
      if($append){
        $obj | Export-Csv -NoTypeInformation -Encoding UTF8 $csvOut
      }else{
        $obj | Export-Csv -NoTypeInformation -Encoding UTF8 -Append $csvOut
      }
    }
    Remove-Item $tmp -Force
  }
}

Write-Host "Starting continuous sim loop every $EveryMinutes minute(s). CTRL+C to stop."
while($true){
  Run-One
  Start-Sleep -Seconds (60*$EveryMinutes)
}
