function Use-TokenFromSecret {
    param([string]$Name = 'GITHUB_TOKEN')
    try {
        $tok = Get-Secret $Name -AsPlainText
    } catch {
        return "[!!] SecretStore not available or secret '$Name' missing."
    }
    if ($tok) {
        $env:GITHUB_TOKEN = $tok
        return "[OK] Loaded $Name from SecretStore."
    } else {
        return "[!!] Secret $Name not found."
    }
}

function Use-TokenFromUserEnv {
    $tok = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN','User')
    if ($tok) {
        $env:GITHUB_TOKEN = $tok
        return "[OK] Loaded GITHUB_TOKEN from user env."
    } else {
        return "[!!] User env var GITHUB_TOKEN missing."
    }
}

function Save-TokenToSecret {
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$Name = 'GITHUB_TOKEN'
    )
    $clean = $Token.Trim() -replace '\s',''
    Set-Secret -Name $Name -Secret $clean
    return "[OK] Saved token to SecretStore as '$Name'."
}

function Show-TokenSanity {
    param(
        [string]$Owner = 'Welsh211223',
        [string]$Repo  = 'ctrader_repo_plus6'
    )

    if (-not $env:GITHUB_TOKEN) {
        return "[!!] GITHUB_TOKEN not set."
    }

    $H = @{
        Authorization          = "Bearer $env:GITHUB_TOKEN"
        Accept                 = "application/vnd.github+json"
        'User-Agent'           = 'pwsh'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    try {
        $me = Invoke-RestMethod -Headers $H -Uri "https://api.github.com/user"
        $r  = Invoke-RestMethod -Headers $H -Uri "https://api.github.com/repos/$Owner/$Repo"
        "[OK] User: {0} | Admin:{1} Push:{2}" -f $me.login, $r.permissions.admin, $r.permissions.push

        try {
            Invoke-RestMethod -Headers $H -Uri "https://api.github.com/repos/$Owner/$Repo/branches/main/protection" | Out-Null
            "[OK] Branch protection readable (Administration granted)."
        } catch {
            "[..] Branch protection not readable (Administration may be missing)."
        }
    } catch {
        "[XX] GitHub API auth failed: $($_.Exception.Message)"
    }
}
