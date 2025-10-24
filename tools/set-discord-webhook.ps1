# tools/set-discord-webhook.ps1
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvPath  = Join-Path $RepoRoot ".env"

Write-Host "Paste your Discord webhook URL and press Enter (input is hidden)..." -ForegroundColor Yellow
$sec = Read-Host -AsSecureString

# Convert SecureString to string in-memory only
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $hook = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$hook = $hook.Trim() -replace '^https://discordapp\.com','https://discord.com'
if ($hook -notmatch '^https://discord\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+') {
    throw "That doesn't look like a Discord webhook URL."
}

# Write minimal .env (UTF-8, no BOM)
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($EnvPath, ("DISCORD_WEBHOOK_URL={0}`n" -f $hook), $enc)
Write-Host "[ OK ] .env updated with new webhook" -ForegroundColor Green

# Put it in this session too
$env:DISCORD_WEBHOOK_URL = $hook

# Optional: tighten ACLs for your user
try {
    $who = "$($env:USERDOMAIN)\$($env:USERNAME)"
    icacls $EnvPath /inheritance:r /grant:r ($who + ':(M)') | Out-Null
    Write-Host "[ OK ] Tightened .env ACL to current user" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Couldn't change ACLs: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# Smoke test (optional)
try {
    . "$PSScriptRoot\common-webhook.ps1"
    Notify-Discord -Message "ctrader: webhook configured ✅" -Webhook $hook
    Write-Host "[ OK ] Test message sent" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Test post failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
}
