[CmdletBinding()]
param(
  [string]$SignalCsv = ".\logs\latest_crypto_signal.csv",
  [string]$PositionsCsv = ".\logs\paper_positions.csv",
  [string]$TradesCsv = ".\logs\paper_trades.csv",
  [string]$PortfolioCsv = ".\logs\paper_portfolio.csv",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------
# Duplicate-window guard handshake
# Step 4 (append-paper-ledger) should write logs\_duplicate_window.flag
# If present, we skip portfolio update unless -Force is provided.
# -------------------------------------------------------------------
$DuplicateFlag = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\logs\_duplicate_window.flag"
if (-not $Force -and (Test-Path $DuplicateFlag)) {
  Write-Host "[paper] Duplicate window flag present — NOT appending trades, but continuing portfolio refresh (positions/cash). Use -Force to override trades." -ForegroundColor Yellow
  exit 0
}

# -------------------------------------------------------------------
# SAFESET: create-or-set property on PSCustomObject/hashtable
# -------------------------------------------------------------------
function Set-NoteProp {
  param(
    [Parameter(Mandatory=$true)] $Obj,
    [Parameter(Mandatory=$true)] [string] $Name,
    [Parameter(Mandatory=$true)] $Value
  )
  if ($null -eq $Obj) { return }

  if ($Obj -is [hashtable] -or $Obj -is [System.Collections.IDictionary]) {
    $Obj[$Name] = $Value
    return
  }

  if ($Obj.PSObject.Properties.Name -contains $Name) {
    $Obj.$Name = $Value
  } else {
    $Obj | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force | Out-Null
  }
}

function To-Decimal([object]$x) {
  if ($null -eq $x) { return [decimal]0 }
  $s = [string]$x
  if ([string]::IsNullOrWhiteSpace($s)) { return [decimal]0 }
  $s = $s.Trim()
  $s = $s -replace '^[A-Za-z]\$',''   # strip currency prefix like "A$"
  $s = $s -replace '[, ]',''
  try { return [decimal]$s } catch { return [decimal]0 }
}

function Ensure-File([string]$path, [string]$headerLine) {
  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path $path)) {
    $headerLine | Out-File -FilePath $path -Encoding utf8
  }
}

