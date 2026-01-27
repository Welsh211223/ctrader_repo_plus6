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

# --- 1) Patch the Run sim now button to use /admin/sim-run ----------------
if($content -match 'href="/admin/sim-now"'){
    Info 'Patching HTML button href="/admin/sim-now" -> "/admin/sim-run"...'
    $content = $content -replace 'href="/admin/sim-now"', 'href="/admin/sim-run"'
} else {
    Info 'No href="/admin/sim-now" found (button may already be patched).'
}

# --- 2) Remove any existing /admin/sim-run route -------------------------
$patternSim = '(?s)@app\.route\("/admin/sim-run"\).*?return Response\(html, mimetype="text/html"\)\s*'
if([regex]::IsMatch($content, $patternSim)){
    Info "Removing existing /admin/sim-run route block(s)..."
    $content = [regex]::Replace($content, $patternSim, '')
}

# --- 3) Remove any existing /admin/routes debug route --------------------
$patternRoutes = '(?s)@app\.route\("/admin/routes"\).*?return body\s*'
if([regex]::IsMatch($content, $patternRoutes)){
    Info "Removing existing /admin/routes debug route block(s)..."
    $content = [regex]::Replace($content, $patternRoutes, '')
}

# --- 4) Find the main guard (if __name__ == "__main__":) -----------------
$patternMain = 'if __name__\s*==\s*["'']__main__["'']\s*:'
$matchMain   = [regex]::Match($content, $patternMain)
if(-not $matchMain.Success){
    Warn "Could not find 'if __name__ == \"__main__\":' block – cannot inject routes."
    exit 1
}

$simRoute = @"
@app.route("/admin/sim-run")
def admin_sim_run():
    """
    Kick a fresh sim run so sim_report.csv + sim_loop_log.csv update.
    """
    import subprocess

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


"@

$routesRoute = @"
@app.route("/admin/routes")
def admin_routes():
    """
    Debug endpoint: list all Flask routes this app knows about.
    """
    lines = []
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        methods = ",".join(sorted(m for m in rule.methods if m not in ("HEAD","OPTIONS")))
        lines.append(f"{rule.rule}  [{methods}] -> {rule.endpoint}")
    body = "<pre>" + "\\n".join(lines) + "</pre>"
    return body


"@

Info "Injecting /admin/sim-run and /admin/routes before main guard..."
$idx     = $matchMain.Index
$before  = $content.Substring(0, $idx)
$after   = $content.Substring($idx)
$content = $before + "`r`n" + $simRoute + "`r`n" + $routesRoute + "`r`n" + $after

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)

Ok "dashboard.py patched (button -> /admin/sim-run, sim-run route, routes debug)."

Info "Verifying admin_sim_run/admin_routes..."
Select-String -Path $path -Pattern 'admin_sim_run','/admin/sim-run','admin_routes','/admin/routes' -Context 1,3 | ForEach-Object{
  '-----'
  $_.Path + ':' + $_.LineNumber
  $_.Line
  $_.Context.PreContext
  $_.Context.PostContext
}
