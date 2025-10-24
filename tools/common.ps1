# tools/common.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$m){ Write-Host "[INFO] $m" }
function Write-Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Warning $m }

function Resolve-RepoRoot {
  try { (git rev-parse --show-toplevel) 2>$null } catch { $null }
}

function Resolve-DotEnvPath {
  param([string]$FileName = ".env")
  $candidates = @()
  if ($script:PSScriptRoot) { $candidates += (Join-Path $script:PSScriptRoot $FileName) }
  $git = Resolve-RepoRoot
  if ($git) { $candidates += (Join-Path $git $FileName) }
  $candidates += (Join-Path (Get-Location).Path $FileName)
  foreach ($p in $candidates | Get-Unique) { if (Test-Path $p) { return $p } }
  return $null
}

function Read-DotEnv {
  param([Parameter(Mandatory)][string]$Path)
  $map = @{}
  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { return }
    $idx = $line.IndexOf('=')
    if ($idx -lt 1) { return }
    $key = $line.Substring(0,$idx).Trim()
    $val = $line.Substring($idx+1).Trim().Trim("'`"")
    $map[$key] = $val
  }
  return $map
}

function Save-DotEnv {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][hashtable]$Data
  )
  $lines = $Data.GetEnumerator() | Sort-Object Key | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }
  [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Test-DiscordWebhookFormat {
  param([string]$Url)
  return ($Url -match '^https://(?:discord(?:app)?\.com)/api/webhooks/\d+/\S+$')
}

function Get-DiscordWebhook {
  param(
    [string]$Explicit,
    [string]$Key = 'DISCORD_WEBHOOK_URL',
    [switch]$WriteBackIfExplicit
  )
  # 1) Explicit parameter
  if ($Explicit) {
    if (-not (Test-DiscordWebhookFormat $Explicit)) { throw "Invalid Discord webhook URL format." }
    if ($WriteBackIfExplicit) {
      $dotenv = Resolve-DotEnvPath
      if (-not $dotenv) { $dotenv = Join-Path (Resolve-RepoRoot ?? (Get-Location).Path) ".env" }
      $kv = @{}
      if (Test-Path $dotenv) { $kv = Read-DotEnv $dotenv }
      $kv[$Key] = $Explicit
      Save-DotEnv -Path $dotenv -Data $kv
      Write-Ok "Wrote/updated $Key in $dotenv"
    }
    return $Explicit
  }

  # 2) Environment variable
  if ($env:$Key) {
    if (-not (Test-DiscordWebhookFormat $env:$Key)) { throw "$Key environment variable is set but invalid." }
    return $env:$Key
  }

  # 3) .env file
  $dotenv = Resolve-DotEnvPath
  if ($dotenv) {
    $kv = Read-DotEnv $dotenv
    if ($kv.ContainsKey($Key) -and $kv[$Key]) {
      if (-not (Test-DiscordWebhookFormat $kv[$Key])) { throw "$Key in $dotenv is present but invalid." }
      return $kv[$Key]
    }
  }

  throw "Discord webhook not found. Set -DiscordWebhook (or -Webhook), or define $Key in environment or .env."
}

function Mask-Secret {
  param([string]$s)
  if (-not $s) { return '' }
  $pre = $s.Substring(0, [Math]::Min(35, $s.Length))
  $suf = $s.Substring([Math]::Max(0, $s.Length - 6))
  return "$pre…$suf"
}

function Post-Discord {
  param(
    [Parameter(Mandatory)][string]$Webhook,
    [Parameter(Mandatory)][string]$Content
  )
  $payload = @{ content = $Content } | ConvertTo-Json
  Invoke-RestMethod -Uri $Webhook -Method Post -Body $payload -ContentType 'application/json' | Out-Null
}
