# tools/fix-coinspot-structure.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Run {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Args=@())
  Write-Host "▶ $Exe $($Args -join ' ')" -ForegroundColor Cyan
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $Exe $($Args -join ' ') (exit $LASTEXITCODE)" }
}

$VenvPy = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $VenvPy)) { $VenvPy = "python" }
$ExecPath = "src\ctrader\execution\coinspot_execution.py"
if (-not (Test-Path $ExecPath)) { throw "Missing $ExecPath" }

$py = @'
import io, re, sys

FN = r"src\ctrader\execution\coinspot_execution.py"

def read():
    with io.open(FN, "r", encoding="utf-8") as f:
        return f.read().replace("\r\n","\n")

def write(s):
    with io.open(FN, "w", encoding="utf-8", newline="") as f:
        f.write(s)

def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))

def is_blank_or_comment(line: str) -> bool:
    s = line.strip()
    return not s or s.startswith("#")

src = read()
lines = src.split("\n")

# 1) Dedent helper defs that were accidentally nested (e.g., "def _poll_fill")
def_names = [r"_poll_fill", r"_poll_cancel", r"_.*_helper"]
def_pat = re.compile(r"^(\s*)def\s+({})(\s*)\(".format("|".join(def_names)))

i = 0
while i < len(lines):
    m = def_pat.match(lines[i])
    if m:
        cur_indent = len(m.group(1))
        if cur_indent > 0:
            # Dedent whole def block to top-level (indent 0)
            start = i
            j = i + 1
            while j < len(lines):
                # next top-level def/class OR EOF marks the end of this block
                if re.match(r"^(def|class)\s+", lines[j]) and indent_of(lines[j]) == 0:
                    break
                j += 1
            block = lines[start:j]
            dedented = [l[cur_indent:] if l.startswith(" " * cur_indent) else l for l in block]
            lines[start:j] = dedented
            # Recompute because we changed line count/contents
            src = "\n".join(lines)
            lines = src.split("\n")
            # continue scanning after the block
            i = j
            continue
    i += 1

# 2) Ensure body of place_plan_coinspot is properly indented under its def header
def_hdr = None
for idx, line in enumerate(lines):
    if re.match(r"^\s*def\s+place_plan_coinspot\s*\(", line):
        def_hdr = idx
        break

if def_hdr is not None:
    base_indent = indent_of(lines[def_hdr])
    body_start = def_hdr + 1

    # Skip blank lines and an optional docstring line(s)
    while body_start < len(lines) and is_blank_or_comment(lines[body_start]):
        body_start += 1
    # If docstring starts
    if body_start < len(lines) and re.match(r'^\s*(?:"""|\'\'\')', lines[body_start]):
        quote = '"""' if '"""' in lines[body_start] else "'''"
        body_start += 1
        while body_start < len(lines) and (quote not in lines[body_start]):
            body_start += 1
        if body_start < len(lines):
            body_start += 1
        while body_start < len(lines) and is_blank_or_comment(lines[body_start]):
            body_start += 1

    # Find end of function body = next top-level def/class or EOF
    body_end = len(lines)
    for j in range(body_start, len(lines)):
        if re.match(r"^(def|class)\s+", lines[j]) and indent_of(lines[j]) == 0:
            body_end = j
            break

    # Ensure every non-blank/non-comment line in the body is at least base_indent+4
    desired = base_indent + 4
    for k in range(body_start, body_end):
        l = lines[k]
        if is_blank_or_comment(l):
            continue
        if indent_of(l) <= base_indent:
            lines[k] = (" " * desired) + l.lstrip(" ")

# 3) Also make sure any stray 'return ' lines at column 0 between defs
#    get tucked under the nearest previous def (indent = 4).
prev_def_indent = 0
for idx, line in enumerate(lines):
    if re.match(r"^def\s+\w+\s*\(", line):
        prev_def_indent = 0  # top-level
        continue
    if re.match(r"^\s*def\s+\w+\s*\(", line):
        prev_def_indent = indent_of(line)
        continue
    if re.match(r"^return\b", line):  # at col 0(!)
        # Indent under previous function by 4 spaces
        lines[idx] = (" " * (prev_def_indent + 4)) + line

write("\n".join(lines))
print("STRUCTURE_FIXED")
'@

$tmp = Join-Path $env:TEMP "fix_coinspot_structure.py"
Write-Utf8NoBom -Path $tmp -Content $py

# Format + lint
Run $VenvPy @($tmp)
Run $VenvPy @('-m','pip','install','-U','black','isort','flake8') | Out-Null
Run $VenvPy @('-m','black','--','src')
Run $VenvPy @('-m','isort','--','src')
Run $VenvPy @('-m','flake8','src')

git add $ExecPath 2>$null | Out-Null
if (git diff --staged --name-only) {
  Run 'git' @('commit','-m','fix: repair coinspot_execution structure (dedent helpers, normalize function body)')
}

Write-Host "`n✅ coinspot_execution.py structure repaired and linted." -ForegroundColor Green
