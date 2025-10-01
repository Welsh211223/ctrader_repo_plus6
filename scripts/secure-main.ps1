[CmdletBinding()]
param(
  [string]$Owner = "Welsh211223",
  [string]$Repo  = "ctrader_repo_plus6",
  [string]$Branch = "main",
  [string[]]$RequiredChecks = @("size-check","black","ruff","ruff-format","isort","detect-secrets")
)
$gh = $null
try { $gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not $gh) { $gh = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path $gh)) { throw "GitHub CLI not found." }
$repoFull = "$Owner/$Repo"
Write-Host ("Applying protection to {0}:{1} ..." -f $repoFull,$Branch) -ForegroundColor Cyan
$payload = [ordered]@{
  required_status_checks = @{ strict = $true; contexts = $RequiredChecks }
  enforce_admins = $true
  required_pull_request_reviews = @{ dismiss_stale_reviews=$true; require_code_owner_reviews=$false; required_approving_review_count=1; require_last_push_approval=$true }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
} | ConvertTo-Json -Depth 6
$null = $payload | & $gh api -X PUT ("repos/{0}/branches/{1}/protection" -f $repoFull,$Branch) --header "Accept: application/vnd.github+json" --input -
& $gh api -X POST ("repos/{0}/branches/{1}/protection/required_signatures" -f $repoFull,$Branch) --header "Accept: application/vnd.github+json" | Out-Null
Write-Host "Done. Review Settings â†’ Branches." -ForegroundColor Green
