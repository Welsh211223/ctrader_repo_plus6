# Fix ctrader-upgrade-all.ps1 for Windows PowerShell 5.1 (remove ?: ternary)
$path = ".\tools\ctrader-upgrade-all.ps1"
if (-not (Test-Path -LiteralPath $path)) { throw "File not found: $path" }
$s = Get-Content -LiteralPath $path -Raw

$pattern = '(?ms)function\s+Append-IfMissing\(\[string\]\$Path,\[string\]\$Marker,\[string\]\$Block\)\s*\{.*?\}'
$replacement = @'
function Append-IfMissing([string]$Path,[string]$Marker,[string]$Block){
  $cur = ""
  if (Test-Path -LiteralPath $Path) {
    $cur = Get-Content -LiteralPath $Path -Raw
  }
  if ($cur -notmatch [regex]::Escape($Marker)) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Add-Content -LiteralPath $Path -Value "`n$Block"
    Ok "Appended to $Path"
  } else {
    Info "$Path already has $Marker"
  }
}
'@

$s2 = [regex]::Replace($s, $pattern, $replacement)
[System.IO.File]::WriteAllText($path, (($s2 -replace "`r`n","`n") -replace "`r","`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "[ OK ] Patched $path for WinPS 5.1" -ForegroundColor Green
