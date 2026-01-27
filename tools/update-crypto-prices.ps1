param(
    [string]$OutPath
)

$ErrorActionPreference = "Stop"

if (-not $OutPath) {
    $root    = Split-Path -Parent $PSCommandPath
    $logsDir = Join-Path (Join-Path $root "..") "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir | Out-Null
    }
    $OutPath = Join-Path $logsDir "crypto_prices.csv"
}

Write-Host "[INFO] Writing crypto prices to $OutPath"

$uri = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=aud&include_24hr_change=true"

Write-Host "[INFO] Fetching from $uri"
$data = Invoke-RestMethod -Method GET -Uri $uri

$now = [DateTime]::UtcNow.ToString("s")

$rows = @()

if ($data.bitcoin) {
    $rows += [PSCustomObject]@{
        symbol      = "BTC/AUD"
        price_aud   = [decimal]$data.bitcoin.aud
        change_24h  = ($data.bitcoin."aud_24h_change"   -as [decimal])
        ts_utc      = $now
    }
}
if ($data.ethereum) {
    $rows += [PSCustomObject]@{
        symbol      = "ETH/AUD"
        price_aud   = [decimal]$data.ethereum.aud
        change_24h  = ($data.ethereum."aud_24h_change"  -as [decimal])
        ts_utc      = $now
    }
}

if (-not $rows) {
    Write-Host "[WARN] No rows returned from API." -ForegroundColor Yellow
    return
}

$rows | Export-Csv -Path $OutPath -Encoding UTF8 -NoTypeInformation

Write-Host "[OK] Crypto prices written to $OutPath"
