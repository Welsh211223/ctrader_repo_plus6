param([int]$MaxPasses = 5)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
for ($i=1; $i -le $MaxPasses; $i++) {
  pre-commit run -a
  if ($LASTEXITCODE -eq 0) { Write-Host "âœ… Hooks green on pass #$i"; exit 0 }
  git add -A
  if ($i -eq $MaxPasses) { Write-Warning "Hooks still not green after $i passes."; exit 1 }
}