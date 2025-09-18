param([string]$Owner="Welsh211223",[string]$Repo="edgefinder-v5-80",[string]$Branch="main")
$full="$Owner/$Repo"
Write-Host "Protection for $full:$Branch" -ForegroundColor Cyan
gh api "repos/$full/branches/$Branch/protection" --jq '.'
Write-Host "`nRequired checks:" -ForegroundColor Yellow
gh api "repos/$full/branches/$Branch/protection/required_status_checks" --jq '.contexts'
try { gh api "repos/$full/branches/$Branch/protection/required_signatures" | Out-Null; Write-Host "`nSigned commits: Yes" -ForegroundColor Green } catch { Write-Host "`nSigned commits: No" -ForegroundColor Red }
