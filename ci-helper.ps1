<#
ci-helper.ps1 — Universal GitHub Actions helper (PS 5.1 compatible)

Commands:
  normalize       Ensure on: has workflow_dispatch + push/PR on Branch
  touch           Commit a small change to trigger push filters
  dispatch        Manually dispatch workflow on Branch
  wait            Wait for latest run to complete (spinner + elapsed)
  logs            Download job logs + scan for egress hints; open run if failed
  run-all         normalize -> touch -> dispatch -> wait -> logs
  repair-and-run  enforce LF + pre-commit + push -> verify -> dispatch -> wait -> logs

Config file (.ci-helper.json) — optional keys:
{
  "Repo": "owner/name",
  "Branch": "egress-allowlist-lock",
  "Workflow": ".github/workflows/lint.yml",
  "KeepPathsFilter": false,
  "AddCommonPaths": true
}
#>

param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('normalize','touch','dispatch','wait','logs','run-all','repair-and-run')]
  [string]$Cmd,

  [string]$Repo,
  [string]$Branch,
  [string]$Workflow,

  [switch]$KeepPathsFilter,
  [switch]$AddCommonPaths,
  [switch]$NoCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail($m){ Write-Error $m; exit 1 }
function Info($m){ Write-Host "▸ $m" }
function Warn($m){ Write-Host "⚠ $m" -ForegroundColor Yellow }
function Ok($m){ Write-Host "✓ $m" -ForegroundColor Green }
function Gray($m){ Write-Host "  · $m" -ForegroundColor DarkGray }

# --- Load config (optional, resilient to arrays/missing keys) ---
$cfgPath = Join-Path (Get-Location) ".ci-helper.json"
if (Test-Path $cfgPath) {
  try {
    $cfg = (Get-Content $cfgPath -Raw) | ConvertFrom-Json
    if ($cfg -is [System.Array]) {
      if ($cfg.Count -gt 0) { $cfg = $cfg[0] } else { $cfg = $null }
    }
    if ($cfg) {
      if (-not $Repo     -and ($cfg.PSObject.Properties.Name -contains 'Repo'))     { $Repo     = $cfg.Repo }
      if (-not $Branch   -and ($cfg.PSObject.Properties.Name -contains 'Branch'))   { $Branch   = $cfg.Branch }
      if (-not $Workflow -and ($cfg.PSObject.Properties.Name -contains 'Workflow')) { $Workflow = $cfg.Workflow }
      if (($cfg.PSObject.Properties.Name -contains 'KeepPathsFilter') -and $cfg.KeepPathsFilter) { $KeepPathsFilter = $true }
      if (($cfg.PSObject.Properties.Name -contains 'AddCommonPaths')  -and $cfg.AddCommonPaths)  { $AddCommonPaths  = $true }
    }
  } catch {
    Fail "Invalid JSON in ${cfgPath}: $($_.Exception.Message)"
  }
}

# --- Basic guards & tool checks ---
$top = git rev-parse --show-toplevel 2>$null
if (-not $top) { Fail "Run inside a git repository." }
Set-Location $top
if (-not $Repo)     { Fail "-Repo not set (or config missing)." }
if (-not $Branch)   { Fail "-Branch not set (or config missing)." }

# Ensure gh is available & authed
try { gh --version | Out-Null } catch { Fail "GitHub CLI (gh) not found. Install https://cli.github.com/ then 'gh auth login'." }
try { gh auth status 2>$null | Out-Null } catch { Fail "Not authenticated to GitHub CLI. Run: gh auth login" }

# Checkout branch
$curBranch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($curBranch -ne $Branch) {
  Info "Checking out branch '$Branch' (current: '$curBranch')"
  git fetch origin $Branch 2>$null | Out-Null
  git checkout $Branch | Out-Null
}

# --- Workflow auto-discovery if not supplied ---
function Resolve-Workflow {
  param([string]$wf)
  if ($wf) { return $wf }
  $candidates = @(Get-ChildItem -Recurse -File -Include *.yml,*.yaml -Path ".github/workflows" -ErrorAction SilentlyContinue | Select-Object -Expand FullName)
  if ($candidates.Count -eq 0) { Fail "No workflow files found under .github/workflows." }
  $pick = $null
  if ($candidates.Count -eq 1) {
    $pick = $candidates[0]
  } else {
    # prefer lint/ci names
    $linty = @($candidates | Where-Object { $_ -match 'lint|ci' })
    if ($linty.Count -gt 0) { $pick = $linty[0] } else { $pick = $candidates[0] }
  }
  $rel = Resolve-Path -Relative $pick
  Info "Workflow auto-detected: $rel"
  return $rel
}
$Workflow = Resolve-Workflow -wf $Workflow

if (-not (Test-Path $Workflow)) { Fail "Workflow file not found locally: $Workflow" }

