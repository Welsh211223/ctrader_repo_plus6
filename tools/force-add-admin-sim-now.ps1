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

# 1) If admin_sim_now already exists, bail out
if($content -match 'def admin_sim_now'){
    Ok "admin_sim_now already defined – nothing to do."
    exit 0
}

# 2) Find the main guard in a flexible way: if __name__ == "__main__":
$pattern = 'if __name__\s*==\s*["'']__main__["'']\s*:'
$match   = [regex]::Match($content, $pattern)

if(-not $match.Success){
    Warn "Could not find 'if __name__ == \"__main__\":' block in dashboard.py – cannot safely inject route."
    exit 1
}

$route = @"
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

Info "Injecting /admin/sim-now route before the main guard..."

$insertIndex = $match.Index
$before      = $content.Substring(0, $insertIndex)
$after       = $content.Substring($insertIndex)

$newContent  = $before + "`r`n" + $route + "`r`n" + $after

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $newContent, $utf8NoBom)

Ok "Added /admin/sim-now route to dashboard.py."

Info "Verifying presence of admin_sim_now..."
Select-String -Path $path -Pattern 'admin_sim_now','/admin/sim-now' -Context 2,3 | ForEach-Object {
    "-----"
    $_.Line
    $_.Context.PreContext
    $_.Context.PostContext
}
