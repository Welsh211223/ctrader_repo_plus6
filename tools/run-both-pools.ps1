[CmdletBinding()]
param(
  [int]$Live = 0,
  [double]$MinNotional = 25,

  # Input CSVs (one per pool)
  [string]$ConservativeCsv = ".\out\signals_conservative.csv",
  [string]$AggressiveCsv   = ".\out\signals_aggressive.csv",

  # Per-pool daily caps (AUD)
  [double]$ConservativeDailyCapAUD = 300,
  [double]$AggressiveDailyCapAUD   = 300,

  # Output merged file
  [string]$MergedCsv = ".\out\signals_merged.csv",

  # Executor runner
  [string]$Runner = ".\tools\run-coinspot-exec.ps1"
)

$ErrorActionPreference = "Stop"

function Ensure-Dir($path) {
  $dir = Split-Path -Parent (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue)
  if (-not $dir) { $dir = Split-Path -Parent $path }
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force $dir | Out-Null
  }
}

function New-DemoFile($path, $pool, $symbol, $side, $qty, $price, $notional) {
  Ensure-Dir $path
  $ts = Get-Date -Format "yyyyMMddHHmmss"
  @"
pool,client_id,symbol,side,qty,price,notional_aud
$pool,$($pool)-$($symbol.Replace('/','-'))-$($side)-$ts,$symbol,$side,$qty,$price,$notional
"@ | Set-Content -Encoding UTF8 $path
}

# Create missing input CSVs with demos (only if missing)
if (-not (Test-Path -LiteralPath $ConservativeCsv)) {
  New-DemoFile $ConservativeCsv "conservative" "BTC/AUD" "BUY" 0.005 100000 500
}
if (-not (Test-Path -LiteralPath $AggressiveCsv)) {
  New-DemoFile $AggressiveCsv   "aggressive"   "ETH/AUD" "SELL" 0.2   4000   800
}

# Load CSVs if present
$cons = @()
$aggr = @()
if (Test-Path -LiteralPath $ConservativeCsv) {
  $tmp = Import-Csv -Path $ConservativeCsv -ErrorAction SilentlyContinue
  if ($tmp) { $cons = @($tmp) }
}
if (Test-Path -LiteralPath $AggressiveCsv) {
  $tmp = Import-Csv -Path $AggressiveCsv -ErrorAction SilentlyContinue
  if ($tmp) { $aggr = @($tmp) }
}

if ((-not $cons) -and (-not $aggr)) {
  throw "No input signals found. Create at least one of:`n  $ConservativeCsv`n  $AggressiveCsv"
}

# Helper to coerce numeric
function As-Double($v) {
  $d = 0.0
  if ($null -ne $v -and [double]::TryParse($v.ToString(), [ref]$d)) { return $d }
  return 0.0
}

# Apply MinNotional + Per-pool daily caps
$consumedCons = 0.0
$consumedAggr = 0.0
$kept = New-Object System.Collections.Generic.List[object]

foreach ($r in $cons) {
  $n  = As-Double $r.notional_aud
  if ($n -le 0) {
    $qty   = As-Double $r.qty
    $price = As-Double $r.price
    $n = $qty * $price
  }
  if ($n -lt $MinNotional) { continue }
  if ($consumedCons + $n -gt $ConservativeDailyCapAUD) { continue }
  $consumedCons += $n
  $kept.Add($r) | Out-Null
}

foreach ($r in $aggr) {
  $n  = As-Double $r.notional_aud
  if ($n -le 0) {
    $qty   = As-Double $r.qty
    $price = As-Double $r.price
    $n = $qty * $price
  }
  if ($n -lt $MinNotional) { continue }
  if ($consumedAggr + $n -gt $AggressiveDailyCapAUD) { continue }
  $consumedAggr += $n
  $kept.Add($r) | Out-Null
}

# Dedup by client_id (fallback on symbol|side|qty|price)
$seen = @{}
$dedup = New-Object System.Collections.Generic.List[object]
foreach ($r in $kept) {
  $cid = ""
  if ($r.PSObject.Properties['client_id']) { $cid = $r.client_id }
  if (-not $cid) {
    $sym = if ($r.PSObject.Properties['symbol']) { $r.symbol } else { '' }
    $side= if ($r.PSObject.Properties['side'])   { $r.side }   else { '' }
    $qty = if ($r.PSObject.Properties['qty'])    { $r.qty }    else { '' }
    $prc = if ($r.PSObject.Properties['price'])  { $r.price }  else { '' }
    $cid = "$sym|$side|$qty|$prc"
  }
  if (-not $seen.ContainsKey($cid)) {
    $seen[$cid] = $true
    $dedup.Add($r) | Out-Null
  }
}

# Write merged CSV
Ensure-Dir $MergedCsv
$dedupCount = if ($dedup) { $dedup.Count } else { 0 }
if ($dedupCount -gt 0) {
  $dedup | Export-Csv -Path $MergedCsv -NoTypeInformation -Encoding UTF8
} else {
  # Emit header only to keep downstream happy
  @"
pool,client_id,symbol,side,qty,price,notional_aud
"@ | Set-Content -Encoding UTF8 $MergedCsv
}
Write-Host ("Merged {0} signal(s) -> {1}" -f $dedupCount, (Resolve-Path $MergedCsv).Path)

# Call the executor runner
if (-not (Test-Path -LiteralPath $Runner)) {
  Write-Host ("Runner not found: {0}" -f $Runner) -ForegroundColor Yellow
  exit 0
}
& $Runner -Signals $MergedCsv -Live $Live -MinNotional $MinNotional
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
