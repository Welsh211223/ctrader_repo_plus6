[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][decimal]$WeeklyBudget,
  [Parameter(Mandatory=$true)][string]$WindowStart,
  [Parameter(Mandatory=$true)][string]$WindowEnd,
  [Parameter(Mandatory=$true)][string]$PortfolioCsv,
  [Parameter(Mandatory=$true)][ref]$CashRef,
  [decimal]$MinAudBuy = 10.00
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LastPortfolioRow([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Import-Csv $path | Select-Object -Last 1) } catch { return $null }
}

# Weekly top-up: if the latest portfolio row is not this window, treat WeeklyBudget as a new deposit
$lastRow = Get-LastPortfolioRow $PortfolioCsv
$isNewWindow = $true

if ($lastRow) {
  $lwS = [string]$lastRow.window_start
  $lwE = [string]$lastRow.window_end
  if ($lwS -eq $WindowStart -and $lwE -eq $WindowEnd) { $isNewWindow = $false }
}

if ($isNewWindow -and $WeeklyBudget -gt 0) {
  $CashRef.Value = $CashRef.Value + $WeeklyBudget
  Write-Host "[paper] Weekly top-up: +A$WeeklyBudget (new window $WindowStart -> $WindowEnd). Cash now A$($CashRef.Value)" -ForegroundColor Yellow
}

# Return MinAudBuy so caller can use it consistently
[pscustomobject]@{ MinAudBuy = $MinAudBuy }
