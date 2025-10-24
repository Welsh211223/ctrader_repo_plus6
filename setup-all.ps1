[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$SheetId,
  [Parameter(Mandatory=$true)]  [string]$TabName,
  [Parameter(Mandatory=$true)]  [string]$ServiceAccount,
  [string]$SignalsCsv = ".\paper_trades.csv",

  [string]$TaskName = "ctrader-paper-daily",
  [string]$TaskPath = "\",

  [int]$LiveDefault = 0,
  [double]$MinNotional = 25.0,
  [double]$DefaultPrice = 0
)

$ErrorActionPreference = "Stop"
function Good($m){ Write-Host $m -ForegroundColor Green }
function Warn($m){ Write-Host $m -ForegroundColor Yellow }
function Info($m){ Write-Host $m -ForegroundColor DarkGray }
function Fail($m){ Write-Error $m; exit 1 }

# --- repo layout ---
$Repo = $PSScriptRoot
if (-not $Repo) { $Repo = (Get-Location).Path }
$ApiDir   = Join-Path $Repo "api"
$ToolsDir = Join-Path $Repo "tools"
$OutDir   = Join-Path $Repo "out"
$Secrets  = Join-Path $Repo "secrets"
$DefaultCsv = Join-Path $OutDir "demo-log.csv"

New-Item -ItemType Directory -Force $ApiDir,$ToolsDir,$OutDir,$Secrets | Out-Null

# --- inputs ---
if (-not $SheetId){ Fail "SheetId is required." }
if (-not $TabName){ Fail "TabName is required." }

# Resolve service account path (PS5-friendly)
$saResolved = $null
try { $saResolved = (Resolve-Path -LiteralPath $ServiceAccount -ErrorAction Stop).Path } catch {}
if (-not $saResolved) { Fail "Service account JSON not found: $ServiceAccount" }
$ServiceAccount = $saResolved

# --- choose python ---
$VenvPy = Join-Path $Repo ".venv\Scripts\python.exe"
if (Test-Path -LiteralPath $VenvPy) {
  $PyToUse = $VenvPy
} else {
  $pyCmd = Get-Command py -ErrorAction SilentlyContinue
  if (-not $pyCmd) { Fail "No venv or 'py.exe' found. Create venv:  py -3.10 -m venv .venv" }
  $PyToUse = $pyCmd.Source
  Warn "Using Python launcher: $PyToUse"
}

# --- api\push_to_sheets.py ---
$PushPy = Join-Path $ApiDir "push_to_sheets.py"
@'
import os, re, csv, sys, argparse
import gspread
from google.oauth2.service_account import Credentials
from gspread.exceptions import WorksheetNotFound

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]

def get_client(sa_path: str):
    path = sa_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path or not os.path.exists(path):
        sys.exit("Service account JSON not found. Pass --sa or set GOOGLE_APPLICATION_CREDENTIALS.")
    creds = Credentials.from_service_account_file(path, scopes=SCOPES)
    return gspread.authorize(creds)

def open_sheet(gc, sheet_id: str):
    sid = sheet_id or os.environ.get("SHEET_ID")
    if not sid:
        sys.exit("No spreadsheet specified. Set SHEET_ID or pass --sheet-id.")
    if re.fullmatch(r"[A-Za-z0-9_-]{20,}", sid):
        return gc.open_by_key(sid)
    sys.exit("Pass a spreadsheet ID (not title).")

def ensure_worksheet(sh, title: str):
    tab = title or os.environ.get("TAB") or "Sheet1"
    try:
        return sh.worksheet(tab)
    except WorksheetNotFound:
        return sh.add_worksheet(title=tab, rows=2000, cols=26)

