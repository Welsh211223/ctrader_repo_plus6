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
