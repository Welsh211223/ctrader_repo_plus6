# tools/restore-toolbox.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $full = Resolve-Path $Path -ErrorAction SilentlyContinue
  if (-not $full) { $dir = Split-Path $Path; if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
  [IO.File]::WriteAllText((Resolve-Path $Path -ErrorAction SilentlyContinue) ?? $Path, $Content, $enc)
}

function Save-IfMissing {
  param([string]$Path,[string]$Content)
  if (-not (Test-Path $Path)) { Write-Utf8NoBom -Path $Path -Content $Content }
}

$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# --- root configs ------------------------------------------------------
# .gitignore (ensure .env ignored and .env.example allowed)
if (-not (Test-Path ".gitignore")) { New-Item -ItemType File -Path ".gitignore" | Out-Null }
$gi = Get-Content .gitignore -Raw
if ($gi -notmatch '(?m)^\s*\.env\s*$')          { Add-Content .gitignore "`n# local secrets`n.env" }
if ($gi -notmatch '(?m)^\s*!\.env\.example\s*$') { Add-Content .gitignore "`n# allow documented example`n!.env.example" }

# pyproject.toml (black/isort)
$pyproject = @'
[tool.black]
line-length = 88
target-version = ["py311","py312","py313"]

[tool.isort]
profile = "black"
line_length = 88
'@
Save-IfMissing "pyproject.toml" $pyproject

# .env.example
$envExample = @'
# --- CoinSpot ---
COINSPOT_API_KEY=YOUR_KEY_HERE
COINSPOT_API_SECRET=YOUR_SECRET_HERE
COINSPOT_LIVE_DANGEROUS=false  # change to true only when ready to send live orders

# --- Optional notifications ---
DISCORD_WEBHOOK=
'@
Save-IfMissing ".env.example" $envExample

# .pre-commit-config.yaml
$pre = @'
repos:
  - repo: https://github.com/psf/black
    rev: 24.8.0
    hooks:
      - id: black

  - repo: https://github.com/PyCQA/isort
    rev: 5.13.2
    hooks:
      - id: isort

  - repo: https://github.com/PyCQA/flake8
    rev: 7.1.1
    hooks:
      - id: flake8

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ["--baseline", ".secrets.baseline"]
        exclude: "^\\.secrets\\.baseline$"
'@
if (-not (Test-Path ".pre-commit-config.yaml")) {
  Write-Utf8NoBom -Path ".pre-commit-config.yaml" -Content $pre
}

# --- tools/ scripts ----------------------------------------------------
New-Item -ItemType Directory -Force -Path "tools" | Out-Null

# precommit-green.ps1
$precommitGreen = @'
param([int]$MaxPasses = 5)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
function Run($exe, $args=@()) { & $exe @args; if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE)" } }
for ($i=1; $i -le $MaxPasses; $i++) {
  pre-commit run -a
  if ($LASTEXITCODE -eq 0) { Write-Host "✅ Hooks green on pass #$i"; exit 0 }
  git add -A
  if ($i -eq $MaxPasses) { Write-Warning "Hooks still not green after $i passes."; exit 1 }
}
'@
Save-IfMissing "tools\precommit-green.ps1" $precommitGreen

# fix-detect-secrets.ps1
$fixDetect = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }
& $VenvPy -m pip install -U detect-secrets | Out-Null
# Rescan everything but the baseline itself; write UTF-8 no BOM
$scan = & $VenvPy -m detect_secrets scan --all-files --exclude-files '^\.secrets\.baseline$'
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText(".secrets.baseline", ($scan -join "`n"), $enc)
Write-Host "✅ .secrets.baseline regenerated (baseline excluded from scanning)."
'@
Save-IfMissing "tools\fix-detect-secrets.ps1" $fixDetect

# repair-coinspot.ps1 (AST-based)
$repairCoinspot = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
function Run { param([string]$Exe,[string[]]$Args=@()); Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan; & $Exe @Args; if ($LASTEXITCODE -ne 0){ throw "Failed: $Exe ($LASTEXITCODE)"} }
$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# Ensure guard module
$guardPath = "src\ctrader\utils\live_guard.py"
$guard = @"
from __future__ import annotations
import os, time
from pathlib import Path
_TRUTHY = {"1","true","yes","on"}
def _is_truthy(v: str|None) -> bool: return (v or "").strip().lower() in _TRUTHY
def assert_live_ok(now: float|None=None) -> None:
    if not _is_truthy(os.getenv("COINSPOT_LIVE_DANGEROUS","false")): return
    if _is_truthy(os.getenv("CONFIRM_LIVE")): return
    tok = Path(".allow_live"); t = time.time() if now is None else now
    if tok.exists():
        try:
            if t - tok.stat().st_mtime <= 3600: return
        except OSError: pass
    raise RuntimeError("Refusing LIVE orders without explicit confirmation (CONFIRM_LIVE=1 or .allow_live).")
