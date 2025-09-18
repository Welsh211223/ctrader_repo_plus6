Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path

# Known files -> descriptions
$desc = @{
  'README.md'                              = 'Project quick-start & safety notes'
  '.env'                                   = 'Active env used by the tools'
  '.env.dev'                               = 'Saved dev env (safe default)'
  '.env.prod'                              = 'Saved prod env (only when truly live)'
  '.github/workflows/ci.yml'               = 'CI pipeline'
  'tools\set-secrets.ps1'                  = 'Prompt & write keys to .env; optional -Load'
  'tools\switch-env.ps1'                   = 'Swap .env <-> .env.dev/.env.prod; optional -Load'
  'tools\env-status.ps1'                   = 'Shows if keys are loaded in THIS shell'
  'tools\smoke-coinspot.ps1'               = 'Read-only balances check'
  'tools\safe-run.ps1'                     = 'Run any command with paper mode forced on'
  'tools\run-backtest.ps1'                 = 'Run ctrader backtest in paper mode'
  'tools\live-preflight.ps1'               = 'Live safety checklist (blocks if unsafe)'
  'src\ctrader\utils\live_guard.py'        = 'Guard that blocks accidental live orders'
  'src\ctrader\execution\coinspot_execution.py' = 'Safe placeholder executor'
}

Write-Host "=== Annotated project files ===" -ForegroundColor Cyan

Get-ChildItem -Path $repo -Recurse -File | ForEach-Object {
  $full = $_.FullName
  $rel  = $full
  $prefix = ($repo + [IO.Path]::DirectorySeparatorChar)

  if ($full.ToLower().StartsWith($prefix.ToLower())) {
    $rel = $full.Substring($prefix.Length)
  }

  # Try both slash styles for lookup
  $note = $desc[$rel]
  if (-not $note) { $note = $desc[$rel -replace '/','\'] }
  if (-not $note) { $note = $desc[$rel -replace '\\','/'] }

  $noteText = if ($note) { " - $note" } else { "" }
  "{0,10}  {1}  {2}" -f $_.Length, $rel, $noteText
}
