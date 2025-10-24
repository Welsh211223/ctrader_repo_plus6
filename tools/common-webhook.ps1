# tools/common-webhook.ps1
# Shared Discord webhook utilities for all project scripts.

# Compute repo root from the /tools directory
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:DefaultDotEnv = Join-Path $script:RepoRoot ".env"

function Get-DotEnvValue {
    param(
        [string]$Key,
        [string]$Path = $script:DefaultDotEnv
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } |
            Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -replace "^\s*$([regex]::Escape($Key))\s*=\s*", "").Trim("`"' ")
}

function Import-DotEnv {
    param([string]$Path = $script:DefaultDotEnv)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($ln in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($ln -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $k = $matches[1]; $v = $matches[2].Trim("`"' ")
            Set-Item -Path ("Env:{0}" -f $k) -Value $v
        }
    }
}

function Resolve-DiscordWebhook {
    param([string]$Explicit)

    # 1) explicit param
    $url = $Explicit
    # 2) env var
    if (-not $url -or -not $url.Trim()) { $url = $env:DISCORD_WEBHOOK_URL }
    # 3) .env
    if (-not $url -or -not $url.Trim()) {
        Import-DotEnv
        $url = Get-DotEnvValue -Key "DISCORD_WEBHOOK_URL"
    }
    if (-not $url -or -not $url.Trim()) { return $null }

    # Normalize + validate
    $url = $url.Trim("`"' ").Trim()
    $url = $url -replace '^https://discordapp\.com', 'https://discord.com'
    if ($url -notmatch '^https://discord\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+' ) {
        throw "Discord webhook URL looks invalid. Expect https://discord.com/api/webhooks/<id>/<token>"
    }
    return $url
}

function Notify-Discord {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Webhook
    )
    $hook = Resolve-DiscordWebhook -Explicit $Webhook
    if (-not $hook) { throw "No webhook provided and DISCORD_WEBHOOK_URL not found in env or .env" }

    $payload = @{ content = $Message } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $hook -ContentType "application/json" -Body $payload -ErrorAction Stop | Out-Null
    Write-Host "[ OK ] Sent Discord notification" -ForegroundColor Green
}