"@
$enc = New-Object System.Text.UTF8Encoding($false)
$dir = Split-Path $guardPath; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($guardPath, $guard, $enc)

# Python AST fixer
$py = @"
import ast, re, sys
fn = r'src\ctrader\execution\coinspot_execution.py'
src = open(fn, 'r', encoding='utf-8').read().replace('\r\n','\n')

def try_parse(s):
    try: ast.parse(s); return True, None
    except (IndentationError,SyntaxError) as e: return False, e

# Heuristic: dedent accidental top-level leading spaces
for _ in range(6):
    ok, err = try_parse(src)
    if ok: break
    if isinstance(err, IndentationError) and getattr(err,'lineno',None):
        lines = src.split('\n'); i = err.lineno-1
        if 0 <= i < len(lines): lines[i] = lines[i].lstrip(); src = '\n'.join(lines); continue
    break

ok, err = try_parse(src)
if not ok:
    print('STILL_BROKEN', type(err).__name__, getattr(err,'lineno',None)); sys.exit(2)

imp = 'from ctrader.utils.live_guard import assert_live_ok\n'
if imp not in src:
    lines = src.splitlines(True); i = 0
    while i < len(lines) and (lines[i].startswith('#!') or lines[i].lower().startswith('# -*- coding')): i += 1
    while i < len(lines) and (lines[i].startswith('import ') or lines[i].startswith('from ')): i += 1
    lines.insert(i, imp); src = ''.join(lines)

tree = ast.parse(src)
target = None
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == 'place_plan_coinspot':
        target = n; break

if target is not None:
    insert_after = target.lineno
    if target.body and isinstance(target.body[0], ast.Expr) and isinstance(getattr(target.body[0],'value',None), ast.Constant) and isinstance(target.body[0].value.value, str):
        insert_after = getattr(target.body[0],'end_lineno', target.body[0].lineno)
    indent_cols = 4
    for n in target.body:
        if not (isinstance(n, ast.Expr) and isinstance(getattr(n,'value',None), ast.Constant) and isinstance(n.value.value, str)):
            indent_cols = getattr(n,'col_offset',4); break
    indent = ' ' * max(indent_cols, 4)
    lines = src.splitlines(True)
    start = target.lineno - 1
    end   = (target.body[-1].end_lineno if target.body else target.lineno)
    block = ''.join(lines[start:end])
    block = re.sub(r'^\s*#\s*Safety:.*\r?\n\s*assert_live_ok\(\)\r?$', '', block, count=1, flags=re.M)
    lines[start:end] = [block]
    body_text = ''.join(lines)[target.lineno-1 : end]
    if 'assert_live_ok()' not in body_text:
        guard_block = f"{indent}# Safety: block accidental live trades\n{indent}assert_live_ok()\n"
        lines.insert(insert_after, guard_block)
    src = ''.join(lines)

ok, err = try_parse(src)
if not ok:
    print('STILL_BROKEN_AFTER', type(err).__name__, getattr(err,'lineno',None)); sys.exit(3)

open(fn, 'w', encoding='utf-8', newline='').write(src)
print('OK')
"@

$tmp = Join-Path $env:TEMP "repair_coinspot_ast.py"
[IO.File]::WriteAllText($tmp, $py, (New-Object System.Text.UTF8Encoding($false)))
Run $VenvPy @($tmp)

Run $VenvPy @('-m','black','--','src')
Run $VenvPy @('-m','isort','--','src')
Run $VenvPy @('-m','flake8','src')
Write-Host "✅ coinspot repaired & formatted."
'@
Save-IfMissing "tools\repair-coinspot.ps1" $repairCoinspot

Write-Host "`n✅ Toolbox restored (configs + helper scripts). Next steps:" -ForegroundColor Green
Write-Host "  1) python -m pip install -U pre-commit detect-secrets black isort flake8"
Write-Host "  2) .\tools\fix-detect-secrets.ps1"
Write-Host "  3) pre-commit install"
Write-Host "  4) .\tools\precommit-green.ps1"
Write-Host "  5) If coinspot still fails: .\tools\repair-coinspot.ps1"
