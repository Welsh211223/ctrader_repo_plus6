[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Owner,
  [Parameter(Mandatory)][string]$Repo,
  [string]$UserToInvite,
  [ValidateSet("pull","triage","push","maintain","admin")]
  [string]$Permission = "push"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ok  ($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[XX] $m" -ForegroundColor Red; throw $m }

if(-not $env:GITHUB_TOKEN){ Die "Set `$env:GITHUB_TOKEN with a valid PAT." }

$BaseUrl = 'https://api.github.com'
$Headers = @{
  "Authorization"       = "token $($env:GITHUB_TOKEN)"
  "Accept"              = "application/vnd.github+json"
  "User-Agent"          = "pwsh"
  "X-GitHub-Api-Version"= "2022-11-28"
}

# --- 1) Who am I + show scope headers if present
$resp = Invoke-WebRequest -Uri "$BaseUrl/user" -Headers $Headers -Method GET
$user = ($resp.Content | ConvertFrom-Json)
Ok "Authed as $($user.login)"

# Header names can vary by casing; resolve case-insensitively
function Get-Header([hashtable]$H,[string]$Name){
  foreach($k in $H.Keys){ if($k -ieq $Name){ return $H[$k] } }
  return $null
}
$xoauth    = Get-Header $resp.Headers 'X-OAuth-Scopes'
$xaccepted = Get-Header $resp.Headers 'X-Accepted-OAuth-Scopes'
Info ("Token scopes header: " + ($xoauth    | Out-String)).Trim()
Info ("Endpoint expects   : " + ($xaccepted | Out-String)).Trim()

# --- 2) Repo permission sanity (are you admin?)
$repo = Invoke-RestMethod -Uri "$BaseUrl/repos/$Owner/$Repo" -Headers $Headers -Method GET
$admin = $repo.permissions.admin
$push  = $repo.permissions.push
Info "Your repo perms → admin: $admin, push: $push"
if(-not $admin){ Warn "You are NOT admin with this token → collaborator invites will 403." }

# --- 3) Print branch protection if token can read it
try {
  $prot = Invoke-RestMethod -Uri "$BaseUrl/repos/$Owner/$Repo/branches/main/protection" -Headers $Headers
  Ok "Branch protection readable (you have admin on token)."
} catch {
  Warn "Branch protection not readable with this token (likely missing Administration permission)."
}

# --- 4) Optional: send invite
if($UserToInvite){
  Info "Inviting '$UserToInvite' with '$Permission'…"
  $inviteUri = "$BaseUrl/repos/$Owner/$Repo/collaborators/$UserToInvite`?permission=$Permission"
  try {
    $inviteResp = Invoke-RestMethod -Method PUT -Headers $Headers -Uri $inviteUri
    if ($inviteResp -and $inviteResp.id) { Ok "Invitation created (id: $($inviteResp.id))." }
    else { Ok "Collaborator already added (204 path)." }
  } catch {
    Warn "Invite failed. Raw message:"
    Write-Host $_.ErrorDetails.Message -ForegroundColor Yellow
    if(-not $admin){
      Warn "Cause: token user isn’t an admin on $Owner/$Repo."
    } else {
      Warn "Fine-grained token? Ensure: Repository → Administration = Read & write, and repo '$Owner/$Repo' is selected."
      Warn "Classic PAT? Ensure scope includes 'repo'."
      Warn "If org enforces SSO, open the token page and click 'Enable SSO' for the org."
    }
    Die "Fix token scopes and re-run."
  }
} else {
  Warn "No -UserToInvite provided; skipping invite step."
}
