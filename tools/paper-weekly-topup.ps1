[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WindowStart,
  [Parameter(Mandatory=$true)][string]$WindowEnd,
  [Parameter(Mandatory=$true)][decimal]$WeeklyBudget,
  [Parameter(Mandatory=$true)][ref]$CashRef,
  [Parameter(Mandatory=$true)][string]$RunId,
  [string]$CashLedgerCsv = ".\logs\paper_cash_ledger.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($WeeklyBudget -le 0) { return }
if ([string]::IsNullOrWhiteSpace($WindowStart) -or [string]::IsNullOrWhiteSpace($WindowEnd)) { return }

# Ensure ledger exists with expected schema
$expectedHeader = 'ts_utc,run_id,window_start,window_end,delta_aud,cash_after_aud,reason,note'
$dir = Split-Path -Parent $CashLedgerCsv
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

if (-not (Test-Path $CashLedgerCsv)) {
  $expectedHeader | Out-File -FilePath $CashLedgerCsv -Encoding utf8
} else {
  $first = (Get-Content $CashLedgerCsv -TotalCount 1)
  if ($first -ne $expectedHeader) {
    throw "[paper] Cash ledger schema unexpected. First line was: $first"
  }
}

# Idempotency check: already topped up for this window?
$existing = Select-String -Path $CashLedgerCsv -Pattern (",$WindowStart,$WindowEnd,") -SimpleMatch -ErrorAction SilentlyContinue |
  Where-Object { $_.Line -match ',weekly_topup,' }

if ($existing) {
  Write-Host "[paper] Weekly top-up already recorded for window $WindowStart -> $WindowEnd (skipping)." -ForegroundColor Yellow
  return
}

# Apply deposit
$CashRef.Value = [decimal]$CashRef.Value + [decimal]$WeeklyBudget
$tsUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$cashAfter = [decimal]$CashRef.Value

# Append ledger row
"$tsUtc,$RunId,$WindowStart,$WindowEnd,$WeeklyBudget,$cashAfter,weekly_topup,""" |
  Out-File -FilePath $CashLedgerCsv -Append -Encoding utf8

Write-Host "[paper] Weekly top-up: +A$WeeklyBudget (window $WindowStart -> $WindowEnd). Cash now: A$cashAfter" -ForegroundColor Yellow
