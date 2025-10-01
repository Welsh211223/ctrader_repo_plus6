[CmdletBinding()]
param([switch]$CommitAndPush)

$ErrorActionPreference = 'Stop'
function OK($m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function INFO($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function WARN($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function SaveUtf8LF([string]$Path,[string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $norm = ($Content -replace "`r`n","`n") -replace "`r","`n"
  [IO.File]::WriteAllText($Path, $norm, [Text.UTF8Encoding]::new($false))
  OK "Wrote: $Path"
}

# --- Replace static strategy with ctor-weights version ---
$static = @'
from __future__ import annotations
from typing import Dict, Iterable

from ctrader.models import Allocation, Holding
from ctrader.strategies.base import Strategy


class StaticStrategy(Strategy):
    """Use fixed weights provided at construction time."""
    name = "static"

    def __init__(self, weights: Dict[str, float]):
        self._weights = {k.upper(): float(v) for k, v in (weights or {}).items()}

    def target_allocations(self, holdings: Iterable[Holding], universe: Iterable[str], **kwargs) -> Allocation:
        syms = [s.upper() for s in universe]
        # Restrict/extend to the universe; missing symbols get 0
        w = {s: float(self._weights.get(s, 0.0)) for s in syms}
        total = sum(w.values())
        if total <= 0:
            # Fallback to equal if bad weights
            eq = 1.0 / max(1, len(syms))
            return Allocation(weights={s: eq for s in syms})
        norm = {s: (w[s] / total) for s in syms}
        return Allocation(weights=norm)
'@
SaveUtf8LF ".\ctrader\strategies\static.py" $static

# --- Run hooks & tests ---
try { Write-Host ">> pre-commit run --all-files" -ForegroundColor Magenta; & pre-commit run --all-files } catch {}
Write-Host ">> pytest" -ForegroundColor Magenta
& pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest failed ($LASTEXITCODE)" }

# --- Commit & push if requested ---
if ($CommitAndPush) {
  git add -A
  $s = git status --porcelain
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    git commit -m "fix(static): accept weights in ctor; align with CLI usage"
    git push
    OK "Committed and pushed."
  } else {
    INFO "No changes to commit."
  }
}

OK "StaticStrategy fixed. Try: python -m ctrader plan --config configs/example.yml"
