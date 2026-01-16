[CmdletBinding()]
param(
  [string]$LedgerCsv = ".\logs\paper_signal_ledger.csv",
  [string]$SignalTxt = ".\logs\latest_crypto_signal.txt",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-WindowFromTxt([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  $txt = Get-Content $p -Raw

  # ONLY ASCII: match "Window: YYYY-MM-DD -> YYYY-MM-DD"
  if ($txt -match 'Window:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*->\s*([0-9]{4}-[0-9]{2}-[0-9]{2})') {
    return [pscustomobject]@{ window_start = $Matches[1]; window_end = $Matches[2] }
  }
  return $null
}

$win = Get-WindowFromTxt $SignalTxt
if (-not $win) {
  Write-Host "[guard] Could not parse window from $SignalTxt. Skipping duplicate guard." -ForegroundColor Yellow
  exit 0
}

if (-not (Test-Path $LedgerCsv)) {
  Write-Host "[guard] Ledger not found ($LedgerCsv). No duplicate risk yet." -ForegroundColor Yellow
  exit 0
}

$ledger = Import-Csv $LedgerCsv
$hits = @($ledger | Where-Object { $_.window_start -eq $win.window_start -and $_.window_end -eq $win.window_end })

if ($hits.Count -gt 0 -and -not $Force) {
  $sample = $hits | Select-Object -First 1
  throw "[guard] DUPLICATE: window $($win.window_start) -> $($win.window_end) already exists (example run_id=$($sample.run_id)). Use -Force to override."
}

Write-Host "[guard] OK: window $($win.window_start) -> $($win.window_end) not yet recorded (or -Force used)." -ForegroundColor Green
