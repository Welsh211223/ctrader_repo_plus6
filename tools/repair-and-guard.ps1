# tools/repair-and-guard.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Cmd {
  param([string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

# Resolve Python
$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }

# Paths
$ExecPath  = "src\ctrader\execution\coinspot_execution.py"
$GuardPath = "src\ctrader\utils\live_guard.py"

if (-not (Test-Path $ExecPath)) { throw "Missing $ExecPath" }
if (-not (Test-Path (Split-Path $GuardPath))) { New-Item -ItemType Directory -Force -Path (Split-Path $GuardPath) | Out-Null }

# 0) Ensure guard module exists and is well-formatted
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

# 1) Backup current file and try to restore a clean base from HEAD
$Backup = "$ExecPath.bak"
Copy-Item -Force $ExecPath $Backup

$headContent = ""
try {
  $headContent = (& git show "HEAD:$ExecPath" 2>$null) -join "`n"
} catch {}
if ($LASTEXITCODE -eq 0 -and $headContent) {
  # Overwrite with HEAD (guaranteed parseable)
  [IO.File]::WriteAllText((Resolve-Path $ExecPath), $headContent, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Restored $ExecPath from HEAD." -ForegroundColor Yellow
} else {
  Write-Host "Keeping working copy of $ExecPath (no HEAD version found)." -ForegroundColor Yellow
}

# 2) Use Python/AST to inject the guard safely (handles docstring + indentation)
$py = @'
import ast, sys, io, os, re, pathlib

fn = r"src\ctrader\execution\coinspot_execution.py"
with open(fn, "r", encoding="utf-8") as f:
    src = f.read()

# Ensure import once (after import block, else at top)
import_line = "from ctrader.utils.live_guard import assert_live_ok\n"
if import_line not in src:
    lines = src.splitlines(True)
    i = 0
    # Skip shebang/encoding lines too
    while i < len(lines) and (lines[i].startswith("#!") or lines[i].lower().startswith("# -*- coding")):
        i += 1
    # Import block
    while i < len(lines) and (lines[i].startswith("import ") or lines[i].startswith("from ")):
        i += 1
    lines.insert(i, import_line)
    src = "".join(lines)

# Parse and locate function
try:
    tree = ast.parse(src)
except Exception as e:
    print("PARSE_FAIL_BEFORE", e)
    sys.exit(2)

func = None
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name == "place_plan_coinspot":
        func = node
        break
if func is None:
    # Nothing to do.
    print("NO_FUNC")
    with open(fn, "w", encoding="utf-8", newline="") as f:
        f.write(src)
    sys.exit(0)

# Compute insertion line just after docstring if present
insert_after = func.lineno  # 1-indexed
if func.body:
    first = func.body[0]
    if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) and isinstance(first.value.value, str):
        # docstring present
        insert_after = (getattr(first, "end_lineno", None) or first.lineno)

# Determine indentation: use the first real body node's col_offset if available
indent_cols = 4
for n in func.body:
    if not (isinstance(n, ast.Expr) and isinstance(getattr(n,"value",None), ast.Constant) and isinstance(n.value.value, str)):
        indent_cols = getattr(n, "col_offset", 4)
        break
indent = " " * max(indent_cols, 4)

# Remove any previous bad/duplicate injected guard near top of function
lines = src.splitlines(True)
start = func.lineno - 1
end = (func.body[-1].end_lineno if func.body else func.lineno)  # best-effort
pattern = re.compile(r"^\s*#\s*Safety:.*\r?\n\s*assert_live_ok\(\)\r?$", re.M)
block = "".join(lines[start:end])
block_clean = pattern.sub("", block, count=1)
if block != block_clean:
    lines[start:end] = [block_clean]

# Insert guard only if missing in function body
joined = "".join(lines)
func_src = joined.splitlines(True)[func.lineno-1 : (func.body[-1].end_lineno if func.body else func.lineno)]
if "assert_live_ok()" not in "".join(func_src):
    insert_idx = insert_after  # 1-indexed
    guard_block = f"{indent}# Safety: block accidental live trades\n{indent}assert_live_ok()\n"
    if insert_idx < len(lines):
        lines.insert(insert_idx, guard_block)
    else:
        lines.append(guard_block)

src2 = "".join(lines)

# Final sanity parse
try:
    ast.parse(src2)
except Exception as e:
    print("PARSE_FAIL_AFTER", e)
    sys.exit(3)

with open(fn, "w", encoding="utf-8", newline="") as f:
    f.write(src2)

print("PATCHED_OK")
'@

$pyFile = Join-Path $env:TEMP "inject_guard_ast.py"
[IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding($false)))
Invoke-Cmd $VenvPy @($pyFile)

# 3) Format & lint to confirm success
Invoke-Cmd $VenvPy @('-m','black','--','src')
Invoke-Cmd $VenvPy @('-m','isort','--','src')
Invoke-Cmd $VenvPy @('-m','flake8','src')

# 4) Stage/commit and run hooks
git add $ExecPath $GuardPath | Out-Null
if (git diff --staged --name-only) {
  Invoke-Cmd 'git' @('commit','-m','fix(safety): restore clean coinspot_execution and inject live guard via AST (safe indent)')
}

Invoke-Cmd 'pre-commit' @('clean')
& pre-commit run -a
if ($LASTEXITCODE -ne 0) {
  git add -A | Out-Null
  Invoke-Cmd 'pre-commit' @('run','-a')
}

Write-Host "`n✅ Repaired indentation and injected guard safely. Hooks should now pass." -ForegroundColor Green
