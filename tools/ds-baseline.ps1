$ErrorActionPreference = 'Stop'
function Ok($m){ Write-Host "✓ $m" -ForegroundColor Green }
function Info($m){ Write-Host "• $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "⚠ $m" -ForegroundColor Yellow }

# ensure venv tools are available
if (-not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
  if (Test-Path .\.venv\Scripts\Activate.ps1) { . .\.venv\Scripts\Activate.ps1 }
}
python -m pip -q install -U pre-commit detect-secrets | Out-Null

# minimal pre-commit config if missing
$pc = ".pre-commit-config.yaml"
if (-not (Test-Path $pc)) {
  @"
exclude: ^(logs/|out/|\.venv/|\.git/)|
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: mixed-line-ending
        args: [--fix=lf]
      - id: detect-private-key
        exclude: ^secrets/.*example.*\.json$
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: [--baseline, .secrets.baseline]
"@ | Set-Content -Encoding utf8 -NoNewline $pc
  git add $pc | Out-Null
  Info "Wrote .pre-commit-config.yaml"
}

# build baseline (UTF-8 no BOM)
$excludeFiles = '(?i)^(logs/|out/|\.venv/|\.git/)|\.log$'
$excludeLines = '(?i)pragma:\s*allowlist\s*secret'
$json = & detect-secrets scan --all-files --exclude-files $excludeFiles --exclude-lines $excludeLines
if ([string]::IsNullOrWhiteSpace($json)) { throw "detect-secrets produced no output" }
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Resolve-Path ".secrets.baseline"), $json, $enc)
git add .secrets.baseline | Out-Null
Ok "Baseline created/updated"

# run only detect-secrets hook first (it may tweak line numbers)
pre-commit install --hook-type pre-commit --hook-type pre-push --overwrite | Out-Null
try {
  pre-commit run detect-secrets --all-files | Out-Null
} catch {
  Warn "detect-secrets hook updated baseline; re-staging"
}
git add .secrets.baseline | Out-Null

# commit if needed
$pending = git diff --cached --name-only
if ($pending) {
  git commit -S -m "chore(security): add/refresh .secrets.baseline" | Out-Null
  try { git push | Out-Null } catch { git push -u origin (git branch --show-current) | Out-Null }
  Ok "Committed & pushed baseline"
} else {
  Info "No baseline changes to commit"
}
