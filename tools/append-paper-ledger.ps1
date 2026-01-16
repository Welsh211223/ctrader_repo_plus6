[CmdletBinding()]
param(
  [string]$SignalCsv = ".\logs\latest_crypto_signal.csv",
  [string]$LedgerCsv = ".\logs\paper_signal_ledger.csv",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Duplicate-window flag used by update-paper-portfolio.ps1
$dupFlag = Join-Path $PSScriptRoot "..\logs\_duplicate_window.flag"

# Always clear at the start; we only create it when we detect a duplicate
Remove-Item $dupFlag -ErrorAction SilentlyContinue | Out-Null

function Ensure-File([string]$path, [string]$headerLine) {
  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path $path)) {
    $headerLine | Out-File -FilePath $path -Encoding utf8
  }
}

function Get-LatestWindowFromSignal([object[]]$rows) {
  if (-not $rows -or $rows.Count -eq 0) { return $null }
  $first = $rows | Select-Object -First 1
  $ws = if ($first.PSObject.Properties.Name -contains "window_start") { [string]$first.window_start } else { "" }
  $we = if ($first.PSObject.Properties.Name -contains "window_end")   { [string]$first.window_end }   else { "" }
  return [pscustomobject]@{ window_start = $ws; window_end = $we }
}

if (-not (Test-Path $SignalCsv)) {
  throw "[ledger] Missing SignalCsv: $SignalCsv"
}

$rows = Import-Csv $SignalCsv
if (-not $rows -or $rows.Count -eq 0) {
  Write-Host "[ledger] No rows in $SignalCsv (HOLD CASH week?) - nothing to append." -ForegroundColor Yellow
  exit 0
}

# Backfill missing columns once (signal CSV may not include them)
$runIdFallback    = (Get-Date -Format "yyyyMMdd_HHmmss")
$runLocalFallback = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
$noteFallback     = "signal"

foreach ($s in $rows) {
  if ($s -and ($s.PSObject.Properties.Name -notcontains "run_id")) {
    $null = $s | Add-Member -NotePropertyName "run_id" -NotePropertyValue $runIdFallback -Force
  } elseif ($s -and [string]::IsNullOrWhiteSpace([string]$s.run_id)) {
    $s.run_id = $runIdFallback
  }

  if ($s -and ($s.PSObject.Properties.Name -notcontains "run_local")) {
    $null = $s | Add-Member -NotePropertyName "run_local" -NotePropertyValue $runLocalFallback -Force
  } elseif ($s -and [string]::IsNullOrWhiteSpace([string]$s.run_local)) {
    $s.run_local = $runLocalFallback
  }

  if ($s -and ($s.PSObject.Properties.Name -notcontains "note")) {
    $null = $s | Add-Member -NotePropertyName "note" -NotePropertyValue $noteFallback -Force
  } elseif ($s -and [string]::IsNullOrWhiteSpace([string]$s.note)) {
    $s.note = $noteFallback
  }
}

# Ensure ledger exists
Ensure-File $LedgerCsv "run_id,run_local,window_start,window_end,base_pair,action,buy_aud,units,last_price,weekly_budget_aud,note"

# Determine window
$win = Get-LatestWindowFromSignal $rows
$ws = [string]$win.window_start
$we = [string]$win.window_end

# Duplicate guard against ledger (window-level)
if (-not $Force -and -not [string]::IsNullOrWhiteSpace($ws) -and -not [string]::IsNullOrWhiteSpace($we) -and (Test-Path $LedgerCsv)) {
  $dup = Select-String -Path $LedgerCsv -Pattern (",$ws,$we,") -SimpleMatch -ErrorAction SilentlyContinue
  if ($dup) {
    Write-Host "[ledger] DUPLICATE: window $ws -> $we already exists in ledger. Use -Force to override." -ForegroundColor Yellow
    "duplicate" | Out-File -FilePath $dupFlag -Encoding utf8
    exit 0
  }
}

# Append ledger rows (normalized columns, tolerate missing fields)
foreach ($r in $rows) {
  $run_id   = [string]$r.run_id
  $run_local= [string]$r.run_local
  $wstart   = if ($r.PSObject.Properties.Name -contains "window_start") { [string]$r.window_start } else { $ws }
  $wend     = if ($r.PSObject.Properties.Name -contains "window_end")   { [string]$r.window_end }   else { $we }

  $base_pair = ""
  if ($r.PSObject.Properties.Name -contains "base_pair") { $base_pair = [string]$r.base_pair }
  elseif ($r.PSObject.Properties.Name -contains "symbol") { $base_pair = [string]$r.symbol }
  elseif ($r.PSObject.Properties.Name -contains "pair") { $base_pair = [string]$r.pair }

  $action = ""
  if ($r.PSObject.Properties.Name -contains "action") { $action = [string]$r.action }
  elseif ($r.PSObject.Properties.Name -contains "side") { $action = [string]$r.side }
  elseif ($r.PSObject.Properties.Name -contains "signal") { $action = [string]$r.signal }
  elseif ($r.PSObject.Properties.Name -contains "decision") { $action = [string]$r.decision }

  $buy_aud = if ($r.PSObject.Properties.Name -contains "buy_aud") { [string]$r.buy_aud } else { "" }
  $units   = if ($r.PSObject.Properties.Name -contains "units") { [string]$r.units } else { "" }
  $last_px = if ($r.PSObject.Properties.Name -contains "last_price") { [string]$r.last_price } else { "" }
  $budget  = if ($r.PSObject.Properties.Name -contains "weekly_budget_aud") { [string]$r.weekly_budget_aud } else { "" }
  $note    = [string]$r.note

  # CSV-safe: wrap fields that might contain commas
  $line = @(
    $run_id,
    $run_local,
    $wstart,
    $wend,
    $base_pair,
    $action,
    $buy_aud,
    $units,
    $last_px,
    $budget,
    $note
  ) -join ','

  $line | Out-File -FilePath $LedgerCsv -Append -Encoding utf8
}

Write-Host "[ledger] Appended $(($rows | Measure-Object).Count) rows for window $ws -> $we" -ForegroundColor Green
