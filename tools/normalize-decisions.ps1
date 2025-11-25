param([string]$Path = "logs\\decisions.csv")
$ErrorActionPreference = "Stop"

# Ensure folder exists
$dir = Split-Path $Path -Parent
if(!(Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }

# Expected CSV header line
$EXPECTED = "timestamp,pool,symbol,side,size,reason,live_trading,dry_run,live_executed"

# Create empty with headers if file missing or empty
if(!(Test-Path $Path) -or ((Get-Item $Path).Length -eq 0)){
  Set-Content -Encoding UTF8 $Path $EXPECTED
  Write-Host "Normalized (empty -> headers only) -> $Path"
  exit 0
}

# Helpers
function Get-Val($row, [string[]]$keys, $default=''){
  foreach($k in $keys){
    if($row.PSObject.Properties.Name -contains $k){
      $v = $row.$k
      if($null -ne $v -and $v.ToString() -ne ''){ return $v }
    }
  }
  return $default
}
function B01($v){
  if($null -eq $v){ return 0 }
  $s = $v.ToString().ToLower()
  if($s -in @('1','true','yes','y')){ return 1 }
  return 0
}

$rows = Import-Csv $Path
if(-not $rows){
  Set-Content -Encoding UTF8 $Path $EXPECTED
  Write-Host "Normalized (empty rows -> headers only) -> $Path"
  exit 0
}

$fixed = foreach($r in $rows){
  $ts   = Get-Val $r @('timestamp','ts','time','Time','Time (UTC)') ''
  $pool = Get-Val $r @('pool','Pool') ''
  $sym  = Get-Val $r @('symbol','asset','pair','Symbol') ''
  $side = (Get-Val $r @('side','action','Side') '').ToString().ToLower()
  $size = Get-Val $r @('size','qty','quantity','Size') ''
  $rsn  = Get-Val $r @('reason','Reason','note','notes') ''

  $live = Get-Val $r @('live_trading','live','is_live','LIVE') 0
  $dry  = Get-Val $r @('dry_run','dry','DRY') 1
  $lex  = Get-Val $r @('live_executed','executed','filled','LIVE_EXECUTED','LIVE') 0

  [PSCustomObject]@{
    timestamp      = $ts
    pool           = $pool
    symbol         = $sym
    side           = $side
    size           = $size
    reason         = $rsn
    live_trading   = B01 $live
    dry_run        = B01 $dry
    live_executed  = B01 $lex
  }
}

# Write clean CSV with canonical order
$fixed | Export-Csv -NoTypeInformation -Encoding UTF8 $Path
$clean = Import-Csv $Path | Select-Object timestamp,pool,symbol,side,size,reason,live_trading,dry_run,live_executed
$clean | Export-Csv -NoTypeInformation -Encoding UTF8 $Path

Write-Host "Normalized -> $Path"
