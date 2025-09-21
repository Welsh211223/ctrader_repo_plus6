[CmdletBinding()]
param(
  [string]$Owner = "Welsh211223",
  [string]$Repo  = "ctrader_repo_plus6",
  [string]$Branch = "main"
)
$gh = $null
try { $gh = (Get-Command gh -ErrorAction Stop).Source } catch { }
if (-not $gh) { $gh = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe' }
if (-not (Test-Path $gh)) { throw "GitHub CLI not found." }
$full = "$Owner/$Repo"
Write-Host ("Protection for {0}:{1}" -f $full,$Branch) -ForegroundColor Cyan
& $gh api ("repos/{0}/branches/{1}/protection" -f $full,$Branch) --jq '.' | Out-String | Write-Output
Write-Host "
Required checks:" -ForegroundColor Yellow
& $gh api ("repos/{0}/branches/{1}/protection/required_status_checks" -f $full,$Branch) --jq '.contexts' | Out-String | Write-Output
try { & $gh api ("repos/{0}/branches/{1}/protection/required_signatures" -f $full,$Branch) | Out-Null; Write-Host "
Signed commits: Yes" -ForegroundColor Green } catch { Write-Host "
Signed commits: No" -ForegroundColor Red }
