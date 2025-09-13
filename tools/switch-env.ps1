param(
  [Parameter(Mandatory)][ValidateSet("dev","staging","prod","local")][string]$Name,
  [switch]$Load
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $full = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $full) { $full = $Path }
  [System.IO.File]::WriteAllText($full, $Content, $enc)
}
function Load-Dotenv-Into-Process { param([Parameter(Mandatory)][string]$Path)
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

$repoRoot = Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path
$envPath  = Join-Path $repoRoot ".env"
$srcPath  = Join-Path $repoRoot (".env.{0}" -f $Name)

if (-not (Test-Path $srcPath)) {
  Write-Warning "$srcPath not found. Creating it from template or current .env."
  if (Test-Path (Join-Path $repoRoot ".env.example")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot ".env.example") -Destination $srcPath -Force
  } elseif (Test-Path $envPath) {
    Copy-Item -LiteralPath $envPath -Destination $srcPath -Force
  } else {
    $tpl = @(
      "# --- CoinSpot ---"
      "COINSPOT_API_KEY="
      "COINSPOT_API_SECRET="
      "COINSPOT_LIVE_DANGEROUS=false"
      ""
      "# --- Optional notifications ---"
      "DISCORD_WEBHOOK="
    ) -join "`r`n"
    Write-Utf8NoBom -Path $srcPath -Content $tpl
  }
  Write-Host "Created $srcPath"
}

if (Test-Path $envPath) {
  $ts = Get-Date -Format "yyyyMMdd-HHmmss"
  Copy-Item -LiteralPath $envPath -Destination (Join-Path $repoRoot ".env.$ts.bak") -Force
}

Copy-Item -LiteralPath $srcPath -Destination $envPath -Force
Write-Host ("Switched environment: {0} -> .env" -f (Split-Path -Leaf $srcPath)) -ForegroundColor Green

if ($Load) {
  Load-Dotenv-Into-Process -Path $envPath
  Write-Host "Loaded .env into current session (PROCESS scope)." -ForegroundColor Green
}