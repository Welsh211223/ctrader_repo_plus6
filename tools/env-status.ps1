$envFile = Join-Path (Resolve-Path "$PSScriptRoot\..") ".env"
$hasKey = [bool]$env:COINSPOT_API_KEY
$hasSec = [bool]$env:COINSPOT_API_SECRET
Write-Host "Active: $envFile"
Write-Host "COINSPOT_API_KEY loaded?  $hasKey"
Write-Host "COINSPOT_API_SECRET loaded?  $hasSec"
