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

# 1) Wire the Run sim now button → /admin/sim-http
if($content -match 'href="/admin/sim-now"'){
    Info 'Patching HTML button href="/admin/sim-now" -> "/admin/sim-http"...'
    $content = $content -replace 'href="/admin/sim-now"', 'href="/admin/sim-http"'
}elseif($content -match 'href="/admin/sim-run"'){
    Info 'Patching HTML button href="/admin/sim-run" -> "/admin/sim-http"...'
    $content = $content -replace 'href="/admin/sim-run"', 'href="/admin/sim-http"'
}else{
    Warn 'Could not find Run sim now button href – HTML left as-is.'
}

# 2) Append new routes with unique names and URLs (no regex deletes)
$routeBlock = @"

@app.route("/admin/sim-http")
def admin_sim_http():
    \"\"\"
    Kick a fresh sim run so sim_report.csv + sim_loop_log.csv update.
    \"\"\"
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

    html = f"<!doctype html><meta charset='utf-8'><body style='font-family:system-ui'><p>{msg}</p><p><a href='/'>← Back to dashboard</a></p></body>"
    return Response(html, mimetype="text/html")


@app.route("/admin/routes-debug")
def admin_routes_debug():
    \"\"\"
    Debug endpoint: list all Flask routes this app knows about.
    \"\"\"
    lines = []
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        methods = ",".join(sorted(m for m in rule.methods if m not in ("HEAD","OPTIONS")))
        lines.append(f"{rule.rule}  [{methods}] -> {rule.endpoint}")
    body = "<pre>" + "\\n".join(lines) + "</pre>"
    return body


"""

Info "Appending /admin/sim-http and /admin/routes-debug routes at end of file..."
$newContent = $content.TrimEnd() + "`r`n`r`n" + $routeBlock

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $newContent, $utf8NoBom)

Ok "dashboard.py patched (button → /admin/sim-http, new routes appended)."

Info "Verifying admin_sim_http/admin_routes_debug..."
Select-String -Path $path -Pattern 'admin_sim_http','/admin/sim-http','admin_routes_debug','/admin/routes-debug' -Context 1,3 | ForEach-Object{
  '-----'
  $_.Path + ':' + $_.LineNumber
  $_.Line
  $_.Context.PreContext
  $_.Context.PostContext
}
