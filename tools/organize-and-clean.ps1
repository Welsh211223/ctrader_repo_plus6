param(
  [switch]$DryRun,
  [switch]$PurgeCaches,
  [switch]$Delete,
  [switch]$GitCommit,
  [string]$Message = "chore: organize workspace (archive backups, clean caches)"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$ts   = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveRoot = Join-Path $repo ".archive"
$archive     = Join-Path $archiveRoot $ts

# Create archive roots up front (recursively)
[System.IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
if (-not $DryRun) { [System.IO.Directory]::CreateDirectory($archive) | Out-Null }

# Helpers
function Get-RelPath([string]$full) {
  $prefix = ($repo + [IO.Path]::DirectorySeparatorChar)
  if ($full.ToLower().StartsWith($prefix.ToLower())) { return $full.Substring($prefix.Length) }
  return $full
}
function Ensure-Parent([string]$destPath) {
  $parent = Split-Path -Parent $destPath
  if (![string]::IsNullOrWhiteSpace($parent)) {
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null  # creates full chain
  }
}
function Matches-AnyPattern([string]$name, [string[]]$patterns) {
  foreach ($pat in $patterns) {
    $wc = New-Object System.Management.Automation.WildcardPattern($pat, 'IgnoreCase')
    if ($wc.IsMatch($name)) { return $true }
  }
  return $false
}

# Safety: never touch .env files; also skip virtualenv and archive itself
$protectedNames = @(".env",".env.dev",".env.prod",".env.staging",".env.local")
$skipRoots = @(
  (Join-Path $repo ".venv"),
  (Join-Path $repo ".archive"),
  (Join-Path $repo ".git")
)

# What to archive (move) as "debris/backups"
$backupPatterns = @("*.bak","*.broken","*.old","*.tmp","*~",".DS_Store","Thumbs.db")

# What caches/build artifacts to purge (when -PurgeCaches is set)
$cacheDirNames = @("__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "build", "dist")
$cacheFilePatterns = @("*.pyc")

[int]$moved = 0
[int]$deleted = 0

Write-Host "Repo: $repo" -ForegroundColor Cyan

function Should-Skip([string]$fullPath) {
  foreach ($root in $skipRoots) {
    if ($fullPath.ToLower().StartsWith($root.ToLower())) { return $true }
  }
  return $false
}

# 1) Move backup/debris files into .archive\<timestamp>
Get-ChildItem -Path $repo -Recurse -Force -File | ForEach-Object {
  if (Should-Skip $_.FullName) { return }

  $rel = Get-RelPath $_.FullName
  if ($protectedNames -contains $rel) { return }

  if (Matches-AnyPattern -name $_.Name -patterns $backupPatterns) {
    $dest = Join-Path $archive $rel
    if ($DryRun) {
      Write-Host "[MOVE] $rel  ->  .archive\$ts\$rel"
    } else {
      Ensure-Parent $dest
      try {
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop
      } catch {
        # One more ensure + retry in case of a race
        Start-Sleep -Milliseconds 50
        Ensure-Parent $dest
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force
      }
    }
    $script:moved++
  }
}

# 2) Purge caches/build artifacts (optional)
if ($PurgeCaches) {
  # Directories by name
  Get-ChildItem -Path $repo -Recurse -Force -Directory | Where-Object {
    -not (Should-Skip $_.FullName) -and ($cacheDirNames -contains $_.Name)
  } | ForEach-Object {
    $rel = Get-RelPath $_.FullName
    if ($DryRun) {
      Write-Host "[DEL-DIR] $rel"
    } else {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:deleted++
  }

  # .egg-info directories
  Get-ChildItem -Path $repo -Recurse -Force -Directory | Where-Object {
    -not (Should-Skip $_.FullName) -and ($_.Name -like "*.egg-info")
  } | ForEach-Object {
    $rel = Get-RelPath $_.FullName
    if ($DryRun) {
      Write-Host "[DEL-DIR] $rel"
    } else {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:deleted++
  }

  # Cache file patterns (e.g., *.pyc)
  foreach ($pat in $cacheFilePatterns) {
    Get-ChildItem -Path $repo -Recurse -Force -File -Filter $pat | ForEach-Object {
      if (Should-Skip $_.FullName) { return }
      $rel = Get-RelPath $_.FullName
      if ($DryRun) {
        Write-Host "[DEL] $rel"
      } else {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      }
      $script:deleted++
    }
  }
}

# 3) Optional Git commit
if ($GitCommit) {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $git) {
    Write-Warning "Git not found on PATH; skipping commit."
  } else {
    if ($DryRun) {
      Write-Host "[GIT] Would run: git add -A ; git commit -m `"$Message`""
    } else {
      & git add -A | Out-Null
      $st = (& git status --porcelain)
      if ($st) {
        & git commit -m $Message | Out-Null
        Write-Host "Committed changes: $Message" -ForegroundColor Green
      } else {
        Write-Host "No changes to commit." -ForegroundColor Yellow
      }
    }
  }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host ("  Moved to .archive: {0}" -f $moved)
if ($PurgeCaches) { Write-Host ("  Deleted caches:    {0}" -f $deleted) }
if (-not $DryRun -and (Test-Path $archive) -and (Get-ChildItem $archive -Recurse -Force | Measure-Object).Count -gt 0) {
  Write-Host ("  Archive folder:    {0}" -f $archive)
}
