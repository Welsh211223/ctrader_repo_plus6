$ErrorActionPreference="Stop"
$path = "logs\\decisions.csv"
"timestamp,pool,symbol,side,size,reason,live_trading,dry_run,live_executed" | Set-Content -Encoding UTF8 $path
Write-Host "Cleared -> $path"
