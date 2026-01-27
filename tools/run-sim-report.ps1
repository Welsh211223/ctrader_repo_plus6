$ErrorActionPreference="Stop"

function Get-DiscordWebhook {
  try { return (Get-Secret DISCORD_WEBHOOK_URL -AsPlainText) } catch { return $null }
}

function Send-Discord([string]$msg){
  $wh = Get-DiscordWebhook
  if(-not $wh){ return }
  Invoke-RestMethod -Uri $wh -Method Post -ContentType 'application/json' -Body (@{content=$msg}|ConvertTo-Json) | Out-Null
}

$root = (Get-Location).Path
$py   = Join-Path $root ".venv\Scripts\python.exe"
& $py (Join-Path $root "simulator.py") | Out-Null

$csv = Join-Path $root "logs\sim_report.csv"
if(Test-Path $csv){
  $rows = Import-Csv $csv
  $lines = @("📊 ctrader sim report")
  foreach($r in $rows){
    $lines += ("• {0}: invested {1} | mkt {2} | PnL {3} ({4}%)" -f `
      $r.symbol, $r.invested_aud, $r.market_value_aud, $r.pnl_aud, $r.pnl_pct)
  }
  Send-Discord ($lines -join "`n")
}else{
  Send-Discord "📊 ctrader sim: no report available"
}
