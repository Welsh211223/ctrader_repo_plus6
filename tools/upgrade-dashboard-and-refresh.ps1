param(
    [switch]$SkipSim,
    [switch]$SkipBacktest,
    [switch]$SkipNormalize
)

$ErrorActionPreference = 'Stop'

function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!!] $m" -ForegroundColor Yellow }

$toolsDir       = Split-Path -Parent $PSCommandPath
$root           = Split-Path $toolsDir -Parent

$dashboardPath  = Join-Path $root 'dashboard.py'
$runSim         = Join-Path $toolsDir 'run-sim.ps1'
$runBacktest    = Join-Path $toolsDir 'run-sim-backtest.ps1'
$summarizeBack  = Join-Path $toolsDir 'summarize-backtest.ps1'
$normalizeDec   = Join-Path $toolsDir 'normalize-decisions.ps1'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- 1) Upgrade dashboard.py with admin routes --------------------------
if(-not (Test-Path $dashboardPath)){
    Warn "dashboard.py not found at: $dashboardPath"
} else {
    Info "Loading dashboard.py from: $dashboardPath"
    $content = [IO.File]::ReadAllText($dashboardPath)

    if($content -match 'def admin_sim_backtest_now'){
        Ok "Admin sim/backtest/live routes already present in dashboard.py – skipping injection."
    } else {
        $marker = '# --- main'

        if($content -notmatch [regex]::Escape($marker)){
            Warn "Could not find marker '$marker' in dashboard.py – cannot safely inject routes."
        } else {
            Info "Injecting admin sim/backtest/live routes before marker '$marker'..."

$insert = @"
@app.route("/admin/sim-backtest-now")
def admin_sim_backtest_now():
    """
    Kick a fresh sim backtest so sim_backtest.csv + sim_backtest_summary.csv update.
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
                os.path.join("tools", "run-sim-backtest.ps1"),
                "-LookbackDays",
                "90",
                "-StepDays",
                "7",
                "-Strategy",
                "both",
            ],
            check=True,
        )
        subprocess.run(
            [
                "pwsh",
                "-NoLogo",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                os.path.join("tools", "summarize-backtest.ps1"),
            ],
            check=True,
        )
        msg = "Backtest + summary updated."
    except Exception as e:
        msg = f"Backtest failed: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back to dashboard</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


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


@app.route("/admin/live/<mode>")
def admin_live(mode):
    """
    Toggle live flag via /admin/live/on or /admin/live/off.
    NOTE: This ONLY controls the dashboard flag + config/live.flag.
          Wire your actual live trading engine to read config/live.flag
          (or an env var) before trusting this in production.
    """
    mode = (mode or "").lower()
    wanted = None
    if mode in ("on", "enable", "enabled", "1", "true", "yes"):
        wanted = "1"
    elif mode in ("off", "disable", "disabled", "0", "false", "no"):
        wanted = "0"

    if wanted is None:
        msg = f"Unknown mode '{mode}'. Use /admin/live/on or /admin/live/off."
    else:
        flag_path = os.path.join("config", "live.flag")
        try:
            os.makedirs(os.path.dirname(flag_path), exist_ok=True)
            with open(flag_path, "w", encoding="utf-8") as f:
                f.write(wanted)
            if wanted == "1":
                msg = "Live flag set to ON (config/live.flag = 1)."
            else:
                msg = "Live flag set to OFF (config/live.flag = 0)."
        except Exception as e:
            msg = f"Failed to update live.flag: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back to dashboard</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


"@

            $newContent = $content -replace [regex]::Escape($marker), "$insert`r`n$marker"

            [IO.File]::WriteAllText($dashboardPath, $newContent, $utf8NoBom)
            Ok "dashboard.py upgraded with admin sim/backtest/live routes."
        }
    }
}

# --- 2) Run sim ----------------------------------------------------------
if(-not $SkipSim){
    if(Test-Path $runSim){
        Info "Running fresh sim: run-sim.ps1 -Strategy both"
        try {
            & $runSim -Strategy both
            Ok "Sim run completed (run-sim.ps1)."
        } catch {
            Warn "Sim run failed: $($_.Exception.Message)"
        }
    } else {
        Warn "run-sim.ps1 not found at: $runSim"
    }
} else {
    Info "Skipping sim as requested (-SkipSim)."
}

# --- 3) Run backtest + summarize ----------------------------------------
if(-not $SkipBacktest){
    if(Test-Path $runBacktest){
        Info "Running backtest: run-sim-backtest.ps1 -LookbackDays 90 -StepDays 7 -Strategy both"
        try {
            & $runBacktest -LookbackDays 90 -StepDays 7 -Strategy both
            Ok "Backtest completed (run-sim-backtest.ps1)."
        } catch {
            Warn "Backtest failed: $($_.Exception.Message)"
        }
    } else {
        Warn "run-sim-backtest.ps1 not found at: $runBacktest"
    }

    if(Test-Path $summarizeBack){
        Info "Summarizing backtest: summarize-backtest.ps1"
        try {
            & $summarizeBack
            Ok "Backtest summary updated (summarize-backtest.ps1)."
        } catch {
            Warn "Backtest summary failed: $($_.Exception.Message)"
        }
    } else {
        Warn "summarize-backtest.ps1 not found at: $summarizeBack"
    }
} else {
    Info "Skipping backtest+summary as requested (-SkipBacktest)."
}

# --- 4) Normalize decisions ---------------------------------------------
if(-not $SkipNormalize){
    if(Test-Path $normalizeDec){
        Info "Normalizing decisions: normalize-decisions.ps1"
        try {
            & $normalizeDec
            Ok "Decisions normalized (normalize-decisions.ps1)."
        } catch {
            Warn "normalize-decisions.ps1 failed: $($_.Exception.Message)"
        }
    } else {
        Warn "normalize-decisions.ps1 not found at: $normalizeDec"
    }
} else {
    Info "Skipping normalize-decisions as requested (-SkipNormalize)."
}

Ok "Upgrade + refresh complete. Restart the dashboard with: pwsh .\tools\run-dashboard.ps1"
Write-Host "Then open http://127.0.0.1:8080 and use:"
Write-Host "  • /admin/sim-now"
Write-Host "  • /admin/sim-backtest-now"
Write-Host "  • /admin/live/on and /admin/live/off"
