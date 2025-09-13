# tools/deep-repair-coinspot.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Cmd {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

$VenvPy   = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }
$ExecPath = "src\ctrader\execution\coinspot_execution.py"
$Guard    = "src\ctrader\utils\live_guard.py"
if (-not (Test-Path $ExecPath)) { throw "Missing $ExecPath" }
if (-not (Test-Path (Split-Path $Guard))) { New-Item -ItemType Directory -Force -Path (Split-Path $Guard) | Out-Null }

# Ensure guard exists
$guardSrc = @'
"""
Runtime guard for live trading.
"""
from __future__ import annotations
import os, time
from pathlib import Path

_TRUTHY = {"1", "true", "yes", "on"}

def _is_truthy(val: str | None) -> bool:
    if val is None:
        return False
    return val.strip().lower() in _TRUTHY

def assert_live_ok(now: float | None = None) -> None:
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
            if age <= 3600:
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
[IO.File]::WriteAllText((Resolve-Path $Guard), $guardSrc, (New-Object System.Text.UTF8Encoding($false)))

# Python fixer (repairs top-level unexpected indents, injects guard via AST, prints context if still broken)
$py = @'
import ast, re, sys, json

FN = r"src\ctrader\execution\coinspot_execution.py"

def read(fn):
    with open(fn, "r", encoding="utf-8") as f:
        return f.read().replace("\r\n","\n")

def write(fn, s):
    with open(fn, "w", encoding="utf-8", newline="") as f:
        f.write(s)

def try_parse(s):
    try:
        ast.parse(s)
        return True, None
    except (IndentationError, SyntaxError) as e:
        return False, e

def nearest_context(s, lineno, radius=6):
    lines = s.split("\n")
    i0 = max(1, (lineno or 1)-radius)
    i1 = min(len(lines), (lineno or 1)+radius)
    out = []
    for i in range(i0, i1+1):
      mark = ">>" if i == lineno else "  "
      out.append(f"{mark} {i:4d}: {lines[i-1]}")
    return "\n".join(out)

src = read(FN)

# Phase 1: auto-repair unexpected top-level indents without altering block bodies.
# Heuristic: if we're NOT inside (), [], {}, nor triple-quoted string, and expected indent is 0,
# then any non-empty, non-comment line with leading spaces is dedented to 0.
def repair_top_indents(s):
    lines = s.split("\n")
    paren = 0
    in_triple = None
    triple_pat = ("'''", '"""')
    expected_stack = [0]
    for idx, line in enumerate(lines):
        raw = line
        # toggle triple quotes (rough but effective for docstrings)
        if not in_triple:
            for tq in triple_pat:
                if tq in line:
                    # enter if odd count
                    if line.count(tq) % 2 == 1:
                        in_triple = tq
                        break
        else:
            if in_triple in line and (line.count(in_triple) % 2 == 1):
                in_triple = None
            continue  # do not touch lines inside triple-quoted strings

        # track paren depth crudely (ignore strings)
        paren += line.count("(") + line.count("[") + line.count("{")
        paren -= line.count(")") + line.count("]") + line.count("}")

        if paren > 0:
            continue  # continuation lines: leave as-is

        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue

        # update expected indent based on previous blocks (rough, but we only care about top-level)
        # If line endswith ":" -> push expected indent for next line
        # If current indent less than top -> pop
        indent = len(line) - len(stripped)
        top = expected_stack[-1]

        # If we seem to be at top level (no open blocks tracked), force left align
        if top == 0 and indent > 0:
            # Don't touch decorators
            if not stripped.startswith("@"):
                lines[idx] = stripped

        # Manage simple block stack for following lines
        # Push if this line is a block header
        if stripped.endswith(":") and not stripped.startswith("@"):
            expected_stack.append((len(lines[idx]) - len(lines[idx].lstrip())) + 4)
        else:
            # Dedent if we see a shallower indent
            while len(expected_stack) > 1 and (len(lines[idx]) - len(lines[idx].lstrip())) < expected_stack[-1]:
                expected_stack.pop()

    return "\n".join(lines)

# Run several passes (in case multiple top-level indents exist)
for _ in range(5):
    ok, err = try_parse(src)
    if ok:
        break
    src2 = repair_top_indents(src)
    if src2 == src:
        break
    src = src2

ok, err = try_parse(src)
if not ok:
    print("STILL_BROKEN", type(err).__name__, getattr(err, "lineno", None))
    print(nearest_context(src, getattr(err, "lineno", 1)))
    sys.exit(2)

# Ensure the guard import exists once (after import block)
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

# Inject assert_live_ok() at the top of place_plan_coinspot
tree = ast.parse(src)
target = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "place_plan_coinspot":
        target = node
        break

if target is not None:
    insert_after = target.lineno
    if target.body:
        first = target.body[0]
        if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) and isinstance(first.value.value, str):
            insert_after = getattr(first, "end_lineno", first.lineno)

    # Determine indent from the first real statement, else 4
    indent_cols = 4
    for n in target.body:
        if not (isinstance(n, ast.Expr) and isinstance(getattr(n,"value",None), ast.Constant) and isinstance(n.value.value, str)):
            indent_cols = getattr(n, "col_offset", 4)
            break
    indent = " " * max(indent_cols, 4)

    lines = src.splitlines(True)
    start = target.lineno - 1
    end   = (target.body[-1].end_lineno if target.body else target.lineno)

    # Remove stale injected guard if present near the top
    block = "".join(lines[start:end])
    block = re.sub(r"^\s*#\s*Safety:.*\r?\n\s*assert_live_ok\(\)\r?$", "", block, count=1, flags=re.M)
    lines[start:end] = [block]

    # Only insert if missing
    joined = "".join(lines)
    body_text = joined.splitlines(True)[target.lineno-1 : end]
    if "assert_live_ok()" not in "".join(body_text):
        guard_block = f"{indent}# Safety: block accidental live trades\n{indent}assert_live_ok()\n"
        lines.insert(insert_after, guard_block)

    src = "".join(lines)

# Final sanity parse
ok, err = try_parse(src)
if not ok:
    print("STILL_BROKEN_AFTER", type(err).__name__, getattr(err, "lineno", None))
    print(nearest_context(src, getattr(err, "lineno", 1)))
    sys.exit(3)

write(FN, src)
print("OK")
'@

$pyFile = Join-Path $env:TEMP "deep_repair_coinspot.py"
[IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding($false)))

# Run the deep repair
Invoke-Cmd $VenvPy @($pyFile)

# Format & lint, then hooks
Invoke-Cmd $VenvPy @('-m','black','--','src')
Invoke-Cmd $VenvPy @('-m','isort','--','src')
Invoke-Cmd $VenvPy @('-m','flake8','src')

git add $ExecPath $Guard 2>$null | Out-Null
if (git diff --staged --name-only) {
  Invoke-Cmd 'git' @('commit','-m','fix(safety): deep repair of indentation + guard injection for coinspot_execution')
}

Invoke-Cmd 'pre-commit' @('clean')
& pre-commit run -a
if ($LASTEXITCODE -ne 0) {
  git add -A | Out-Null
  Invoke-Cmd 'pre-commit' @('run','-a')
}

Write-Host "`n✅ Deep repair complete." -ForegroundColor Green
