param(
  [ValidateSet("run","lint","format","test","precommit-install","precommit-run")]
  [string]$Task="run"
)

function Exec([string]$cmd){
  Write-Host ">> $cmd"
  & cmd /c $cmd
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $cmd" }
}

switch ($Task) {
  "run"                { Exec "python -m ctrader" }
  "lint"               { Exec "ruff check ."; Exec "isort --check-only ."; Exec "black --check ." }
  "format"             { Exec "ruff check --fix ."; Exec "isort ."; Exec "black ." }
  "test"               { Exec "pytest" }
  "precommit-install"  { Exec "pre-commit install"; Exec "pre-commit install --hook-type commit-msg" }
  "precommit-run"      { Exec "pre-commit run --all-files" }
  default              { Write-Host "Unknown task: $Task"; exit 1 }
}