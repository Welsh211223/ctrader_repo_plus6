<#  tools/ops-hardening.ps1
    Repo hardening for Windows/PowerShell 5:
      - .gitignore noise rules + untrack junk safely
      - .gitattributes + .editorconfig (line endings)
      - Pre-commit config (Black, Ruff, isort, detect-secrets)
      - Fix src/ctrader/cli/schedule.py header ordering
      - Create detect-secrets baseline (Windows-safe)
      - Pre-commit install / run
      - Optional: README and docs/ORGANIZER.md updates
      - Optional: SSH commit signing (local)
#>

[CmdletBinding()]
param(
  [switch]$All,

  # file/content writers
  [switch]$WriteGitattributes,
  [switch]$WriteEditorconfig,
  [switch]$WritePrecommitYaml,

  # code/content touch-ups
  [switch]$FixScheduleHeader,
  [switch]$UpdateReadme,
  [switch]$UpdateOrganizer,

  # secrets / hooks
  [switch]$RecreateBaseline,
  [switch]$InstallPrecommitDeps,
  [switch]$RunPrecommit,
  [switch]$CleanPrecommitCache,

  # git housekeeping
  [switch]$UntrackNoise,
  [switch]$EnsureGitSigning,
  [switch]$Commit,
  [switch]$Push,
  [string]$CommitMessage = "chore/ops: repo hardening (pre-commit, secrets baseline, formatting)"
)

# ----- sensible defaults when -All is used -----
if ($All) {
  $WriteGitattributes   = $true
  $WriteEditorconfig    = $true
  $WritePrecommitYaml   = $true
  $FixScheduleHeader    = $true
  $UpdateReadme         = $true
  $UpdateOrganizer      = $true
  $RecreateBaseline     = $true
  $InstallPrecommitDeps = $true
  $RunPrecommit         = $true
  $CleanPrecommitCache  = $true
  $UntrackNoise         = $true
  $EnsureGitSigning     = $true
}

$ErrorActionPreference = "Stop"

function Fail($msg){ Write-Host $msg -ForegroundColor Red; throw $msg }

function Assert-RepoRoot {
  if (-not (Test-Path ".git")) { Fail "Run this from the repository root ('.git' not found)." }
  $root = (Resolve-Path ".").Path
  Write-Host "Repo root: $root" -ForegroundColor Cyan
}

function Resolve-Tool {
  param([string]$Name)
  # Prefer venv\Scripts\Name.exe, fallback to PATH
  $cand = ".\.venv\Scripts\$Name.exe"
  if (Test-Path $cand) { return (Resolve-Path $cand).Path }
  $tool = (Get-Command $Name -ErrorAction SilentlyContinue)
  if ($tool) { return $tool.Source }
  return $null
}

function Ensure-LinesInFile {
  param([string]$Path,[string[]]$Lines)
  if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
  $existing = Get-Content -Raw $Path
  $added = 0
  foreach ($ln in $Lines) {
    if ($existing -notmatch [regex]::Escape($ln)) {
      Add-Content -Path $Path -Value $ln -Encoding utf8
      $added++
    }
  }
  if ($added -gt 0) { Write-Host "Updated $Path ($added line(s) added)." -ForegroundColor Green }
  else { Write-Host "$Path already contains required lines." -ForegroundColor Yellow }
}

function Untrack-Noise {
  # stop tracking noisy stuff if it slipped into git history
  & git rm -r --cached --ignore-unmatch .archive 2>$null
  & git rm --cached --ignore-unmatch .env 2>$null
  & git rm --cached --ignore-unmatch ".env.*" 2>$null
  # keep .env.example
  git restore --staged .env.example 2>$null
  # also catch nested ".archive" dirs just in case
  $archives = Get-ChildItem -Recurse -Directory -Filter ".archive" -ErrorAction SilentlyContinue
  foreach ($d in $archives) {
    $rel = (Resolve-Path -Relative $d.FullName)
    & git rm -r --cached --ignore-unmatch $rel 2>$null
  }
}

function Write-GitAttributes {
$txt = @'
* text=auto eol=lf

# windows scripts should stay CRLF
*.ps1 text eol=crlf
*.bat text eol=crlf
*.cmd text eol=crlf

# images/binaries
*.png binary
*.jpg binary
*.jpeg binary
*.gif binary
*.ico binary
*.pdf binary

# keep secrets baseline as text (LF)
.secrets.baseline text eol=lf
'@
  Set-Content -Path ".gitattributes" -Value $txt -Encoding utf8
  Write-Host "Wrote .gitattributes" -ForegroundColor Green
}

