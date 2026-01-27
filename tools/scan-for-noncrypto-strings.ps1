[CmdletBinding()]
param(
  [string]$Root = ".",
  [string[]]$Patterns = @(
    "SERPAPI","serpapi","image_replace","RubyOps","asterandruby",
    "option_b_serpapi_grouped","SEO\\image_replace","Aster & Ruby"
  ),

  # Exclude paths (regex fragments)
  [string[]]$ExcludePathRegex = @(
    '\\\.git\\',
    '\\\.venv\\',
    '\\venv\\',
    '\\__pycache__\\',
    '\\node_modules\\',
    '\\logs\\',
    '\\dist\\',
    '\\build\\',
    '\.bak(_|$)',   # ignore any *.bak*
    '\.old$',
    '~$',
    '\\tools\\scan-for-noncrypto-strings\.ps1$'   # don't match ourselves
  )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Is-Excluded([string]$fullPath) {

  # Hard excludes for our own restorepoints/backups
  if ($fullPath -match 'scan-for-noncrypto-strings\.ps1\.RESTOREPOINT_') { return $true }
  if ($fullPath -match 'scan-for-noncrypto-strings\.ps1\.bak_')         { return $true }
  if ($fullPath -match '\.bak(_|$)')                                    { return $true }
foreach ($rx in $ExcludePathRegex) {
    if ($fullPath -match $rx) { return $true }
  }
  return $false
}

# PS5-safe recurse (Select-String -Recurse is not available everywhere)
$files = Get-ChildItem -Path $Root -File -Recurse -ErrorAction SilentlyContinue |
  Where-Object { -not (Is-Excluded $_.FullName) }

$hits = foreach ($p in $Patterns) {
  Select-String -Path $files.FullName -Pattern $p -ErrorAction SilentlyContinue |
    Select-Object @{n="Pattern";e={$p}}, Path, LineNumber, Line
}

if ($hits) {
  Write-Host "[FAIL] Found non-crypto references:" -ForegroundColor Red
  $hits | Sort-Object Path, LineNumber | Format-Table Pattern, Path, LineNumber, Line -Auto
  exit 2
} else {
  Write-Host "[OK] Clean: no non-crypto references found (excluding backups/junk dirs)." -ForegroundColor Green
}
