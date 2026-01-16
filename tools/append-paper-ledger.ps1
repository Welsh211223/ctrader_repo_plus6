[CmdletBinding()]
param(
  [string]$SignalCsv = ".\logs\latest_crypto_signal.csv",
  [string]$LedgerCsv = ".\logs\paper_signal_ledger.csv",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-LatestWindowFromSignal([object[]]$rows) {
  if (-not $rows -or $rows.Count -eq 0) { return $null }
  $ws = ($rows | Select-Object -First 1).window_start
  $we = ($rows | Select-Object -First 1).window_end
  return [pscustomobject]@{ window_start = $ws; window_end = $we }
}

if (-not (Test-Path $SignalCsv)) {
  throw "[ledger] Missing SignalCsv: $SignalCsv"
}

$rows = Import-Csv $SignalCsv

# --- Phase 4 safety: backfill missing columns (signal CSV may not include them) ---
$__RunIdFallback    = (Get-Date -Format "yyyyMMdd_HHmmss")
$__RunLocalFallback = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
$__NoteFallback     = "signal"
foreach ($__s in $rows) {
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "run_id")) {
    $null = $__s | Add-Member -NotePropertyName "run_id" -NotePropertyValue $__RunIdFallback -Force
  }
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "run_local")) {
    $null = $__s | Add-Member -NotePropertyName "run_local" -NotePropertyValue $__RunLocalFallback -Force
  }
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "note")) {
    $null = $__s | Add-Member -NotePropertyName "note" -NotePropertyValue $__NoteFallback -Force
  }
}
# --- /Phase 4 safety ---


# --- Phase 4 safety: backfill run_id + run_local if missing (signal CSV may not include them) ---
$__RunIdFallback = (Get-Date -Format "yyyyMMdd_HHmmss")
$__RunLocalFallback = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
foreach ($__s in $rows) {
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "run_id")) {
    $null = $__s | Add-Member -NotePropertyName "run_id" -NotePropertyValue $__RunIdFallback -Force
  }
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "run_local")) {
    $null = $__s | Add-Member -NotePropertyName "run_local" -NotePropertyValue $__RunLocalFallback -Force
  }
}
# --- /Phase 4 safety: backfill run_id + run_local ---


# --- Phase 4 safety: backfill run_id if missing (signal CSV may not include run_id) ---
$__RunIdFallback = (Get-Date -Format "yyyyMMdd_HHmmss")
foreach ($__s in $rows) {
  if ($__s -and ($__s.PSObject.Properties.Name -notcontains "run_id")) {
    $null = $__s | Add-Member -NotePropertyName "run_id" -NotePropertyValue $__RunIdFallback -Force
  }
}
# --- /Phase 4 safety: backfill run_id ---

if (-not $rows -or $rows.Count -eq 0) {
  Write-Host "[ledger] No rows in $SignalCsv (HOLD CASH week?) - nothing to append." -ForegroundColor Yellow
  exit 0
}

$win = Get-LatestWindowFromSignal $rows
if (-not $win) {
  throw "[ledger] Could not read window_start/window_end from $SignalCsv"
}

# Duplicate guard: if ledger already has this exact window, block unless -Force
if (Test-Path $LedgerCsv) {
  $ledger = Import-Csv $LedgerCsv
  $hits = @($ledger | Where-Object { $_.window_start -eq $win.window_start -and $_.window_end -eq $win.window_end })
  if ($hits.Count -gt 0 -and -not $Force) {
    throw "[ledger] DUPLICATE: window $($win.window_start) -> $($win.window_end) already exists in ledger. Use -Force to override."
  }
}

# Compute totals
$weeklyBudget = 0.0
try { $weeklyBudget = [double]($rows[0].weekly_budget_aud) } catch { $weeklyBudget = 0.0 }

$allocatedTotal = 0.0
foreach ($r in $rows) {
  try { $allocatedTotal += [double]($r.invested_aud) } catch {}
}
$cashUnallocated = [Math]::Round(($weeklyBudget - $allocatedTotal), 2)

# Add per-row fields (repeat totals for convenience)
$enhanced = foreach ($r in $rows) {
  $req = 0.0
  try { $req = [double]($r.invested_aud) } catch { $req = 0.0 }

  [pscustomobject]@{
    run_id              = $r.run_id
    run_local           = $r.run_local
    window_start        = $r.window_start
    window_end          = $r.window_end
    symbol_label        = $r.symbol_label
    base_pair           = $r.base_pair
    invested_aud        = $r.invested_aud
    required_transfer_aud = ("{0:F2}" -f $req)
    allocated_total_aud   = ("{0:F2}" -f $allocatedTotal)
    cash_unallocated_aud  = ("{0:F2}" -f $cashUnallocated)
    units               = $r.units
    last_price          = $r.last_price
    window_pnl_pct      = $r.window_pnl_pct
    weekly_budget_aud   = $r.weekly_budget_aud
    note                = $r.note
  }
}

# Append (or create)
$header = @(
  "run_id","run_local","window_start","window_end","symbol_label","base_pair",
  "invested_aud","required_transfer_aud","allocated_total_aud","cash_unallocated_aud",
  "units","last_price","window_pnl_pct","weekly_budget_aud","note"
)

if (-not (Test-Path $LedgerCsv)) {
  $enhanced | Select-Object $header | Export-Csv -NoTypeInformation -Encoding UTF8 $LedgerCsv
  Write-Host "[ledger] Created $LedgerCsv (rows=$($enhanced.Count))" -ForegroundColor Green
} else {
  # Export-Csv appends only with -Append in PS7, but we must keep header stable
  $enhanced | Select-Object $header | Export-Csv -NoTypeInformation -Encoding UTF8 -Append $LedgerCsv
  Write-Host "[ledger] Appended to $LedgerCsv (rows=$($enhanced.Count))" -ForegroundColor Green
}

Write-Host ("[ledger] Weekly budget: A${0:F2} | Allocated: A${1:F2} | Unallocated: A${2:F2}" -f $weeklyBudget, $allocatedTotal, $cashUnallocated) -ForegroundColor Cyan