function Write-EditorConfig {
$txt = @'
root = true

[*]
end_of_line = lf
charset = utf-8
insert_final_newline = true
trim_trailing_whitespace = true

[*.ps1]
end_of_line = crlf

[*.yml]
indent_style = space
indent_size = 2
'@
  Set-Content -Path ".editorconfig" -Value $txt -Encoding utf8
  Write-Host "Wrote .editorconfig" -ForegroundColor Green
}

function Write-PrecommitYaml {
$yaml = @'
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
      - id: ruff-format

  - repo: https://github.com/PyCQA/isort
    rev: 5.13.2
    hooks:
      - id: isort

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ["--baseline", ".secrets.baseline"]
        pass_filenames: false
'@
  Set-Content -Path ".pre-commit-config.yaml" -Value $yaml -Encoding utf8
  Write-Host "Wrote .pre-commit-config.yaml" -ForegroundColor Green
}

function Fix-ScheduleHeader {
  $path = "src\ctrader\cli\schedule.py"
  if (-not (Test-Path $path)) { Write-Host "Skip: $path not found." -ForegroundColor Yellow; return }

  $code = Get-Content -Raw $path

  # capture top-level docstring if present
  $docMatch = [regex]::Match($code, '^\s*(?s)(?:(?:"""[\s\S]*?"""|''''[\s\S]*?''''))')
  $doc  = ""
  $rest = $code
  if ($docMatch.Success) {
    $doc  = $docMatch.Value.TrimEnd()
    $rest = $code.Substring($docMatch.Length)
  }

  # strip any existing future/import/path lines to avoid duplicates
  $patterns = @(
    '(?m)^\s*from\s+__future__\s+import\s+annotations\s*\r?\n',
    '(?m)^\s*import\s+argparse\s*\r?\n',
    '(?m)^\s*import\s+shlex\s*\r?\n',
    '(?m)^\s*import\s+subprocess\s*\r?\n',
    '(?m)^\s*import\s+time\s*\r?\n',
    '(?m)^\s*import\s+sys\s*\r?\n',
    '(?m)^\s*from\s+pathlib\s+import\s+Path\s*\r?\n',
    '(?m)^\s*SRC_DIR\s*=.*\r?\n',
    '(?m)^\s*if\s+str\(SRC_DIR\)\s+not\s+in\s+sys\.path:\s*\r?\n',
    '(?m)^\s*sys\.path\.insert\(.*\)\s*\r?\n'
  )
  foreach ($pat in $patterns) { $rest = [regex]::Replace($rest, $pat, '') }

  $header = @"
from __future__ import annotations

import argparse
import shlex
import subprocess
import time
import sys
from pathlib import Path

# Point to the /src directory: .../src/ctrader/cli/schedule.py -> parents[2] is /src
SRC_DIR = Path(__file__).resolve().parents[2]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

"@

  $prefix = ""
  if ($doc -ne "") { $prefix = $doc + "`r`n`r`n" }
  $new = $prefix + $header + $rest.TrimStart()
  Set-Content -Path $path -Value $new -Encoding utf8

  Write-Host "Fixed header in $path" -ForegroundColor Green
}

function Make-Organizer {
  New-Item -ItemType Directory -Force .\docs | Out-Null
$txt = @'
# ctrader — Operator's Organizer

## Daily Ops Checklist
- [ ] `git pull` from `main`
- [ ] Update prices (CoinSpot/Coingecko fetch)
- [ ] Generate rebalance plan (paper)
- [ ] Review risk caps & trend filters
- [ ] Execute (paper or live), then log outcomes
- [ ] Discord notification sent and verified

## Release Flow
1. Branch: `chore/ops-hardening` or `feat/<name>`
2. Run `pre-commit run --all-files`
3. Update `CHANGELOG.md` as needed
4. Commit (signed), push, open PR → squash & merge
5. Tag release: `git tag vX.Y.Z && git push --tags`

## Branching
- `main`: stable
- `chore/*`: maintenance, quality, infra
- `feat/*`: new features
- `fix/*`: bugfixes

## Secrets Handling
- Never commit keys. `detect-secrets` enforces this.
- Keep `.env` only locally. Use `.env.example` as template.

## Rollback
- `git revert <SHA>`
- If a deploy breaks, roll back to last tag `git checkout vX.Y.Z`
'@
  Set-Content -Path ".\docs\ORGANIZER.md" -Value $txt -Encoding utf8
  Write-Host "Wrote docs/ORGANIZER.md" -ForegroundColor Green
}

function Touch-Readme {
  $path = "README.md"
  if (-not (Test-Path $path)) { return }
  $raw = Get-Content -Raw $path
  if ($raw -notmatch "## Pre-commit") {
$add = @"
## Pre-commit

Install once (inside your venv):

```powershell
pip install pre-commit black ruff isort detect-secrets
pre-commit install
pre-commit run --all-files
