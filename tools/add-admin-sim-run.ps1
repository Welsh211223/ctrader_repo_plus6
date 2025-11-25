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

# --- 1) Patch the HTML button to use /admin/sim-run instead of /admin/sim-now
if($content -match '/admin/sim-now'){
    Info "Replacing href=\"/admin/sim-now\" with href=\"/admin/sim-run\" in dashboard HTML..."
    $content = $content -replace 'href="/admin/sim-now"', 'href="/admin/sim-run"'
} else {
    Info "No href=\"/admin/sim-now\" found – skipping HTML href patch."
}

# --- 2) Add a clean /admin/sim-run route if it doesn't exist
if($content -match 'def admin_sim_run'){
    Ok "admin_sim_run route already defined – nothing to do."
} else {
    $pattern = 'if __name__\s*==\s*["'']__main__["'']\s*:'
    $match   = [regex]::Match($content, $pattern)

    if(-not $match.Success){
        Warn "Could not find 'if __name__ == \"__main__\":' block in dashboard.py – cannot safely inject route."
    } else {
        $route = @"
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

        Info "Injecting /admin/sim-run route before the main guard..."
        $idx       = $match.Index
        $before    = $content.Substring(0, $idx)
        $after     = $content.Substring($idx)
        $content   = $before + "`r`n" + $route + "`r`n" + $after

        Ok "Added /admin/sim-run route to dashboard.py."
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)

Ok "dashboard.py patched (button href + /admin/sim-run route)."

Info "Verifying admin_sim_run snippet..."
Select-String -Path $path -Pattern 'admin_sim_run','/admin/sim-run' -Context 2,5 | ForEach-Object {
    '-----'
    $_.Line
    $_.Context.PreContext
    $_.Context.PostContext
}