def main():
    ap = argparse.ArgumentParser(description="Append a CSV into a Google Sheet (no Drive API).")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--sheet-id")
    ap.add_argument("--tab")
    ap.add_argument("--sa")
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        sys.exit(f"CSV not found: {args.csv}")

    gc = get_client(args.sa)
    sh = open_sheet(gc, args.sheet_id)
    ws = ensure_worksheet(sh, args.tab)

    with open(args.csv, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    if not rows:
        print("CSV empty; nothing to append.")
        return

    ws.append_rows(rows, value_input_option="USER_ENTERED")
    print(f"Appended {len(rows)} rows -> {sh.title} / {ws.title}")

if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding UTF8 $PushPy
Good "Wrote $PushPy"

# --- tools\push-to-sheets.ps1 ---
$PushPS1 = Join-Path $ToolsDir "push-to-sheets.ps1"
@'
[CmdletBinding()]
param(
  [string]$CsvPath,
  [string]$Tab = $env:TAB,
  [string]$SheetId = $env:SHEET_ID,
  [string]$ServiceAccount = $env:GOOGLE_APPLICATION_CREDENTIALS,
  [string]$Python = ".\.venv\Scripts\python.exe",
  [switch]$Quiet,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
function Write-Info($m){ if(-not $Quiet){ Write-Host $m -ForegroundColor DarkGray } }
function Fail($m){ Write-Error $m; exit 1 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = (Resolve-Path (Join-Path $scriptDir "..")).Path
$pyHelper  = Join-Path $repoRoot "api\push_to_sheets.py"
if(-not (Test-Path $pyHelper)){ Fail "Python helper not found: $pyHelper" }

# resolve Python
if(-not (Test-Path -LiteralPath $Python)){
  $pyCmd = Get-Command py -ErrorAction SilentlyContinue
  if($pyCmd){ $Python = $pyCmd.Source } else { Fail "Preferred python not found and 'py' launcher missing." }
}

# resolve CSV
function Resolve-Csv([string]$Given){
  if($Given){
    $p = $Given
    if(-not (Test-Path -LiteralPath $p)){
      $try = Join-Path $repoRoot $Given
      if(Test-Path -LiteralPath $try){ $p = $try }
    }
    if(-not (Test-Path -LiteralPath $p)){ Fail "CSV not found: $Given" }
    return (Resolve-Path -LiteralPath $p).Path
  }
  $pref1 = Join-Path $repoRoot "out\demo-log.csv"
  if(Test-Path $pref1 -PathType Leaf){ return $pref1 }
  $pref2 = Join-Path $repoRoot "paper_trades.csv"
  if(Test-Path $pref2 -PathType Leaf){ return $pref2 }
  $csv = Get-ChildItem -Path $repoRoot -Recurse -File -Filter *.csv -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch "\\(\.venv|node_modules|\.git)\\" } |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if($csv){ return $csv.FullName }
  Fail "No CSV found. Create one (e.g., .\out\demo-log.csv) or pass -CsvPath."
}
$csvFull = Resolve-Csv -Given $CsvPath

# sheet + creds
if([string]::IsNullOrWhiteSpace($SheetId)){ Fail "No Spreadsheet ID. Use -SheetId or set SHEET_ID." }
if($ServiceAccount -and -not (Test-Path -LiteralPath $ServiceAccount)){ Fail "Service account JSON not found: $ServiceAccount" }
$env:TAB = $Tab

# deps smoke test
try{ $null = & $Python -c "import gspread; from google.oauth2 import service_account; print('ok')" 2>$null } catch{
  Write-Host "Install deps:" -ForegroundColor Yellow
  Write-Host "  $Python -m pip install gspread google-auth google-auth-oauthlib" -ForegroundColor Yellow
  Fail "Missing Python dependencies."
}

$pyArgs = @($pyHelper,'--csv',$csvFull,'--sheet-id',$SheetId)
if($ServiceAccount){ $pyArgs += @('--sa',$ServiceAccount) }
if($Tab){            $pyArgs += @('--tab',$Tab) }

Write-Info "CSV      : $csvFull"
Write-Info "Sheet ID : $SheetId"
Write-Info "Tab      : $Tab"
if($ServiceAccount){ Write-Info "SA JSON  : $ServiceAccount" } else { Write-Info "SA JSON  : (using env GOOGLE_APPLICATION_CREDENTIALS)" }
Write-Info "Command  : $Python $($pyArgs -join ' ')"

if($DryRun){ Write-Host "(DryRun) Would execute the command above." -ForegroundColor Cyan; exit 0 }

& $Python @pyArgs
if($LASTEXITCODE -ne 0){ Fail "Uploader returned non-zero exit code: $LASTEXITCODE" }
'@ | Set-Content -Encoding UTF8 $PushPS1
Good "Wrote $PushPS1"

# --- api\coinspot_exec.py (preview only) ---
$ExecPy = Join-Path $ApiDir "coinspot_exec.py"
@'
import csv, argparse, sys

def read_signals(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows

def tofloat(v, dflt=0.0):
    try:
        return float(str(v).strip())
    except:
        return dflt

def normalize_symbol(sym:str)->str:
    s = (sym or "").strip().upper()
    if "/" in s:
        return s
    return f"{s}/AUD" if s else s

def main():
    ap = argparse.ArgumentParser(description="CoinSpot executor (PREVIEW ONLY).")
    ap.add_argument("--signals", required=True)
    ap.add_argument("--min-notional", type=float, default=25.0)
    ap.add_argument("--default-price", type=float, default=0.0)
    ap.add_argument("--live", type=int, default=0)
    args = ap.parse_args()

    sigs = read_signals(args.signals)
    if not sigs:
        print("No signals found.")
        return

    planned = []
    for r in sigs:
        side   = (r.get("side") or r.get("action") or "").strip().lower()
        amount = tofloat(r.get("amount") or r.get("qty") or r.get("quantity"), 0.0)
        price  = tofloat(r.get("price"), args.default_price)
        sym    = normalize_symbol(r.get("symbol") or r.get("pair") or r.get("asset"))

        if side not in ("buy","sell"):
            continue
        notional = 0.0 if price <= 0 else amount * price
        if args.min_notional > 0 and notional > 0 and notional < args.min_notional:
            continue

        planned.append({"symbol": sym, "side": side, "amount": amount, "price": price, "notional": notional})

    print(f"Found {len(planned)} eligible signal(s). Mode: {'LIVE' if args.live==1 else 'PREVIEW'}")
    for p in planned:
        print(f" - {p['side'].upper():4} {p['amount']} {p['symbol']} @ {p['price']} (notional≈{p['notional']})")

    if args.live == 1:
        print("LIVE requested — but this stub does NOT place real orders.")
        sys.exit(2)

if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding UTF8 $ExecPy
Good "Wrote $ExecPy"

# --- tools\run-coinspot-exec.ps1 (fill defaults with -f) ---
$RunnerPs = Join-Path $ToolsDir "run-coinspot-exec.ps1"
$runnerTemplate = @'
[CmdletBinding()]
param(
  [string]$Signals,
  [int]   $Live        = {0},
  [double]$MinNotional = {1},
  [double]$DefaultPrice = {2}
)
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$pyExe    = Join-Path $repoRoot ".venv\Scripts\python.exe"
if(-not (Test-Path -LiteralPath $pyExe)){
  $pyCmd = Get-Command py -ErrorAction SilentlyContinue
  if(-not $pyCmd){ throw "Python not found for executor." }
  $pyExe = $pyCmd.Source
}
$execPy  = Join-Path $repoRoot "api\coinspot_exec.py"
if(-not (Test-Path -LiteralPath $execPy)){ throw "Executor not found: $execPy" }

# resolve signals
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

$argsList = @("--signals", $Signals, "--min-notional", $MinNotional, "--live", $Live)
if($PSBoundParameters.ContainsKey("DefaultPrice")){ $argsList += @("--default-price", $DefaultPrice) }

$display = ($argsList | ForEach-Object { $_.ToString() }) -join ' '
Write-Host "Running executor:" -ForegroundColor DarkGray
Write-Host "  `"$pyExe`" `"$execPy`" $display" -ForegroundColor DarkGray

& $pyExe $execPy @argsList
if($LASTEXITCODE -ne 0){ throw "Executor returned non-zero exit code: $LASTEXITCODE" }
'@
$runnerFilled = [string]::Format($runnerTemplate, $LiveDefault, $MinNotional, $DefaultPrice)
$runnerFilled | Set-Content -Encoding UTF8 $RunnerPs
Good "Wrote $RunnerPs"

# --- session envs ---
$env:SHEET_ID = $SheetId
$env:TAB = $TabName
$env:GOOGLE_APPLICATION_CREDENTIALS = $ServiceAccount
Info "Session envs set: SHEET_ID, TAB, GOOGLE_APPLICATION_CREDENTIALS"

# --- demo CSV if needed ---
if(-not (Test-Path -LiteralPath $DefaultCsv)){
@"
time,thing,value
$((Get-Date).ToString('s')),smoke-test,1
$((Get-Date).ToString('s')),smoke-test,2
"@ | Set-Content -Encoding UTF8 $DefaultCsv
  Info "Created $DefaultCsv"
}

# --- ensure deps (Sheets) ---
& $PyToUse -m pip install --disable-pip-version-check --quiet gspread google-auth google-auth-oauthlib | Out-Null
Good "Python deps present for Sheets push."

# --- one-time push ---
& $PushPS1 -Tab $TabName -SheetId $SheetId -ServiceAccount $ServiceAccount | Write-Host

# --- scheduled task wiring (idempotent) ---
$task = $null
try { $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName } catch {}

if ($task) {
  $actions = @($task.Actions)

  $hasPush = @($actions | Where-Object { $_.Arguments -match 'push-to-sheets\.ps1' })
  if ($hasPush.Count -gt 1) {
    Warn ("Found {0} push-to-sheets actions; deduping." -f $hasPush.Count)
    $actions = @($actions | Where-Object { $_.Arguments -notmatch 'push-to-sheets\.ps1' })
    $actions += $hasPush[0]
  } elseif ($hasPush.Count -eq 0) {
    $actions += New-ScheduledTaskAction -Execute "powershell.exe" `
      -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -Tab `"{1}`"" -f $PushPS1, $TabName) `
      -WorkingDirectory $Repo
  }

  $hasExec = @($actions | Where-Object { $_.Arguments -match 'run-coinspot-exec\.ps1' })
  if ($hasExec.Count -eq 0) {
    $actions += New-ScheduledTaskAction -Execute "powershell.exe" `
      -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $RunnerPs) `
      -WorkingDirectory $Repo
  }

  $newDef = New-ScheduledTask -Action $actions -Trigger $task.Triggers -Settings $task.Settings -Principal $task.Principal
  Register-ScheduledTask -TaskName $TaskName -InputObject $newDef -Force | Out-Null

  Write-Host ("`nFinal actions for {0}:" -f $TaskName) -ForegroundColor Cyan
  (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).Actions |
    Format-Table Execute,Arguments,WorkingDirectory -Auto
} else {
  Warn ("Scheduled task '{0}{1}' not found - skipping task wiring." -f $TaskPath, $TaskName)
}

Good "`nSetup complete."
Write-Host "Sheets push: ACTIVE." -ForegroundColor Yellow
Write-Host "CoinSpot executor: PREVIEW ONLY (no live orders). For live trading we will add authenticated calls with guardrails and set -Live 1." -ForegroundColor Yellow
