# tools/auto-repair-coinspot.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Cmd {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

# Resolve Python
$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# Targets
$ExecPath  = "src\ctrader\execution\coinspot_execution.py"
$GuardPath = "src\ctrader\utils\live_guard.py"
if (-not (Test-Path $ExecPath)) { throw "Missing $ExecPath" }
if (-not (Test-Path (Split-Path $GuardPath))) { New-Item -ItemType Directory -Force -Path (Split-Path $GuardPath) | Out-Null }

# 0) Guard module (UTF-8 no BOM)
$guard = @'
"""
Runtime guard for live trading.

Behavior:
- If COINSPOT_LIVE_DANGEROUS is false/empty: no-op.
- If COINSPOT_LIVE_DANGEROUS is true: require either
  * CONFIRM_LIVE in {1, true, yes, on} OR
  * presence of a .allow_live file (valid for 1 hour).
"""
from __future__ import annotations

import os
import time
from pathlib import Path

_TRUTHY = {"1", "true", "yes", "on"}


def _is_truthy(val: str | None) -> bool:
    if val is None:
        return False
    return val.strip().lower() in _TRUTHY


def assert_live_ok(now: float | None = None) -> None:
    """Raise RuntimeError if live trading is enabled without explicit confirmation."""
    live = _is_truthy(os.getenv("COINSPOT_LIVE_DANGEROUS", "false"))
    if not live:
        return
    if _is_truthy(os.getenv("CONFIRM_LIVE")):
        return

    token = Path(".allow_live")
    _now = time.time() if now is None else now
    if token.exists():
        try:
            age = _now - token.stat().st_mtime
            if age <= 3600:  # valid 1 hour
                return
        except OSError:
            pass

    raise RuntimeError(
        "Refusing to place LIVE orders: COINSPOT_LIVE_DANGEROUS=true but no explicit confirmation provided. "
        "Do ONE of:\n"
        "  - Set CONFIRM_LIVE=1 for this run, or\n"
        "  - Create an empty file named .allow_live (valid for 1 hour).\n"
        "This safeguard prevents accidental live trades."
    )
'@
[IO.File]::WriteAllText((Resolve-Path $GuardPath), $guard, (New-Object System.Text.UTF8Encoding($false)))

# 1) AST-based repair & injection (writes back only if valid)
$py = @'
import ast, re, sys

FN = r"src\ctrader\execution\coinspot_execution.py"

def read(fn):
    with open(fn, "r", encoding="utf-8") as f:
        return f.read()

def write(fn, s):
    with open(fn, "w", encoding="utf-8", newline="") as f:
        f.write(s)

def try_parse(s):
    try:
        ast.parse(s)
        return True, None
    except (IndentationError, SyntaxError) as e:
        return False, e

src = read(FN).replace("\r\n", "\n")

# Try to auto-fix unexpected top-level indentation up to 6 passes
for _ in range(6):
    ok, err = try_parse(src)
    if ok:
        break
    if isinstance(err, IndentationError) and getattr(err, "lineno", None):
        lines = src.split("\n")
        i = err.lineno - 1
        if 0 <= i < len(lines):
            lines[i] = lines[i].lstrip()
            src = "\n".join(lines)
            continue
    break

# Ensure import exactly once (after import block if present)
import_line = "from ctrader.utils.live_guard import assert_live_ok\n"
if import_line not in src:
    lines = src.splitlines(True)
    i = 0
    while i < len(lines) and (lines[i].startswith("#!") or lines[i].lower().startswith("# -*- coding")):
        i += 1
    while i < len(lines) and (lines[i].startswith("import ") or lines[i].startswith("from ")):
        i += 1
    lines.insert(i, import_line)
    src = "".join(lines)

ok, err = try_parse(src)
if not ok:
    print("STILL_BROKEN", type(err).__name__, getattr(err, "lineno", None))
    sys.exit(2)

# Inject guard at top of place_plan_coinspot (works nested or top-level)
tree = ast.parse(src)
func = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "place_plan_coinspot":
        func = node
        break

if func is not None:
    # Compute insertion point (after docstring if present)
    insert_after = func.lineno
    if func.body:
        first = func.body[0]
        if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) and isinstance(first.value.value, str):
            insert_after = getattr(first, "end_lineno", first.lineno)

    # Choose indent using first non-docstring stmt
    indent_cols = 4
    for n in func.body:
        if not (isinstance(n, ast.Expr) and isinstance(getattr(n,"value",None), ast.Constant) and isinstance(n.value.value, str)):
            indent_cols = getattr(n, "col_offset", 4)
            break
    indent = " " * max(indent_cols, 4)

    lines = src.splitlines(True)
    start = func.lineno - 1
    end = (func.body[-1].end_lineno if func.body else func.lineno)

    # Remove any previously injected guard near start
    block = "".join(lines[start:end])
    block = re.sub(r"^\s*#\s*Safety:.*\r?\n\s*assert_live_ok\(\)\r?$", "", block, count=1, flags=re.M)
    lines[start:end] = [block]

    # Only insert if not already present
    joined = "".join(lines)
    body_text = joined.splitlines(True)[func.lineno-1 : end]
    if "assert_live_ok()" not in "".join(body_text):
        guard_block = f"{indent}# Safety: block accidental live trades\n{indent}assert_live_ok()\n"
        # insert_after is 1-indexed; list is 0-indexed
        lines.insert(insert_after, guard_block)
    src = "".join(lines)

ok, err = try_parse(src)
if not ok:
    print("STILL_BROKEN_AFTER", type(err).__name__, getattr(err, "lineno", None))
    sys.exit(3)

write(FN, src)
print("OK")
'@

$pyFile = Join-Path $env:TEMP "auto_fix_coinspot.py"
[IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding($false)))

# Run the fixer (NOTE: pass args correctly with -Args)
Invoke-Cmd -Exe $VenvPy -Args @($pyFile)

# 2) Format & lint
Invoke-Cmd -Exe $VenvPy -Args @('-m','black','--','src')
Invoke-Cmd -Exe $VenvPy -Args @('-m','isort','--','src')
Invoke-Cmd -Exe $VenvPy -Args @('-m','flake8','src')

# 3) Commit + hooks
git add $ExecPath $GuardPath 2>$null | Out-Null
if (git diff --staged --name-only) {
  Invoke-Cmd -Exe 'git' -Args @('commit','-m','fix(safety): auto-repair indentation and inject live guard (AST)')
}

Invoke-Cmd -Exe 'pre-commit' -Args @('clean')
& pre-commit run -a
if ($LASTEXITCODE -ne 0) {
  git add -A | Out-Null
  Invoke-Cmd -Exe 'pre-commit' -Args @('run','-a')
}

Write-Host "`n✅ Repaired, formatted, and hooks run." -ForegroundColor Green
