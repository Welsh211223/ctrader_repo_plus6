# tools/prep-precommit.ps1
# Usage (from repo root):  powershell -ExecutionPolicy Bypass -File .\tools\prep-precommit.ps1
# Optional:                powershell -ExecutionPolicy Bypass -File .\tools\prep-precommit.ps1 -NoCommit

param(
  [switch]$NoCommit
)

$ErrorActionPreference = "Stop"

# --- Repo root ---
$gitRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $gitRoot) { $gitRoot = (Resolve-Path .).Path }
Set-Location $gitRoot
Write-Host "Repo root: $gitRoot"

# --- Ensure tools (best-effort; safe if already installed) ---
$venvPip = ".\.venv\Scripts\pip.exe"
if (Test-Path $venvPip) {
  & $venvPip install -q pre-commit detect-secrets black ruff isort | Out-Null
}

# --- Create detect-secrets baseline (Windows-safe, no BOM) ---
Remove-Item .secrets.baseline -ErrorAction SilentlyContinue
cmd /c "detect-secrets scan --all-files > .secrets.baseline"

if (-not (Test-Path .secrets.baseline)) {
  throw "detect-secrets baseline was not created."
}
$first = (Get-Content .secrets.baseline -TotalCount 1).Trim()
if ($first -ne "{") {
  throw "Baseline doesn't look like JSON. First line: '$first'"
}
$absBaseline = ((Resolve-Path .secrets.baseline).Path) -replace '\\','/'
Write-Host "Baseline: $absBaseline"

# --- Backup current YAML (if any) ---
if (Test-Path .pre-commit-config.yaml) {
  Copy-Item .pre-commit-config.yaml .pre-commit-config.yaml.bak -Force
  Write-Host "Backed up .pre-commit-config.yaml -> .pre-commit-config.yaml.bak"
}

# --- Write a clean pre-commit config (Windows-friendly absolute baseline) ---
$yaml = @"
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-yaml
      - id: mixed-line-ending
      - id: detect-private-key

  - repo: https://github.com/psf/black
    rev: 24.8.0
    hooks:
      - id: black

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.5
    hooks:
      - id: ruff
        args: ["--fix"]
      - id: ruff-format

  - repo: https://github.com/PyCQA/isort
    rev: 5.13.2
    hooks:
      - id: isort

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args:
          - --baseline
          - $absBaseline
        pass_filenames: false
"@
$yaml | Out-File .pre-commit-config.yaml -Encoding utf8
Write-Host "Wrote .pre-commit-config.yaml"

# --- Run hooks ---
pre-commit clean
Write-Host "`n--- Running detect-secrets only (debug) ---"
pre-commit run detect-secrets --all-files -v

Write-Host "`n--- Running full pre-commit ---"
pre-commit run --all-files

# --- Commit & push (unless -NoCommit) ---
if (-not $NoCommit) {
  git add .pre-commit-config.yaml .secrets.baseline
  try {
    git commit -m "qa: pre-commit config + detect-secrets baseline" | Out-Null
  } catch {
    Write-Host "Nothing to commit (maybe already clean)."
  }
  git push
}

Write-Host "`nAll set ✅"
