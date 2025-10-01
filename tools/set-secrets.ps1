param([switch]$Load)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $full = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $full) { $full = $Path }
  [System.IO.File]::WriteAllText($full, $Content, $enc)
}

function Load-Dotenv-Into-Process {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { return }
  Get-Content -LiteralPath $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $kv = $_ -split '=', 2
    if ($kv.Length -eq 2) {
      $k = $kv[0].Trim(); $v = $kv[1]
      $v = $v -replace '^\s*"(.*)"\s*$', '$1'
      $v = $v -replace "^\s*'(.*)'\s*$", '$1'
      [Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }
  }
}

function Upsert-Line {
  param([string[]]$Lines, [string]$Key, [string]$Val)
  if ($null -eq $Lines) { $Lines = @() }
  $found = $false
  for ($i=0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
      $Lines[$i] = "$Key=$Val"; $found = $true; break
    }
  }
  if (-not $found) { $Lines += "$Key=$Val" }
  return $Lines
}

$repoRoot = Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path
$envPath  = Join-Path $repoRoot ".env"

if (Test-Path $envPath) {
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  Copy-Item -LiteralPath $envPath -Destination (Join-Path $repoRoot ".env.$ts.bak") -Force
  Write-Host "Backed up .env -> .env.$ts.bak"
}

$key = Read-Host "Paste COINSPOT_API_KEY"
$secSecure = Read-Host "Paste COINSPOT_API_SECRET (hidden)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secSecure)
$secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($secret)) {
  throw "Key/secret cannot be empty."
}

# PS5-safe: read then split
$lines = @()
if (Test-Path $envPath) {
  $raw = Get-Content -LiteralPath $envPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ($null -ne $raw) {
    $raw = $raw -replace "`r`n", "`n"
    $lines = $raw -split "`n"
  }
}
$lines = Upsert-Line -Lines $lines -Key 'COINSPOT_API_KEY' -Val $key
$lines = Upsert-Line -Lines $lines -Key 'COINSPOT_API_SECRET' -Val $secret
if ($lines -notcontains 'COINSPOT_LIVE_DANGEROUS=false' -and ($lines -join "`n") -notmatch '^\s*COINSPOT_LIVE_DANGEROUS\s*=') {
  $lines += 'COINSPOT_LIVE_DANGEROUS=false'
}

Write-Utf8NoBom -Path $envPath -Content (($lines -join "`r`n") + "`r`n")
Write-Host "Wrote .env âœ…"

try { & icacls $envPath /inheritance:r /grant:r "$env:USERNAME:(M)" | Out-Null }
catch { Write-Warning ("Could not restrict ACL on {0}: {1}" -f $envPath, $_) }

if ($Load) {
  Load-Dotenv-Into-Process -Path $envPath
  Write-Host "Loaded .env into current session (PROCESS scope)." -ForegroundColor Green
}

@"
Next:
 - Optional quick check:  powershell -ExecutionPolicy Bypass -File .\tools\smoke-coinspot.ps1
 - If you ever pasted keys in terminals/chats, rotate them from your exchange dashboard.
"@ | Write-Host
