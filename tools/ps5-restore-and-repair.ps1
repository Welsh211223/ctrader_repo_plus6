# tools/ps5-restore-and-repair.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $resolved = $null
  try { $resolved = (Resolve-Path $Path -ErrorAction Stop).Path } catch { }
  if (-not $resolved) {
    $dir = Split-Path $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $resolved = $Path
  }
  [IO.File]::WriteAllText($resolved, $Content, $enc)
}

function Save-IfMissing { param([string]$Path,[string]$Content) if (-not (Test-Path $Path)) { Write-Utf8NoBom -Path $Path -Content $Content } }

function Run {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

$RepoRoot = (Get-Location).Path
$VenvPy   = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# --- 1) Restore core configs ---------------------------------------------------
if (-not (Test-Path ".gitignore")) { New-Item -ItemType File -Path ".gitignore" | Out-Null }
$gi = Get-Content .gitignore -Raw
$adds = @()
if ($gi -notmatch '(?m)^\s*\.env\s*$')            { $adds += "`n# local secrets`n.env" }
if ($gi -notmatch '(?m)^\s*!\.env\.example\s*$')   { $adds += "`n# allow documented example`n!.env.example" }
if ($gi -notmatch '(?m)^\s*\.venv/?\s*$')          { $adds += "`n.venv" }
if ($gi -notmatch '(?m)^\s*__pycache__/?\s*$')     { $adds += "`n__pycache__/" }
if ($gi -notmatch '(?m)^\s*\.pytest_cache/?\s*$')  { $adds += "`n.pytest_cache/" }
if ($gi -notmatch '(?m)^\s*dist/?\s*$')            { $adds += "`ndist/" }
if ($gi -notmatch '(?m)^\s*build/?\s*$')           { $adds += "`nbuild/" }
if ($adds.Count) { Add-Content .gitignore ($adds -join "") }

$pyproject = @'
[tool.black]
line-length = 88
target-version = ["py311","py312","py313"]

[tool.isort]
profile = "black"
line_length = 88
'@
Save-IfMissing "pyproject.toml" $pyproject

$envExample = @'
# --- CoinSpot ---
COINSPOT_API_KEY=YOUR_KEY_HERE
COINSPOT_API_SECRET=YOUR_SECRET_HERE
COINSPOT_LIVE_DANGEROUS=false  # change to true only when ready to send live orders

# --- Optional notifications ---
DISCORD_WEBHOOK=
'@
Save-IfMissing ".env.example" $envExample

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
Save-IfMissing ".pre-commit-config.yaml" $pre

# --- 2) Restore helper scripts -------------------------------------------------
if (-not (Test-Path "tools")) { New-Item -ItemType Directory -Force -Path "tools" | Out-Null }

$precommitGreen = @'
param([int]$MaxPasses = 5)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
for ($i=1; $i -le $MaxPasses; $i++) {
  pre-commit run -a
  if ($LASTEXITCODE -eq 0) { Write-Host "✅ Hooks green on pass #$i"; exit 0 }
  git add -A
  if ($i -eq $MaxPasses) { Write-Warning "Hooks still not green after $i passes."; exit 1 }
}
'@
Save-IfMissing "tools\precommit-green.ps1" $precommitGreen

$fixDetect = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U detect-secrets | Out-Null
$scan = & $py -m detect_secrets scan --all-files --exclude-files '^\.secrets\.baseline$'
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText(".secrets.baseline", ($scan -join "`n"), $enc)
Write-Host "✅ .secrets.baseline regenerated."
'@
Save-IfMissing "tools\fix-detect-secrets.ps1" $fixDetect

$lintAll = @'
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U black isort flake8 | Out-Null
& $py -m black --check .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $py -m isort --check-only .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $py -m flake8
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "✅ Lints clean."
'@
Save-IfMissing "tools\lint-all.ps1" $lintAll

$runTests = @'
param([switch]$Coverage)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U pytest | Out-Null
if ($Coverage) { & $py -m pip install -U pytest-cov | Out-Null }
if ($Coverage) { & $py -m pytest --maxfail=1 -q --cov=src --cov-report term-missing }
else { & $py -m pytest -q }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
'@
Save-IfMissing "tools\run-tests.ps1" $runTests

# --- 3) Ensure live_guard module exists ---------------------------------------
$guardPath = "src\ctrader\utils\live_guard.py"
$guard = @'
from __future__ import annotations
import os, time
from pathlib import Path

_TRUTHY = {"1", "true", "yes", "on"}

def _is_truthy(v: str | None) -> bool:
    return (v or "").strip().lower() in _TRUTHY

def assert_live_ok(now: float | None = None) -> None:
    """Block accidental live trading unless explicitly confirmed."""
    if not _is_truthy(os.getenv("COINSPOT_LIVE_DANGEROUS", "false")):
        return
    if _is_truthy(os.getenv("CONFIRM_LIVE")):
        return
    tok = Path(".allow_live")
    t = time.time() if now is None else now
    if tok.exists():
        try:
            if t - tok.stat().st_mtime <= 3600:
                return
        except OSError:
            pass
    raise RuntimeError(
        "Refusing LIVE orders: COINSPOT_LIVE_DANGEROUS=true without explicit confirmation. "
        "Set CONFIRM_LIVE=1 or create an empty .allow_live (valid 1 hour)."
    )
'@
Write-Utf8NoBom -Path $guardPath -Content $guard

# --- 4) Aggressive but safe Python repair of coinspot_execution.py ------------
$execPath = "src\ctrader\execution\coinspot_execution.py"
if (-not (Test-Path $execPath)) { throw "Missing $execPath" }

$pyRepair = @'
import ast, sys, io, re

FN = r"src\ctrader\execution\coinspot_execution.py"

def read():
    with io.open(FN, "r", encoding="utf-8") as f:
        return f.read().replace("\r\n", "\n")

def write(s):
    with io.open(FN, "w", encoding="utf-8", newline="") as f:
        f.write(s)

def parse_ok(s):
    try:
        ast.parse(s)
        return True, None
    except (IndentationError, SyntaxError) as e:
        return False, e

def context(s, ln, radius=8):
    lines = s.split("\n")
    if not ln: ln = 1
    ln = max(1, min(len(lines), ln))
    i0, i1 = max(1, ln - radius), min(len(lines), ln + radius)
    out = []
    for i in range(i0, i1 + 1):
        mark = ">>" if i == ln else "  "
        out.append(f"{mark} {i:4d}: {lines[i-1]}")
    return "\n".join(out)

src = read()
# Normalize tabs to spaces
src = src.replace("\t", "    ")

# Pass 1-10: if IndentationError, reduce indent on the error line stepwise
for _ in range(10):
    ok, err = parse_ok(src)
    if ok:
        break
    if isinstance(err, IndentationError) and getattr(err, "lineno", None):
        ln = err.lineno
        lines = src.split("\n")
        if 1 <= ln <= len(lines):
            line = lines[ln-1]
            stripped = line.lstrip()
            if stripped:
                indent = len(line) - len(stripped)
                new_indent = max(0, indent - (indent % 4 or 4))
                lines[ln-1] = (" " * new_indent) + stripped
                src = "\n".join(lines)
                continue
    break

ok, err = parse_ok(src)
if not ok:
    print("STILL_BROKEN", type(err).__name__, getattr(err, "lineno", None))
    print(context(src, getattr(err, "lineno", 1)))
    sys.exit(2)

# Ensure import exists once after import block
imp = "from ctrader.utils.live_guard import assert_live_ok\n"
if imp not in src:
    parts = src.splitlines(True)
    i = 0
    while i < len(parts) and (parts[i].startswith("#!") or parts[i].lower().startswith("# -*- coding")):
        i += 1
    while i < len(parts) and (parts[i].startswith("import ") or parts[i].startswith("from ")):
        i += 1
    parts.insert(i, imp)
    src = "".join(parts)

tree = ast.parse(src)
target = None
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == "place_plan_coinspot":
        target = n
        break

if target is not None:
    insert_after = target.lineno
    if target.body and isinstance(target.body[0], ast.Expr) and isinstance(getattr(target.body[0],"value",None), ast.Constant) and isinstance(target.body[0].value.value, str):
        insert_after = getattr(target.body[0], "end_lineno", target.body[0].lineno)

    indent_cols = 4
    for n in target.body:
        if not (isinstance(n, ast.Expr) and isinstance(getattr(n,"value",None), ast.Constant) and isinstance(n.value.value, str)):
            indent_cols = getattr(n, "col_offset", 4)
            break
    indent = " " * max(indent_cols, 4)

    lines = src.splitlines(True)
    # Avoid duplicate insertion
    body_text = "".join(lines[target.lineno-1 : (target.body[-1].end_lineno if target.body else target.lineno)])
    if "assert_live_ok()" not in body_text:
        guard_block = f"{indent}# Safety: block accidental live trades\n{indent}assert_live_ok()\n"
        lines.insert(insert_after, guard_block)
        src = "".join(lines)

ok, err = parse_ok(src)
if not ok:
    print("STILL_BROKEN_AFTER", type(err).__name__, getattr(err, "lineno", None))
    print(context(src, getattr(err, "lineno", 1)))
    sys.exit(3)

write(src)
print("OK")
'@

# Write & run the Python fixer
$tmpPy = Join-Path $env:TEMP "ps5_coinspot_repair.py"
Write-Utf8NoBom -Path $tmpPy -Content $pyRepair
try {
  Run $VenvPy @($tmpPy)
} catch {
  Write-Warning $_.Exception.Message
  Write-Host "`nIf it shows STILL_BROKEN with a context snippet, copy/paste that here." -ForegroundColor Yellow
  throw
}

# --- 5) Format, Lint, Commit, and run hooks -----------------------------------
Run $VenvPy @('-m','pip','install','-U','black','isort','flake8') | Out-Null
Run $VenvPy @('-m','black','--','src')
Run $VenvPy @('-m','isort','--','src')
Run $VenvPy @('-m','flake8','src')

git add $execPath $guardPath 2>$null | Out-Null
if (git diff --staged --name-only) {
  Run 'git' @('commit','-m','fix: PS5-safe toolbox restore + coinspot repair + guard injection')
}

# Hooks (optional)
if (Get-Command pre-commit -ErrorAction SilentlyContinue) {
  & pre-commit clean | Out-Null
  & pre-commit run -a
}

Write-Host "`n✅ PS5 restore + coinspot repair complete." -ForegroundColor Green