function Get-NowUtcIso() {
  return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# --- Robust field helpers (tolerate schema differences) ---
function HasField($obj, [string]$name) {
  return ($obj -and ($obj.PSObject.Properties.Name -contains $name))
}
function GetField($obj, [string[]]$names, [string]$default="") {
  foreach ($n in $names) {
    if (HasField $obj $n) {
      $v = $obj.$n
      if ($null -ne $v) { return [string]$v }
    }
  }
  return $default
}
# --- /Robust field helpers ---

if (-not (Test-Path $SignalCsv)) {
  throw "[paper] Missing signal CSV: $SignalCsv (run tools\crypto_dca_signals_cc.py first)"
}

$signals = Import-Csv $SignalCsv
if (-not $signals) { throw "[paper] Signal CSV has no rows: $SignalCsv" }

# Detect schema from first row
$pairField   = "base_pair"
$actionField = "action"

if ($signals -and $signals.Count -gt 0) {
  $cols = $signals[0].PSObject.Properties.Name

  if ($cols -contains "base_pair") { $pairField = "base_pair" }
  elseif ($cols -contains "symbol") { $pairField = "symbol" }
  elseif ($cols -contains "pair") { $pairField = "pair" }

  if ($cols -contains "action") { $actionField = "action" }
  elseif ($cols -contains "side") { $actionField = "side" }
  elseif ($cols -contains "signal") { $actionField = "signal" }
  elseif ($cols -contains "decision") { $actionField = "decision" }
  else { $actionField = "" } # infer later
}

# Backfill run_id if missing
$runIdFallback = (Get-Date -Format "yyyyMMdd_HHmmss")
foreach ($s in $signals) {
  if ($s.PSObject.Properties.Name -notcontains "run_id") {
    $null = $s | Add-Member -NotePropertyName "run_id" -NotePropertyValue $runIdFallback -Force
  } elseif ([string]::IsNullOrWhiteSpace([string]$s.run_id)) {
    $s.run_id = $runIdFallback
  }
}

# Backfill window_start/window_end if missing
foreach ($s in $signals) {
  if ($s.PSObject.Properties.Name -notcontains "window_start") {
    $null = $s | Add-Member -NotePropertyName "window_start" -NotePropertyValue "" -Force
  }
  if ($s.PSObject.Properties.Name -notcontains "window_end") {
    $null = $s | Add-Member -NotePropertyName "window_end" -NotePropertyValue "" -Force
  }
}

# Window info (first row)
$ws = [string]$signals[0].window_start
$we = [string]$signals[0].window_end
$rid0 = [string]$signals[0].run_id

# -------------------------------------------------------------------
# SECOND duplicate guard: if TradesCsv already contains this window with mode=paper_exec,
# skip (unless -Force). This prevents cash bleed on reruns even if the flag is missing.
# -------------------------------------------------------------------
Ensure-File $TradesCsv "ts_utc,side,base_pair,units,price_aud,notional_aud,run_id,window_start,window_end,mode"
if (-not $Force -and (Test-Path $TradesCsv) -and -not [string]::IsNullOrWhiteSpace($ws) -and -not [string]::IsNullOrWhiteSpace($we)) {
  $already = Select-String -Path $TradesCsv -Pattern (",${ws},${we},paper_exec") -SimpleMatch -ErrorAction SilentlyContinue
  if ($already) {
    Write-Host "[paper] Trades already exist for window $ws -> $we — NOT appending trades, but continuing portfolio refresh (positions/cash). Use -Force to override trades." -ForegroundColor Yellow
    exit 0
  }
}

# Determine weekly budget + allocated total
$weeklyBudget = [decimal]0
$allocatedTotal = [decimal]0

if ($signals[0].PSObject.Properties.Name -contains "weekly_budget_aud") {
  $weeklyBudget = To-Decimal $signals[0].weekly_budget_aud
}

foreach ($s in $signals) {
  $actRaw = ""
  if (-not [string]::IsNullOrWhiteSpace($actionField)) {
    $actRaw = GetField $s @($actionField,"action","side","signal","decision") ""
  }

  $act = ($actRaw.Trim().ToLower())
  if ([string]::IsNullOrWhiteSpace($act)) {
    $inferBuyAud = if ($s.PSObject.Properties.Name -contains "buy_aud") { To-Decimal $s.buy_aud } else { [decimal]0 }
    $inferUnits  = if ($s.PSObject.Properties.Name -contains "units")   { To-Decimal $s.units }   else { [decimal]0 }
    if ($inferBuyAud -gt 0 -or $inferUnits -gt 0) { $act = "buy" } else { $act = "hold" }
  }

  if ($act -eq "buy") {
    if ($s.PSObject.Properties.Name -contains "buy_aud") {
      $allocatedTotal += To-Decimal $s.buy_aud
    }
  }
}

# Load current cash/positions
$cash = [decimal]0
$posMap = @{}

if (Test-Path $PositionsCsv) {
  $posRows = Import-Csv $PositionsCsv
  foreach ($p in $posRows) {
    if (-not $p.base_pair) { continue }
    $posMap[$p.base_pair] = $p
  }
}

if (Test-Path $PortfolioCsv) {
  $snap = Import-Csv $PortfolioCsv | Select-Object -Last 1
  if ($snap -and ($snap.PSObject.Properties.Name -contains "cash_aud")) {
    $cash = To-Decimal $snap.cash_aud
  }
}

if ($cash -eq 0 -and $weeklyBudget -gt 0) {
  $cash = $weeklyBudget
  Write-Host "[paper] Initialized cash to A$weeklyBudget (from weekly_budget_aud)." -ForegroundColor Yellow
}

Ensure-File $PositionsCsv "base_pair,units,avg_cost_aud,last_price,market_value_aud,unrealized_pnl_aud,unrealized_pnl_pct,run_id_last,window_start_last,window_end_last"
Ensure-File $PortfolioCsv "ts_utc,run_id,window_start,window_end,weekly_budget_aud,allocated_aud,cash_aud,positions_value_aud,equity_aud"

# Apply signals as paper trades
foreach ($s in $signals) {
  $pair = GetField $s @($pairField,"base_pair","symbol","pair") ""
  if ([string]::IsNullOrWhiteSpace($pair)) { continue }

  $actRaw = ""
  if (-not [string]::IsNullOrWhiteSpace($actionField)) {
    $actRaw = GetField $s @($actionField,"action","side","signal","decision") ""
  }

  $act = ($actRaw.Trim().ToLower())
  if ([string]::IsNullOrWhiteSpace($act)) {
    $inferBuyAud = if ($s.PSObject.Properties.Name -contains "buy_aud") { To-Decimal $s.buy_aud } else { [decimal]0 }
    $inferUnits  = if ($s.PSObject.Properties.Name -contains "units")   { To-Decimal $s.units }   else { [decimal]0 }
    if ($inferBuyAud -gt 0 -or $inferUnits -gt 0) { $act = "buy" } else { $act = "hold" }
  }

  $px = if ($s.PSObject.Properties.Name -contains "last_price") { To-Decimal $s.last_price } else { [decimal]0 }
  $winStart = [string]$s.window_start
  $winEnd   = [string]$s.window_end
  $rid      = [string]$s.run_id

  if (-not $posMap.ContainsKey($pair)) {
    $posMap[$pair] = [pscustomobject]@{
      base_pair = $pair
      units = "0"
      avg_cost_aud = "0"
      last_price = "0"
      market_value_aud = "0"
      unrealized_pnl_aud = "0"
      unrealized_pnl_pct = "0"
      run_id_last = ""
      window_start_last = ""
      window_end_last = ""
    }
  }

  $p = $posMap[$pair]
  $curUnits = To-Decimal $p.units
  $curAvg   = To-Decimal $p.avg_cost_aud

  if ($act -eq "buy") {
    $buyAud = if ($s.PSObject.Properties.Name -contains "buy_aud") { To-Decimal $s.buy_aud } else { [decimal]0 }
    $units  = if ($s.PSObject.Properties.Name -contains "units") { To-Decimal $s.units } else { [decimal]0 }

    if ($units -le 0 -and $px -gt 0 -and $buyAud -gt 0) {
      $units = $buyAud / $px
    }
    if ($buyAud -le 0 -and $px -gt 0 -and $units -gt 0) {
      $buyAud = $units * $px
    }

    if ($buyAud -gt 0 -and $units -gt 0) {
      $cash = $cash - $buyAud

      $newUnits = $curUnits + $units
      $newAvg = if ($newUnits -gt 0) { (($curUnits * $curAvg) + ($units * $px)) / $newUnits } else { [decimal]0 }

      $p.units = "{0:F10}" -f $newUnits
      $p.avg_cost_aud = "{0:F2}" -f $newAvg

      $ts = Get-NowUtcIso
      "$ts,buy,$pair,$units,$px,$buyAud,$rid,$winStart,$winEnd,paper_exec" | Out-File -FilePath $TradesCsv -Append -Encoding utf8
    }
  }
  elseif ($act -eq "sell") {
    $sellUnits = if ($s.PSObject.Properties.Name -contains "units") { To-Decimal $s.units } else { [decimal]0 }
    $sellAud   = if ($px -gt 0) { $sellUnits * $px } else { [decimal]0 }

    if ($sellUnits -gt 0 -and $curUnits -gt 0) {
      if ($sellUnits -gt $curUnits) { $sellUnits = $curUnits }
      $sellAud = $sellUnits * $px
      $cash = $cash + $sellAud
      $p.units = "{0:F10}" -f ([decimal]$curUnits - $sellUnits)

      $ts = Get-NowUtcIso
      "$ts,sell,$pair,$sellUnits,$px,$sellAud,$rid,$winStart,$winEnd,paper_exec" | Out-File -FilePath $TradesCsv -Append -Encoding utf8
    }
  }

  if ($px -gt 0) { $p.last_price = "{0:F2}" -f $px }
  Set-NoteProp -Obj $p -Name "run_id_last" -Value ($rid)
  Set-NoteProp -Obj $p -Name "window_start_last" -Value ($winStart)
  Set-NoteProp -Obj $p -Name "window_end_last" -Value ($winEnd)
}

# Revalue positions
$posValue = [decimal]0
foreach ($pair in $posMap.Keys) {
  $p = $posMap[$pair]
  $u  = To-Decimal $p.units
  $px = To-Decimal $p.last_price
  $ac = To-Decimal $p.avg_cost_aud

  $mv = $u * $px
  $upnl = ($px - $ac) * $u
  $upnlPct = if ($ac -ne 0 -and $u -ne 0) { (($px / $ac) - 1) * 100 } else { [decimal]0 }

  $p.market_value_aud = "{0:F2}" -f $mv
  $p.unrealized_pnl_aud = "{0:F2}" -f $upnl
  $p.unrealized_pnl_pct = "{0:F2}" -f $upnlPct

  $posValue += $mv
}

# Write positions + snapshot
$posOut = $posMap.Values | Sort-Object base_pair
$posOut | Export-Csv -NoTypeInformation -Path $PositionsCsv -Encoding utf8

$equity = $cash + $posValue
$tsNow = Get-NowUtcIso

"$tsNow,$rid0,$ws,$we,$weeklyBudget,$allocatedTotal,$cash,$posValue,$equity" | Out-File -FilePath $PortfolioCsv -Append -Encoding utf8

Write-Host "[paper] Updated positions + cash from latest window $ws -> $we" -ForegroundColor Green
Write-Host ("[paper] Cash now: A{0:F2}" -f [double]$cash) -ForegroundColor Green
Write-Host ("[paper] Positions value: A{0:F2} | Equity: A{1:F2}" -f [double]$posValue, [double]$equity) -ForegroundColor Green
