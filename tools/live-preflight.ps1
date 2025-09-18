# tools\live-preflight.ps1 — safety checklist before any live run
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Resolve-Path "$PSScriptRoot\..").Path
$allow = Join-Path $root ".allow_live"

function BoolTruthy($v) {
  if ($null -eq $v) { return $false }
  $s = ($v.ToString()).Trim().ToLower()
  return @("1","true","yes","on") -contains $s
}

$hasKey = [bool]$env:COINSPOT_API_KEY
$hasSec = [bool]$env:COINSPOT_API_SECRET
$live   = BoolTruthy $env:COINSPOT_LIVE_DANGEROUS
$conf   = BoolTruthy $env:CONFIRM_LIVE

$tokenOk = $false
if (Test-Path $allow) {
  try {
    $age = (Get-Date) - (Get-Item $allow).LastWriteTime
    if ($age.TotalSeconds -le 3600) { $tokenOk = $true }
  } catch { $tokenOk = $false }
}

Write-Host "=== Live Preflight ===" -ForegroundColor Cyan
Write-Host ("Keys present?             API:{0}  SECRET:{1}" -f $hasKey, $hasSec)
Write-Host ("Live flag (dangerous)?    {0}" -f $live)
Write-Host ("Have CONFIRM_LIVE?        {0}" -f $conf)
Write-Host ("Valid .allow_live token?  {0}" -f $tokenOk)

$issues = New-Object System.Collections.Generic.List[string]
if (-not $hasKey) { $issues.Add("COINSPOT_API_KEY missing (run .\tools\set-secrets.ps1 -Load)") }
if (-not $hasSec) { $issues.Add("COINSPOT_API_SECRET missing (run .\tools\set-secrets.ps1 -Load)") }

if ($live -and -not ($conf -or $tokenOk)) {
  $issues.Add("Guard will BLOCK live orders: COINSPOT_LIVE_DANGEROUS=true but no CONFIRM_LIVE and no fresh .allow_live.")
}

if ($issues.Count -gt 0) {
  Write-Host "`nProblems:" -ForegroundColor Yellow
  $issues | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
  Write-Host "`nSuggested fixes:" -ForegroundColor Yellow
  Write-Host " - Ensure secrets are loaded:  .\tools\set-secrets.ps1 -Load"
  Write-Host " - For dry runs:              use .\tools\safe-run.ps1 or .\tools\run-backtest.ps1"
  Write-Host " - For live (later):          set CONFIRM_LIVE=1 or touch .allow_live (valid 1h), but only when truly ready."
  exit 2
}

Write-Host "`nPreflight looks OK." -ForegroundColor Green
# Optional: smoke test (read-only)
if (Test-Path (Join-Path $PSScriptRoot "smoke-coinspot.ps1")) {
  Write-Host "Running smoke check..." -ForegroundColor Cyan
  & "$PSScriptRoot\smoke-coinspot.ps1"
  exit $LASTEXITCODE
}
exit 0
