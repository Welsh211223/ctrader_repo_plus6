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

# Remove the FIRST /admin/sim-now block only, leaving the second one
$pattern = '(?s)@app\.route\("/admin/sim-now"\).*?return Response\(html, mimetype="text/html"\)\s*'

if(-not [regex]::IsMatch($content, $pattern)){
    Warn "No /admin/sim-now route block found to remove."
    exit 0
}

$newContent = [regex]::Replace($content, $pattern, '', 1)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $newContent, $utf8NoBom)

Ok "Removed one /admin/sim-now block to fix duplicate endpoint."
