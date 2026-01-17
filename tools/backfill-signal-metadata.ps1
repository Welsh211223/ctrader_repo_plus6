[CmdletBinding()]
param(
  [string]$SignalCsv = ".\logs\latest_crypto_signal.csv",
  [string]$Source    = "sim_backtest_multi_trend_cc.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NowUtcIso() {
  return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function To-Decimal([object]$x) {
  if ($null -eq $x) { return [decimal]0 }
  $s = ([string]$x).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return [decimal]0 }
  $s = $s -replace '^[A-Za-z]\$',''
  $s = $s -replace '[, ]',''
  try { [decimal]$s } catch { [decimal]0 }
}

if (-not (Test-Path $SignalCsv)) {
  Write-Host "[meta] No signal CSV found: $SignalCsv" -ForegroundColor Yellow
  exit 0
}

$rows = Import-Csv $SignalCsv
if (-not $rows -or $rows.Count -eq 0) {
  Write-Host "[meta] Signal CSV empty: $SignalCsv" -ForegroundColor Yellow
  exit 0
}

$now = Get-NowUtcIso

# Determine if columns exist
$props = @($rows[0].PSObject.Properties.Name)

$needsGenerated = -not ($props -contains "generated_utc")
$needsSource    = -not ($props -contains "source")
$needsAction    = -not ($props -contains "action")
$needsBuyAud    = -not ($props -contains "buy_aud")

if (-not ($needsGenerated -or $needsSource -or $needsAction -or $needsBuyAud)) {
  Write-Host "[meta] Signal CSV already has generated_utc/source/action/buy_aud. No changes." -ForegroundColor Green
  exit 0
}

foreach ($r in $rows) {
  if ($needsGenerated) { $r | Add-Member -NotePropertyName "generated_utc" -NotePropertyValue $now -Force }
  if ($needsSource)    { $r | Add-Member -NotePropertyName "source"        -NotePropertyValue $Source -Force }

  # Bonus: create action/buy_aud for compatibility with live executor later
  if ($needsAction) { $r | Add-Member -NotePropertyName "action" -NotePropertyValue "buy" -Force }

  if ($needsBuyAud) {
    # Your file uses invested_aud as the intended weekly buy amount
    $buy = if ($r.PSObject.Properties.Name -contains "invested_aud") { To-Decimal $r.invested_aud } else { [decimal]0 }
    $r | Add-Member -NotePropertyName "buy_aud" -NotePropertyValue ([decimal]::Round($buy, 2)) -Force
  }
}

# Preserve original columns order but ensure new fields exist at end
$tmp = Join-Path (Split-Path -Parent $SignalCsv) ("latest_crypto_signal.tmp_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$rows | Export-Csv -NoTypeInformation -Path $tmp -Encoding UTF8
Move-Item -Force $tmp $SignalCsv

Write-Host "[meta] Backfilled: generated_utc/source/action/buy_aud -> $SignalCsv" -ForegroundColor Green
