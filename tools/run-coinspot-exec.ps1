[CmdletBinding()]
param(
  [string]$Signals,
  [int]   $Live        = 0,
  [double]$MinNotional = 25,
  [double]$DefaultPrice = 0
)
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path

# resolve python
$pyExe = Join-Path $repoRoot ".venv\Scripts\python.exe"
if(-not (Test-Path -LiteralPath $pyExe)){
  $pyCmd = Get-Command py -ErrorAction SilentlyContinue
  if(-not $pyCmd){ throw "Python not found for executor." }
  $pyExe = $pyCmd.Source
}

# executor script
$execPy = Join-Path $repoRoot "api\coinspot_exec.py"
if(-not (Test-Path -LiteralPath $execPy)){ throw "Executor not found: $execPy" }

# resolve signals CSV
if([string]::IsNullOrWhiteSpace($Signals)){
  $pref1 = Join-Path $repoRoot "paper_trades.csv"
  $pref2 = Join-Path $repoRoot "out\demo-log.csv"
  if(Test-Path -LiteralPath $pref1){ $Signals = $pref1 }
  elseif(Test-Path -LiteralPath $pref2){ $Signals = $pref2 }
  else { throw "Signals CSV not found (pass -Signals)" }
}else{
  if(-not (Test-Path -LiteralPath $Signals)){
    $try = Join-Path $repoRoot $Signals
    if(Test-Path -LiteralPath $try){ $Signals = $try }
  }
  if(-not (Test-Path -LiteralPath $Signals)){ throw "Signals CSV not found: $Signals" }
}

# build args
$argsList = @("--signals", $Signals, "--min-notional", $MinNotional, "--live", $Live)
if($PSBoundParameters.ContainsKey("DefaultPrice")){ $argsList += @("--default-price", $DefaultPrice) }

# echo
$display = ($argsList | ForEach-Object { $_.ToString() }) -join ' '
Write-Host "Running executor:" -ForegroundColor DarkGray
Write-Host "  `"$pyExe`" `"$execPy`" $display" -ForegroundColor DarkGray
if($Live -eq 0){
  Write-Host "DRY-RUN: no orders will be sent. Set -Live 1 for live mode after wiring API keys." -ForegroundColor Yellow
}

# run
& $pyExe $execPy @argsList
if($LASTEXITCODE -ne 0){ throw "Executor returned non-zero exit code: $LASTEXITCODE" }
