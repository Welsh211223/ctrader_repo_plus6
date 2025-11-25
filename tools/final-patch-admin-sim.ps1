$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "[OK]  $m"  -ForegroundColor Green }

# 1) Work out repo root and target dashboard.py
$toolsDir = Split-Path -Parent $PSCommandPath
$root     = Split-Path $toolsDir -Parent
$path     = Join-Path $root 'dashboard.py'

if (-not (Test-Path $path)) {
    throw "Could not find dashboard.py at expected location: $path"
}

Info "Target dashboard file: $path"

# 2) Load existing content as one big string
$content = Get-Content -Path $path -Raw

# 2a) Remove any existing /admin/sim-now route blocks (even if mangled)
# Pattern: decorator + def admin_sim_now(...) + body up to next decorator/def or EOF
$content = [regex]::Replace(
    $content,
    '(?ms)^@app\.route\("/admin/sim-now"\)\s*[\r\n]+def\s+admin_sim_now\([^)]*\):.*?(?=^@app\.route\("|^def\s+\w+\s*\(|\Z)',
    ''
)

# 2b) Remove any existing /admin/routes-debug route blocks
$content = [regex]::Replace(
    $content,
    '(?ms)^@app\.route\("/admin/routes-debug"\)\s*[\r\n]+def\s+admin_routes_debug\([^)]*\):.*?(?=^@app\.route\("|^def\s+\w+\s*\(|\Z)',
    ''
)

# 3) Patch Run Sim button href to point at /admin/sim-now
if ($content -match 'href="/admin/sim-run"') {
    Info 'Patching HTML button href="/admin/sim-run" -> "/admin/sim-now"...'
    $content = $content -replace 'href="/admin/sim-run"', 'href="/admin/sim-now"'
}
elseif ($content -match 'href="/admin/sim-http"') {
    Info 'Patching HTML button href="/admin/sim-http" -> "/admin/sim-now"...'
    $content = $content -replace 'href="/admin/sim-http"', 'href="/admin/sim-now"'
}
elseif ($content -match 'href="/admin/sim-now"') {
    Info 'Run sim button already points to /admin/sim-now.'
}
else {
    Warn 'Could not find Run sim button href – HTML left as-is.'
}

# 4) Prepare clean Flask routes to append

$simRoute = @'
@app.route("/admin/sim-now")
def admin_sim_now():
    """
    Kick a fresh sim run so sim_report.csv + sim_loop_log.csv update.
    """
    import subprocess
    import os

    try:
        subprocess.run(
            [
                "pwsh",
                "-NoLogo",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join("tools", "run-sim.ps1"),
                "-Strategy",
                "both",
            ],
            check=True,
        )
        msg = "Sim run completed."
    except Exception as e:
        msg = f"Sim run failed: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back to dashboard</a></p>
    </body>"""
    return Response(html, mimetype="text/html")
'@

$routesRoute = @'
@app.route("/admin/routes-debug")
def admin_routes_debug():
    """
    Debug endpoint: list all Flask routes this app knows about.
    """
    lines = []
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        methods = ",".join(sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS")))
        lines.append(f"{rule.rule}  [{methods}] -> {rule.endpoint}")
    body = "<pre>" + "\n".join(lines) + "</pre>"
    return body
'@

# 5) Append routes at end of file (clean versions only)

# Trim trailing whitespace/newlines first
$content = $content.TrimEnd()

# Add two blank lines and then our routes
$content = $content + "`r`n`r`n" + $simRoute + "`r`n`r`n" + $routesRoute

# 6) Write back file as UTF-8 (no BOM)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)

Ok "dashboard.py patched: href fixed, admin_sim_now + admin_routes_debug rewritten cleanly."

# 7) Quick verification snippet
Info "Verifying admin_sim_now/admin_routes_debug in $path..."
Select-String -Path $path `
    -Pattern 'admin_sim_now','/admin/sim-now','admin_routes_debug','/admin/routes-debug' `
    -Context 1,3 |
    ForEach-Object {
        '-----'
        $_.Path + ':' + $_.LineNumber
        $_.Line
        $_.Context.PreContext
        $_.Context.PostContext
    }