# --- Helpers ---
function Ensure-LF {
  param([string]$path)
  $raw = Get-Content $path -Raw
  $lf  = $raw -replace "`r`n","`n" -replace "`r","`n"
  if ($lf -ne $raw) {
    [IO.File]::WriteAllText($path, $lf, [Text.UTF8Encoding]::new($false))
    Ok "Normalized LF endings: $path"
  }
}

function Ensure-GitattributesLF {
  $gattr = ".gitattributes"
  $needWrite = $true
  $txt = ""
  if (Test-Path $gattr) {
    $txt = Get-Content $gattr -Raw
    if (($txt -match '\*\.yml\s+text eol=lf') -and ($txt -match '\*\.yaml\s+text eol=lf')) { $needWrite = $false }
  }
  if ($needWrite) {
    $block = "*.yml  text eol=lf`n*.yaml text eol=lf`n"
    $new = ($txt.TrimEnd() + "`r`n" + $block)
    [IO.File]::WriteAllText($gattr, $new, [Text.UTF8Encoding]::new($false))
    git add $gattr | Out-Null
    Ok "Updated .gitattributes to enforce LF for YAML"
  }
}

function Has-StagedChanges {
  $names = git diff --cached --name-only
  return -not [string]::IsNullOrWhiteSpace($names)
}

function Run-Precommit {
  param([string[]]$files)
  try { pre-commit --version | Out-Null } catch { Gray "pre-commit not installed; skipping hook run."; return }
  if ($files -and $files.Count -gt 0) {
    pre-commit run --files $files | Out-Null
  } else {
    pre-commit run --all-files | Out-Null
  }
}

function New-OnBlock {
  param([string]$branch,[bool]$keep,[bool]$addCommon,[string]$wfContent)
  $newOn = @"
on:
  workflow_dispatch:
  push:
    branches: [ $branch, main ]
"@
  $paths = @()
  if ($addCommon) {
    $paths += @(
      '".github/workflows/**"',
      '"src/**"',
      '"tests/**"',
      '"pyproject.toml"',
      '"requirements*.txt"',
      '"setup.cfg"',
      '"pre-commit-config.yaml"'
    )
  }
  if ($keep) {
    $pushPaths = New-Object System.Collections.Generic.List[string]
    $inPush = $false; $inPaths = $false
    foreach ($line in ($wfContent -split "`r?`n")) {
      if ($line -match '^\s*push\s*:\s*$') { $inPush = $true; continue }
      if ($inPush -and $line -match '^\s+\S') {
        if ($line -match '^\s*paths\s*:\s*$') { $inPaths = $true; continue }
        if ($inPaths -and $line -match '^\s*-\s*(.+)$') { $pushPaths.Add($Matches[1].Trim()) }
        elseif ($inPaths -and $line -match '^\s*\S') { $inPaths = $false }
      } elseif ($inPush -and $line -match '^\S') { break }
    }
    if ($pushPaths.Count -gt 0) { $paths = $pushPaths }
  }
  if ($paths.Count -gt 0) {
    $newOn += "`n    paths:`n"
    foreach ($p in $paths) { $newOn += "      - $p`n" }
  }
  $newOn += @"
  pull_request:
    branches: [ main ]
"@
  return $newOn
}

function Normalize-Workflow {
  if ($NoCommit) { Warn "NoCommit set — showing what would change only."; return }
  $wf = Get-Content $Workflow -Raw
  $newOn = New-OnBlock -branch $Branch -keep $KeepPathsFilter.IsPresent -addCommon $AddCommonPaths.IsPresent -wfContent $wf
  $pattern = '(?ms)^\s*on:\s*.*?(?=^\S|\Z)'
  if ($wf -match '(?m)^\s*on\s*:') {
    $wf2 = [System.Text.RegularExpressions.Regex]::Replace($wf, $pattern, $newOn)
  } else {
    $wf2 = $newOn + "`r`n" + $wf
  }
  if ($wf2 -ne $wf) {
    [IO.File]::WriteAllText($Workflow, $wf2, [Text.UTF8Encoding]::new($false))
    git add $Workflow | Out-Null
    git commit -m "ci: normalize on:; add workflow_dispatch; enable push/PR on ${Branch}" | Out-Null
    Ok "Updated workflow triggers"
  } else {
    Gray "Workflow triggers already normalized"
  }
}

function Verify-RemoteWorkflow {
  param([string]$wfRef)
  $yaml = gh workflow view $wfRef --ref $Branch --yaml 2>$null
  if (-not $yaml) {
    $name = Split-Path $wfRef -Leaf
    $yaml = gh workflow view $name --ref $Branch --yaml 2>$null
  }
  if (-not $yaml) { Fail "Could not load workflow YAML from GitHub for ref '${Branch}'." }
  if ($yaml -notmatch '(?m)^\s*workflow_dispatch\s*:') { Fail "workflow_dispatch not found on remote." }
  Ok "Verified workflow_dispatch on remote (${Branch})"
}

