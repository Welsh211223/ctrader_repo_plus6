[CmdletBinding()]
param(
  [string]$Owner="Welsh211223",
  [string]$Repo ="edgefinder-v5-80",   # <-- this repo
  [string]$Branch="main",
  [string[]]$RequiredChecks=@("block non-LFS >50MB") # add more job names if you add a lint workflow
)
$repoFull="$Owner/$Repo"

# Build JSON
$payload = [ordered]@{
  required_status_checks = @{
    strict=$true
    contexts=$RequiredChecks
  }
  enforce_admins=$true
  required_pull_request_reviews=@{
    dismiss_stale_reviews=$true
    require_code_owner_reviews=$false
    required_approving_review_count=1
    require_last_push_approval=$true
  }
  restrictions=$null
  required_linear_history=$true
  allow_force_pushes=$false
  allow_deletions=$false
  block_creations=$false
  required_conversation_resolution=$true
} | ConvertTo-Json -Depth 6

Write-Host "Applying protection to $repoFull:$Branch ..." -ForegroundColor Cyan
gh api -X PUT "repos/$repoFull/branches/$Branch/protection" --header "Accept: application/vnd.github+json" --input - <<< $payload

Write-Host "Requiring signed commits..." -ForegroundColor Cyan
gh api -X POST "repos/$repoFull/branches/$Branch/protection/required_signatures" --header "Accept: application/vnd.github+json" | Out-Null

Write-Host "Done. Review Settings ? Branches." -ForegroundColor Green
