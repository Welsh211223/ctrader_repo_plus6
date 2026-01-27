$ErrorActionPreference = 'Stop'

function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }

$toolsDir = Split-Path -Parent $PSCommandPath
$root     = Split-Path $toolsDir -Parent
$path     = Join-Path $root 'dashboard.py'
$backup   = Join-Path $root 'dashboard.py.bak'

if(-not (Test-Path $path)){
    Warn "dashboard.py not found at: $path"
    exit 1
}

Info "Backing up dashboard.py -> dashboard.py.bak"
Copy-Item -Path $path -Destination $backup -Force

Info "Loading dashboard.py from: $path"
$content = Get-Content $path -Raw

# --- 1) Patch the Run sim now button back to /admin/sim-now ----------
if($content -match 'href="/admin/sim-run"'){
    Info 'Patching HTML button href="/admin/sim-run" -> "/admin/sim-now"...'
    $content = $content -replace 'href="/admin/sim-run"', 'href="/admin/sim-now"'
}
elseif($content -match 'href="/admin/sim-now"'){
    Info 'Run sim button already points to /admin/sim-now.'
}
else{
    Warn 'No Run sim now button href found – leaving HTML as-is.'
}

# --- 2) Strip any existing admin_sim_now/admin_sim_run/admin_routes ----
$pattern = '(?ms)^@app\.route\(".*?/admin/(sim-now|sim-run|routes)".*?^$'

if([regex]::IsMatch($content, $pattern)){
    Info "Removing existing /admin/(sim-now|sim-run|routes) route blocks..."
    $content = [regex]::Replace($content, $pattern, '')
} else {
    Info "No existing /admin/sim-now/sim-run/routes blocks found to remove."
}

# --- 3) Find the main guard (if __name__ == "__main__":) ---------------
$patternMain = 'if __name__\s*==\s*["'']__main__["'']\s*:'
$matchMain   = [regex]::Match($content, $patternMain)
if(-not $matchMain.Success){
    Warn "Could not find 'if __name__ == \"__main__\":' block – cannot inject routes."
    exit 1
}

$simNowRoute = @"
@app.route("/admin/sim-now")
def admin_sim_now():
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

Info "Injecting clean /admin/sim-now and /admin/routes before main guard..."
$idx     = $matchMain.Index
$before  = $content.Substring(0, $idx)
$after   = $content.Substring($idx)
$content = $before + "`r`n" + $simNowRoute + "`r`n" + $routesRoute + "`r`n" + $after

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)

Ok "dashboard.py reset + patched (Run sim -> /admin/sim-now, clean routes)."

Info "Verifying admin_sim_now/admin_routes..."
Select-String -Path $path -Pattern 'admin_sim_now','/admin/sim-now','admin_routes','/admin/routes' -Context 1,3 | ForEach-Object{
  '-----'
  $_.Path + ':' + $_.LineNumber
  $_.Line
  $_.Context.PreContext
  $_.Context.PostContext
}
