Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-CoinSpotNonce {
  # Nonce must be unique per request; ticks is fine.
  return [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

function Get-HmacSha512Hex {
  param(
    [Parameter(Mandatory=$true)][string]$Secret,
    [Parameter(Mandatory=$true)][string]$Message
  )
  $enc = [Text.Encoding]::UTF8
  $keyBytes = $enc.GetBytes($Secret)
  $msgBytes = $enc.GetBytes($Message)

  $h = [System.Security.Cryptography.HMACSHA512]::new($keyBytes)
  try {
    ($h.ComputeHash($msgBytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  } finally {
    $h.Dispose()
  }
}

function Invoke-CoinSpotV2 {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path, # e.g. "/quote/buy/now"
    [Parameter(Mandatory=$true)][hashtable]$Body,
    [Parameter()][string]$ApiKey = $env:COINSPOT_API_KEY,
    [Parameter()][string]$ApiSecret = $env:COINSPOT_API_SECRET
  )

  if ([string]::IsNullOrWhiteSpace($ApiKey))    { throw "Missing COINSPOT_API_KEY env var." }
  if ([string]::IsNullOrWhiteSpace($ApiSecret)) { throw "Missing COINSPOT_API_SECRET env var." }

  $root = "https://www.coinspot.com.au/api/v2"
  $nonce = New-CoinSpotNonce

  # CoinSpot expects nonce in request body for signed endpoints (common pattern).
  # We include it for all calls to keep consistent.
  $Body["nonce"] = $nonce

  $json = ($Body | ConvertTo-Json -Compress)
  $sig  = Get-HmacSha512Hex -Secret $ApiSecret -Message $json

  $headers = @{
    "key"  = $ApiKey
    "sign" = $sig
    "Content-Type" = "application/json"
  }

  $uri = $root.TrimEnd("/") + $Path

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $json -TimeoutSec 30
    return $resp
  } catch {
    throw "CoinSpot API call failed: $Path :: $($_.Exception.Message)"
  }
}
