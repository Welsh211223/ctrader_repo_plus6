<#  tools/secure-main.ps1
    Hardens the main branch via GitHub API (gh CLI).
    Usage (safe defaults):
      pwsh -File .\tools\secure-main.ps1

    With auto-detected required checks & tag protection:
      pwsh -File .\tools\secure-main.ps1 -AutoDetectChecks -ProtectTags

    If you want CODEOWNERS created for yourself:
      pwsh -File .\tools\secure-main.ps1 -CreateCodeowners -Codeowner '@Welsh211223'
#>

[CmdletBinding()]
param(
  [string]$Branch = 'main',
  [switch]$AutoDetectChecks,          # detect job/check names from latest successful run on $Branch
  [switch]$StrictUpToDate,            # require branches to be up-to-date when using checks
  [switch]$ProtectTags,               # create tag protection for v* (release tags)
  [string]$TagPattern = 'v*',
  [switch]$CreateCodeowners,
  [string]$Codeowner = '@your-handle', # set to @Welsh211223 for you
  [switch]$RequireSignedCommits        # try to enable "require signed commits" (best-effort)
)

function Fail($m){ Write-Error $m; exit 1 }
function Need($tool){
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "Missing '$tool'. Install or add to PATH." }
}

# Pre-reqs
Need git; Need gh
if (-not (gh auth status 2>$null)) { Fail "gh is not authenticated. Run: gh auth login" }

# Discover owner/repo
$origin = (git remote get-url origin) 2>$null
if (-not $origin) { Fail "No 'origin' remote found." }
$ownerRepo = $origin -replace '.*github\.com[:/]|\.git$',''
if ($ownerRepo -notmatch '.+/.+') { Fail "Could not parse owner/repo from: $origin" }
$owner,$repo = $ownerRepo -split '/'

Write-Host "Securing $owner/$repo on branch '$Branch'..." -ForegroundColor Cyan

# Optional: CODEOWNERS
if ($CreateCodeowners) {
  $dir = ".github"
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $co = Join-Path $dir "CODEOWNERS"
  if (-not (Test-Path $co)) {
    if ($Codeowner -eq '@your-handle') { Write-Warning "Set -Codeowner to your GitHub handle (e.g., @Welsh211223)"; }
    Set-Content -Path $co -Value ("* " + $Codeowner) -Encoding utf8
    git add $co
    Write-Host "Created .github/CODEOWNERS → $Codeowner" -ForegroundColor Green
  } else {
    Write-Host "CODEOWNERS already exists; leaving as-is." -ForegroundColor Yellow
  }
}

# Optional: auto-detect required status checks from latest successful run
$checksPayload = $null
if ($AutoDetectChecks) {
  # Get last successful workflow run on $Branch, then use its head SHA
  $run = gh run list -b $Branch -L 20 --json status,conclusion,headSha \
        | ConvertFrom-Json | Where-Object { $_.status -eq 'completed' -and $_.conclusion -eq 'success' } | Select-Object -First 1
  if ($run -and $run.headSha) {
    $sha = $run.headSha
    # Fetch check runs for that commit; gather names as contexts
    $cr = gh api "repos/$owner/$repo/commits/$sha/check-runs?per_page=100" --jq ".check_runs[].name" 2>$null
    $names = $cr -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne "" } | Sort-Object -Unique
    if ($names.Count -gt 0) {
      $checksPayload = @{
        strict = $StrictUpToDate.IsPresent
        checks = @($names | ForEach-Object { @{ context = $_ } })
      }
      Write-Host "Detected required checks: $($names -join ', ')" -ForegroundColor Green
    } else {
      Write-Warning "No check run names detected; skipping required checks."
    }
  } else {
    Write-Warning "No successful runs found on '$Branch'; skipping required checks."
  }
}

# Build protection body
$prReviews = @{
  dismiss_stale_reviews = $true
  required_approving_review_count = 0     # set to 1+ when you have another reviewer
  require_code_owner_reviews = $false     # toggle true when CODEOWNERS matters
  require_last_push_approval = $false
}

$body = @{
  enforce_admins = $true
  required_linear_history = @{ enabled = $true }
  required_conversation_resolution = @{ enabled = $true }
  allow_force_pushes = @{ enabled = $false }
  allow_deletions = @{ enabled = $false }
  required_pull_request_reviews = $prReviews
  required_status_checks = $checksPayload  # null == disabled
} | ConvertTo-Json -Depth 8

$tmp = New-TemporaryFile
Set-Content $tmp $body -Encoding utf8

# Apply protection
gh api -X PUT "repos/$owner/$repo/branches/$Branch/protection" --input $tmp | Out-Null
Remove-Item $tmp
Write-Host "Branch protection applied." -ForegroundColor Green

# Optional: require signed commits (best-effort; silently warn if not supported)
if ($RequireSignedCommits) {
  try {
    gh api -X PUT "repos/$owner/$repo/branches/$Branch/protection/required_signatures" | Out-Null
    Write-Host "Require signed commits: enabled." -ForegroundColor Green
  } catch {
    Write-Warning "Could not enable 'Require signed commits' via API (repo plan/permissions?). Set in UI if needed."
  }
}

# Optional: tag protection (e.g., v1.2.3)
if ($ProtectTags) {
  try {
    gh api -X POST "repos/$owner/$repo/tags/protection" -f pattern="$TagPattern" | Out-Null
    Write-Host "Tag protection added for pattern: $TagPattern" -ForegroundColor Green
  } catch {
    Write-Warning "Could not add tag protection (already exists or permissions)."
  }
}

# Print confirmation (key flags)
$prot = gh api "repos/$owner/$repo/branches/$Branch/protection" --jq "{enforce_admins, required_linear_history, required_conversation_resolution, allow_force_pushes, allow_deletions, required_pull_request_reviews, required_status_checks}"
Write-Host "`nCurrent protection:" -ForegroundColor Cyan
$prot
Write-Host "`nDone." -ForegroundColor Green
