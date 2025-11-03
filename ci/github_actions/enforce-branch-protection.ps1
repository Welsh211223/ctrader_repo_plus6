#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [string]$Branch = "main",
  [int]$RequiredReviewers = 1,
  [string[]]$RequiredChecks = @("ctrader-ci")
)

if (-not $env:GITHUB_TOKEN) { throw "GITHUB_TOKEN env var is required." }

$baseUrl = "https://api.github.com"
$headers = @{
  "Authorization" = "Bearer $($env:GITHUB_TOKEN)"
  "Accept"        = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent" = "pwsh"
  "Content-Type" = "application/json"
}

$body = @{
  required_status_checks = @{ strict = $true; contexts = $RequiredChecks }
  enforce_admins = $true
  required_pull_request_reviews = @{
    required_approving_review_count = $RequiredReviewers
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $false
  }
  restrictions = $null
  allow_force_pushes = $false
  allow_deletions = $false
} | ConvertTo-Json -Depth 6

$uri = "$baseUrl/repos/$Owner/$Repo/branches/$Branch/protection"
Write-Host "Applying branch protection to $Owner/$Repo [$Branch]..."
Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body | Out-Null
Write-Host "Branch protection applied."

$verify = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
$verify | ConvertTo-Json -Depth 6