function Latest-RunId {
  $rl = gh run list --workflow $Workflow --branch $Branch --limit 10 --json databaseId,createdAt | ConvertFrom-Json
  if (-not $rl) { return $null }
  return ($rl | Select-Object -First 1).databaseId
}

function Do-Dispatch {
  Info "Dispatching $Workflow on ${Branch}…"
  $out = gh workflow run $Workflow --ref $Branch 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "Dispatch failed." }
  Ok "Dispatched"
}

function Do-Wait {
  $runId = Latest-RunId
  if (-not $runId) { Fail "No runs found for $Workflow on ${Branch}." }
  $start = Get-Date
  Info "Waiting for run $runId…"
  $spinner = @('|','/','-','\'); $i = 0
  while ($true) {
    $r = gh run view $runId --json status,conclusion | ConvertFrom-Json
    $state = $r.status
    $spin = $spinner[$i % $spinner.Length]; $i++
    $elapsed = (Get-Date) - $start
    Write-Host -NoNewline ("`r{0} status: {1}   elapsed: {2:mm\:ss}   " -f $spin,$state,$elapsed)
    if ($state -eq 'completed') { break }
    Start-Sleep -Seconds 3
  }
  Write-Host ""
  $c = (gh run view $runId --json conclusion | ConvertFrom-Json).conclusion
  if ($c -eq 'success') { Ok "Run $runId conclusion: $c" } else { Warn "Run $runId conclusion: $c" }
}

function Do-Logs {
  $runId = Latest-RunId
  if (-not $runId) { Fail "No runs found for $Workflow on ${Branch}." }
  Info "Fetching jobs for $runId…"
  $jobs = (gh api repos/$Repo/actions/runs/$runId/jobs | ConvertFrom-Json).jobs
  if (-not $jobs -or $jobs.Count -eq 0) { Warn "No jobs (likely skipped due to filters)."; return }
  $rows = @()
  foreach ($j in $jobs) {
    $jid = $j.id
    $out = "job-$jid.log"
    gh api repos/$Repo/actions/jobs/$jid/logs | Out-File -FilePath $out -Encoding utf8
    $rows += New-Object psobject -Property @{ Job=$j.name; Status=$j.status; Conclusion=$j.conclusion; Log=$out }
  }
  $rows | Format-Table -AutoSize
  $hits = Get-ChildItem job-*.log | ForEach-Object {
    Select-String -Path $_.FullName -Pattern 'Allow these endpoints|Detected egress to' -Context 3
  }
  if ($hits) {
    Write-Host "`n=== Potential egress allow-list notes ==="
    $hits | ForEach-Object { $_.ToString() }
    Write-Host "=== End ==="
  } else {
    Gray "No egress/allow-list hints found."
  }
  $failed = @($rows | Where-Object { $_.Conclusion -and $_.Conclusion -ne 'success' })
  if ($failed.Count -gt 0) {
    Gray "Opening run page in browser…"
    gh run view $runId --web | Out-Null
  }
}

function Commit-And-Push-IfStaged([string]$msg) {
  if (Has-StagedChanges) {
    git commit -m $msg | Out-Null
    git push | Out-Null
    Ok $msg
  } else {
    Gray "No staged changes to commit."
  }
}

# --- High-level flows ---
function Do-Normalize {
  Normalize-Workflow
  Ensure-LF -path $Workflow
  Run-Precommit -files @($Workflow)
  git add $Workflow | Out-Null
  Commit-And-Push-IfStaged "ci: fix workflow triggers + enforce LF line endings"
  Verify-RemoteWorkflow -wfRef $Workflow
}

function Do-Touch-Commit {
  if ($NoCommit) { Warn "NoCommit set — skipping touch commit."; return }
  $touch = "ci-touch.$([Guid]::NewGuid().ToString('N')).txt"
  "# noop" | Out-File -FilePath $touch -Encoding ascii
  git add $touch | Out-Null
  Commit-And-Push-IfStaged "chore: touch to trigger CI"
}

function Do-Repair-And-Run {
  Ensure-GitattributesLF
  Ensure-LF -path $Workflow
  Run-Precommit -files @($Workflow)
  git add $Workflow | Out-Null
  Commit-And-Push-IfStaged "ci: normalize line endings for workflow"
  Verify-RemoteWorkflow -wfRef $Workflow
  Do-Dispatch
  Do-Wait
  Do-Logs
}

# --- Router ---
switch ($Cmd) {
  'normalize'      { Do-Normalize }
  'touch'          { Do-Touch-Commit }
  'dispatch'       { Do-Dispatch }
  'wait'           { Do-Wait }
  'logs'           { Do-Logs }
  'run-all'        { Do-Normalize; Do-Touch-Commit; Do-Dispatch; Do-Wait; Do-Logs }
  'repair-and-run' { Do-Repair-And-Run }
}
