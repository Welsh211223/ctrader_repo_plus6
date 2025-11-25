$ErrorActionPreference = 'Stop'

function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }

$toolsDir = Split-Path -Parent $PSCommandPath
$root     = Split-Path $toolsDir -Parent
$path     = Join-Path $root 'dashboard.py'

if(-not (Test-Path $path)){
    Warn "dashboard.py not found at: $path"
    exit 1
}

Info "Loading dashboard.py from: $path"
$content = Get-Content $path -Raw

# Patterns for admin routes we might have duplicated
$patterns = @(
    '(?s)@app\.route\("/admin/sim-now"\).*?return Response\(html, mimetype="text/html"\)\s*',
    '(?s)@app\.route\("/admin/sim-backtest-now"\).*?return Response\(html, mimetype="text/html"\)\s*',
    '(?s)@app\.route\("/admin/live/<mode>"\).*?return Response\(html, mimetype="text/html"\)\s*'
)

foreach($pattern in $patterns){
    $matches = [regex]::Matches($content, $pattern)
    if($matches.Count -gt 1){
        $toRemove = $matches.Count - 1
        Info "Found $($matches.Count) blocks for pattern, removing $toRemove extra..."
        for($i = 0; $i -lt $toRemove; $i++){
            $content = [regex]::Replace($content, $pattern, '', 1)
        }
    } elseif($matches.Count -eq 1){
        Info "Pattern has exactly one block – OK."
    } else {
        Info "Pattern not found – nothing to do."
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)

Ok "Deduplicated admin sim/sim-backtest/live routes in dashboard.py."
