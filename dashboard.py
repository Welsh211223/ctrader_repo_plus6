import csv
import datetime as dt
import os
from collections import defaultdict, namedtuple
from typing import DefaultDict

from flask import Flask, Response, redirect, render_template_string, url_for

app = Flask(__name__)

# --- helpers ---------------------------------------------------------------


def _read_csv(path):
    if not os.path.exists(path):
        return []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))
    except Exception:
        return []


def _caps():
    """
    Daily caps for paper + live.
    If you later introduce a real YAML config, wire it here.
    """
    Caps = namedtuple("Caps", ["paper", "live"])
    # Default: 50 AUD per mode
    return Caps(paper=50.0, live=50.0)


def _today_utc_date():
    return dt.datetime.utcnow().date()


def _today_net(mode: str) -> float:
    """
    Placeholder for a real budget ledger reader.

    Right now returns 0 so your 'Budget — Today' card is safe.
    Wire it to your real trade ledger later if desired.
    """
    # TODO: integrate with real trade ledger if/when present
    return 0.0


def _sim_report():
    """
    Read the latest single-window sim report.
    """
    rows = _read_csv(os.path.join("logs", "sim_report.csv"))
    return rows


def _live_enabled() -> bool:
    """
    Live trading flag, backed by config/live.flag.
    Any non-empty '1/true/yes/on' => True.
    """
    flag_path = os.path.join("config", "live.flag")
    try:
        with open(flag_path, encoding="utf-8") as f:
            raw = f.read().strip().lower()
        return raw in ("1", "true", "yes", "on")
    except FileNotFoundError:
        return False
    except Exception:
        return False


def _decisions():
    """
    Read logs/decisions.csv, best-effort.
    """
    rows = _read_csv(os.path.join("logs", "decisions.csv"))
    # ensure keys exist so Jinja doesn't explode
    safe_rows = []
    for r in rows:
        safe_rows.append(
            {
                "timestamp": r.get("timestamp", ""),
                "pool": r.get("pool", ""),
                "symbol": r.get("symbol", ""),
                "side": r.get("side", ""),
                "size": r.get("size", ""),
                "reason": r.get("reason", ""),
                "dry_run": r.get("dry_run", r.get("DRY", "")),
                "live_executed": r.get("live_executed", r.get("LIVE", "")),
            }
        )
    return safe_rows


def _sim_today_rows():
    """
    Read logs/sim_loop_log.csv and filter rows for *today* (UTC).
    Returns list of dicts with typed numbers where useful.
    """
    path = os.path.join("logs", "sim_loop_log.csv")
    rows = _read_csv(path)
    if not rows:
        return []

    today = _today_utc_date()
    today_rows = []
    for r in rows:
        ts_raw = r.get("ts_run") or r.get("ts") or ""
        try:
            # expect ISO like 2025-11-13T06:57:57Z
            ts = dt.datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
            if ts.date() != today:
                continue
        except Exception:
            # if ts can't be parsed, skip
            continue

        try:
            pnl_aud = float(r.get("pnl_aud", "0") or 0)
        except Exception:
            pnl_aud = 0.0
        try:
            invested = float(r.get("invested_aud", "0") or 0)
        except Exception:
            invested = 0.0
        try:
            mv = float(r.get("market_value_aud", "0") or 0)
        except Exception:
            mv = 0.0

        today_rows.append(
            {
                "ts_run": ts_raw,
                "symbol": r.get("symbol", ""),
                "invested_aud": invested,
                "market_value_aud": mv,
                "pnl_aud": pnl_aud,
            }
        )
    return today_rows


def _sim_today_pnl():
    """
    Aggregate today's sim_loop_log by symbol.
    Returns (rows, total_pnl_aud).
    """
    rows = _sim_today_rows()
    if not rows:
        return [], 0.0

    agg = defaultdict(lambda: {"invested": 0.0, "market": 0.0, "pnl": 0.0})
    for r in rows:
        sym = r["symbol"]
        agg[sym]["invested"] += r["invested_aud"]
        agg[sym]["market"] += r["market_value_aud"]
        agg[sym]["pnl"] += r["pnl_aud"]

    out = []
    total = 0.0
    for sym, v in agg.items():
        total += v["pnl"]
        out.append(
            {
                "symbol": sym,
                "invested_aud": round(v["invested"], 2),
                "market_value_aud": round(v["market"], 2),
                "pnl_aud": round(v["pnl"], 2),
            }
        )

    # stable ordering
    out.sort(key=lambda r: r["symbol"])
    return out, round(total, 2)


def _pool_from_symbol(symbol: str) -> str:
    """
    Extract a 'pool' / strategy label from a symbol like:
      'BTC/AUD (CORE DCA)' -> 'CORE DCA'
      'ETH/AUD (AGGRO momentum)' -> 'AGGRO momentum'
    """
    if "(" in symbol and ")" in symbol:
        try:
            inner = symbol.split("(", 1)[1].split(")", 1)[0]
            return inner.strip()
        except Exception:
            return ""
    return ""


def _pnl_by_pool(today_symbol_rows):
    """
    Aggregate today's PnL by pool/strategy (using () suffix).
    Returns list of dicts with keys: pool, pnl_aud.
    """
    if not today_symbol_rows:
        return []

    agg: DefaultDict[str, float] = defaultdict(float)
    for r in today_symbol_rows:
        pool = _pool_from_symbol(r["symbol"])
        if not pool:
            pool = "unlabelled"
        agg[pool] += r["pnl_aud"]

    out = []
    for pool, pnl in agg.items():
        out.append(
            {
                "pool": pool,
                "pnl_aud": round(pnl, 2),
            }
        )
    out.sort(key=lambda x: x["pool"])
    return out


def _rolling_pnl(max_rows: int = 20):
    """
    Recent sim_loop_log windows: ts_run + total pnl per run.
    It's a lightweight 'PnL over time' view.
    """
    path = os.path.join("logs", "sim_loop_log.csv")
    rows = _read_csv(path)
    if not rows:
        return []

    # aggregate by ts_run in case multiple rows share the same run timestamp
    agg: DefaultDict[str, float] = defaultdict(float)
    for r in rows:
        ts = r.get("ts_run") or r.get("ts") or ""
        try:
            pnl = float(r.get("pnl_aud", "0") or 0)
        except Exception:
            pnl = 0.0
        agg[ts] += pnl

    # sort by timestamp
    items = []
    for ts, pnl in agg.items():
        items.append((ts, pnl))
    try:
        items.sort(key=lambda t: dt.datetime.fromisoformat(t[0].replace("Z", "+00:00")))
    except Exception:
        items.sort(key=lambda t: t[0])

    # take last max_rows
    items = items[-max_rows:]
    out = []
    for ts, pnl in items:
        out.append(
            {
                "ts_run": ts,
                "pnl_aud": round(pnl, 2),
            }
        )
    return out


def _backtest_summary():
    """
    Read logs/sim_backtest_summary.csv if present.
    """
    path = os.path.join("logs", "sim_backtest_summary.csv")
    rows = _read_csv(path)
    safe_rows = []
    for r in rows:
        safe_rows.append(
            {
                "symbol": r.get("symbol", ""),
                "windows": r.get("windows", ""),
                "mean_pnl%": r.get("mean_pnl%", ""),
                "median_pnl%": r.get("median_pnl%", ""),
                "worst_pnl%": r.get("worst_pnl%", ""),
                "best_pnl%": r.get("best_pnl%", ""),
                "stdev_pnl%": r.get("stdev_pnl%", ""),
                "avg_invested_aud": r.get("avg_invested_aud", ""),
            }
        )
    return safe_rows


# --- templates -------------------------------------------------------------

BASE = """<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>ctrader dashboard</title>
    <style>
      body{
        font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;
        margin:24px;
        background:#f3f4f6;
      }
      .wrap{max-width:1024px;margin:0 auto;}
      .topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;}
      h1{margin:0;font-size:24px;}
      .pill{
        display:inline-flex;
        align-items:center;
        border-radius:999px;
        padding:4px 10px;
        font-size:12px;
        font-weight:500;
        gap:6px;
      }
      .pill-off{
        background:#fef2f2;
        color:#b91c1c;
      }
      .pill-on{
        background:#ecfdf3;
        color:#166534;
      }
      .pill-dot{
        width:8px;height:8px;border-radius:999px;
      }
      .pill-off .pill-dot{background:#ef4444;}
      .pill-on .pill-dot{background:#22c55e;}
      .card{
        border:1px solid #e5e7eb;
        border-radius:12px;
        padding:16px;
        background:#ffffff;
        margin-bottom:16px;
      }
      .card h2{margin:0 0 8px 0;font-size:18px;}
      .card h3{margin:0 0 8px 0;font-size:15px;}
      .mono{font-family:ui-monospace,Menlo,Consolas,monospace;}
      .muted{color:#6b7280;font-size:12px;}
      .buttons{
        display:flex;
        flex-wrap:wrap;
        gap:8px;
        margin-top:8px;
        margin-bottom:16px;
      }
      .btn{
        display:inline-block;
        padding:6px 10px;
        border-radius:999px;
        text-decoration:none;
        font-size:13px;
        border:1px solid #d1d5db;
        background:#f9fafb;
        color:#111827;
      }
      .btn:hover{background:#e5e7eb;}
      .btn-danger{
        border-color:#fca5a5;
        background:#fef2f2;
        color:#b91c1c;
      }
      table{
        width:100%;
        border-collapse:collapse;
        font-size:13px;
      }
      th,td{
        padding:4px 6px;
        border-bottom:1px solid #e5e7eb;
      }
      th{
        text-align:left;
        font-weight:600;
        background:#f9fafb;
      }
      tr:last-child td{border-bottom:none;}
      .layout{
        display:grid;
        grid-template-columns:2fr 1.4fr;
        gap:16px;
      }
      @media (max-width:900px){
        .layout{grid-template-columns:1fr;}
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="topbar">
        <h1>ctrader dashboard</h1>
        <div>
          {% if live_enabled %}
            <span class="pill pill-on">
              <span class="pill-dot"></span>
              LIVE trading: ON
              <a href="/admin/live/off" style="margin-left:8px;font-size:11px;">(disable)</a>
            </span>
          {% else %}
            <span class="pill pill-off">
              <span class="pill-dot"></span>
              Live trading: OFF (sim / DRY)
              <a href="/admin/live/on" style="margin-left:8px;font-size:11px;">(enable)</a>
            </span>
          {% endif %}
        </div>
      </div>

      <div class="buttons">
        <a class="btn" href="/admin/sim-now">Run sim now</a>
        <a class="btn" href="/admin/sim-backtest-now">Run backtest + summary</a>
        <a class="btn" href="/admin/fix-decisions">Fix decisions</a>
        <a class="btn btn-danger" href="/budget">View budget</a>
      </div>

      <div class="layout">
        <div>
          <div class="card">
            <h2>Budget — Today (UTC)</h2>
            <table>
              <tr>
                <th>Mode</th>
                <th class="mono" style="text-align:right;">Net spend (AUD)</th>
                <th class="mono" style="text-align:right;">Daily cap (AUD)</th>
                <th style="text-align:right;">Status</th>
              </tr>
              <tr>
                <td>Paper (DRY_RUN)</td>
                <td class="mono" style="text-align:right;">{{ "%.2f"|format(paper) }}</td>
                <td class="mono" style="text-align:right;">{{ "%.2f"|format(caps.paper) }}</td>
                <td style="text-align:right;">OK</td>
              </tr>
              <tr>
                <td>Live</td>
                <td class="mono" style="text-align:right;">{{ "%.2f"|format(live) }}</td>
                <td class="mono" style="text-align:right;">{{ "%.2f"|format(caps.live) }}</td>
                <td style="text-align:right;">OK</td>
              </tr>
            </table>
            <p class="muted" style="margin-top:8px;">
              Budget card is wired for future ledger integration; currently shows 0 until real trades feed it.
              <a href="/budget">Open budget page →</a>
            </p>
          </div>

          <div class="card">
            <h2>Sim PnL — Today (UTC)</h2>
            {% if pnl_rows %}
              <table>
                <tr>
                  <th>Symbol</th>
                  <th class="mono" style="text-align:right;">Invested</th>
                  <th class="mono" style="text-align:right;">Market</th>
                  <th class="mono" style="text-align:right;">PnL (AUD)</th>
                </tr>
                {% for r in pnl_rows %}
                  <tr>
                    <td class="mono">{{ r.symbol }}</td>
                    <td class="mono" style="text-align:right;">{{ "%.2f"|format(r.invested_aud) }}</td>
                    <td class="mono" style="text-align:right;">{{ "%.2f"|format(r.market_value_aud) }}</td>
                    <td class="mono" style="text-align:right;">{{ "%.2f"|format(r.pnl_aud) }}</td>
                  </tr>
                {% endfor %}
              </table>
              <p style="margin-top:8px;">
                <strong>Total PnL today: {{ "%.2f"|format(pnl_total) }} AUD</strong>
              </p>
            {% else %}
              <p class="muted">
                No sim_loop_log entries for today yet. Run a sim or wait for the scheduler.
              </p>
            {% endif %}
          </div>

          <div class="card">
            <h3>PnL by pool — Today (UTC)</h3>
            {% if pnl_pools %}
              <table>
                <tr>
                  <th>Pool / strategy</th>
                  <th class="mono" style="text-align:right;">PnL (AUD)</th>
                </tr>
                {% for r in pnl_pools %}
                  <tr>
                    <td class="mono">{{ r.pool }}</td>
                    <td class="mono" style="text-align:right;">{{ "%.2f"|format(r.pnl_aud) }}</td>
                  </tr>
                {% endfor %}
              </table>
              <p class="muted" style="margin-top:6px;">
                Pool is parsed from the symbol suffix, e.g. <span class="mono">BTC/AUD (CORE DCA)</span> → <span class="mono">CORE DCA</span>.
              </p>
            {% else %}
              <p class="muted">
                No pool-labelled rows yet (symbols like <span class="mono">BTC/AUD (CORE DCA)</span>).
              </p>
            {% endif %}
          </div>

        </div>

        <div>
          <div class="card">
            <h2>Sim report</h2>
            {% if sim %}
              <table>
                <tr>
                  <th>Symbol</th>
                  <th class="mono" style="text-align:right;">Invested</th>
                  <th class="mono" style="text-align:right;">Market</th>
                  <th class="mono" style="text-align:right;">PnL (AUD)</th>
                  <th class="mono" style="text-align:right;">PnL %</th>
                </tr>
                {% for r in sim %}
                  <tr>
                    <td class="mono">{{ r.symbol }}</td>
                    <td class="mono" style="text-align:right;">{{ r.invested_aud }}</td>
                    <td class="mono" style="text-align:right;">{{ r.market_value_aud }}</td>
                    <td class="mono" style="text-align:right;">{{ r.pnl_aud }}</td>
                    <td class="mono" style="text-align:right;">{{ r.pnl_pct }}</td>
                  </tr>
                {% endfor %}
              </table>
            {% else %}
              <p class="muted">Run <span class="mono">pwsh .\tools\run-sim.ps1 -Strategy both</span> to populate sim_report.csv.</p>
            {% endif %}
          </div>

          <div class="card">
            <h3>Backtest Summary</h3>
            {% if backtests %}
              <table>
                <tr>
                  <th>Symbol</th>
                  <th class="mono">Windows</th>
                  <th class="mono">Mean %</th>
                  <th class="mono">Median %</th>
                  <th class="mono">Worst %</th>
                  <th class="mono">Best %</th>
                  <th class="mono">σ PnL%</th>
                  <th class="mono">Avg Invested</th>
                </tr>
                {% for r in backtests %}
                  <tr>
                    <td class="mono">{{ r.symbol }}</td>
                    <td class="mono">{{ r.windows }}</td>
                    <td class="mono">{{ r["mean_pnl%"] }}</td>
                    <td class="mono">{{ r["median_pnl%"] }}</td>
                    <td class="mono">{{ r["worst_pnl%"] }}</td>
                    <td class="mono">{{ r["best_pnl%"] }}</td>
                    <td class="mono">{{ r["stdev_pnl%"] }}</td>
                    <td class="mono">{{ r.avg_invested_aud }}</td>
                  </tr>
                {% endfor %}
              </table>
            {% else %}
              <p class="muted">
                Run backtests to see summary
                (<span class="mono">pwsh .\tools\run-sim-backtest.ps1 ...; pwsh .\tools\summarize-backtest.ps1</span>).
              </p>
            {% endif %}
          </div>

          <div class="card">
            <h3>Recent sim runs (PnL per run)</h3>
            {% if rolling_pnl %}
              <table>
                <tr>
                  <th>Run time (ts_run)</th>
                  <th class="mono" style="text-align:right;">Total PnL (AUD)</th>
                </tr>
                {% for r in rolling_pnl %}
                  <tr>
                    <td class="mono">{{ r.ts_run }}</td>
                    <td class="mono" style="text-align:right;">{{ "%.2f"|format(r.pnl_aud) }}</td>
                  </tr>
                {% endfor %}
              </table>
            {% else %}
              <p class="muted">No sim_loop_log entries yet.</p>
            {% endif %}
          </div>
        </div>
      </div>

      <div class="card" style="margin-top:16px;">
        <h3>Recent decisions</h3>
        {% if rows %}
          <table>
            <tr>
              <th>Time (UTC)</th>
              <th>Pool</th>
              <th>Symbol</th>
              <th>Side</th>
              <th>Size</th>
              <th>Reason</th>
              <th>DRY</th>
              <th>LIVE</th>
            </tr>
            {% for r in rows %}
              <tr>
                <td class="mono">{{ r.timestamp }}</td>
                <td class="mono">{{ r.pool }}</td>
                <td class="mono">{{ r.symbol }}</td>
                <td class="mono">{{ r.side }}</td>
                <td class="mono">{{ r.size }}</td>
                <td class="mono">{{ r.reason }}</td>
                <td class="mono">{{ r.dry_run }}</td>
                <td class="mono">{{ r.live_executed }}</td>
              </tr>
            {% endfor %}
          </table>
        {% else %}
          <p class="muted">No decisions yet.</p>
        {% endif %}
      </div>
    </div>
  </body>
</html>"""

BUDGET = """<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>budget</title>
    <style>
      body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:24px;background:#f3f4f6;}
      .wrap{max-width:720px;margin:0 auto;}
      .card{border:1px solid #e5e7eb;border-radius:12px;padding:16px;background:#ffffff;}
      .mono{font-family:ui-monospace,Menlo,Consolas,monospace;}
      table{width:100%;border-collapse:collapse;font-size:13px;}
      th,td{padding:4px 6px;border-bottom:1px solid #e5e7eb;}
      th{text-align:left;font-weight:600;background:#f9fafb;}
      tr:last-child td{border-bottom:none;}
    </style>
  </head>
  <body>
    <div class="wrap">
      <h1 style="margin:0 0 16px 0">Budget — Today (UTC)</h1>
      <div class="card">
        <table>
          <tr>
            <th align="left">Mode</th>
            <th align="right">Net spend (AUD)</th>
            <th align="right">Daily cap (AUD)</th>
          </tr>
          <tr>
            <td>Paper (DRY_RUN)</td>
            <td class="mono" align="right">{{ "%.2f"|format(paper) }}</td>
            <td class="mono" align="right">{{ "%.2f"|format(caps.paper) }}</td>
          </tr>
          <tr>
            <td>Live</td>
            <td class="mono" align="right">{{ "%.2f"|format(live) }}</td>
            <td class="mono" align="right">{{ "%.2f"|format(caps.live) }}</td>
          </tr>
        </table>
        <p style="margin-top:12px">
          <a href="/">← Back</a>
        </p>
      </div>
    </div>
  </body>
</html>"""

# --- routes -------------------------------------------------------------


@app.route("/")
def home():
    rows = _decisions()[-100:]
    caps = _caps()
    paper = _today_net("paper")
    live = _today_net("live")
    sim = _sim_report()
    backtests = _backtest_summary()
    pnl_rows, pnl_total = _sim_today_pnl()
    pnl_pools = _pnl_by_pool(pnl_rows)
    rolling = _rolling_pnl()
    live_flag = _live_enabled()

    return render_template_string(
        BASE,
        rows=rows,
        caps=caps,
        paper=paper,
        live=live,
        sim=sim,
        backtests=backtests,
        pnl_rows=pnl_rows,
        pnl_total=pnl_total,
        pnl_pools=pnl_pools,
        rolling_pnl=rolling,
        live_enabled=live_flag,
    )


@app.route("/budget")
def budget():
    caps = _caps()
    paper = _today_net("paper")
    live = _today_net("live")
    return render_template_string(BUDGET, caps=caps, paper=paper, live=live)


# --- admin endpoints ----------------------------------------------------


@app.route("/admin/fix-decisions")
def admin_fix():
    """
    Backfill timestamps then normalize decisions.csv via PowerShell helpers.
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
                os.path.join("tools", "fill-missing-timestamps.ps1"),
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
                os.path.join("tools", "normalize-decisions.ps1"),
            ],
            check=True,
        )
        msg = "Decisions backfilled + normalized."
    except Exception as e:
        msg = f"Admin fix failed: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back to dashboard</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


@app.route("/admin/backtest")
def admin_bkt():
    """
    Trigger sliding-window backtest + summary (uses your tools/*.ps1).
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


@app.route("/admin/routes")
def admin_routes():
    """
    Debug endpoint: list all Flask routes this app knows about.
    """
    lines = []
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        methods = ",".join(
            sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS"))
        )
        lines.append(f"{rule.rule}  [{methods}] -> {rule.endpoint}")
    body = "<pre>" + "\\n".join(lines) + "</pre>"
    return body


@app.route("/admin/sim-run")
def admin_sim_run():
    """
    Backwards-compat endpoint: redirect to /admin/sim-now.
    """
    return redirect(url_for("admin_sim_now"))


@app.route("/admin/sim-now")
def admin_sim_now():
    """
    Kick a fresh sim run so sim_report.csv + sim_loop_log.csv update.
    """
    import os
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
        msg = "Sim completed."
    except Exception as e:
        msg = f"Sim failed: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


@app.route("/admin/routes-debug")
def admin_routes_debug():
    """Debug endpoint: list all Flask routes this app knows about."""
    lines = []
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        methods = ",".join(
            sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS"))
        )
        lines.append(f"{rule.rule}  [{methods}] -> {rule.endpoint}")
    body = "<pre>" + "\n".join(lines) + "</pre>"
    return body


@app.route("/admin/health")
def admin_health():
    """Simple health check for key cTrader dashboard components."""
    import os

    root = os.path.dirname(os.path.abspath(__file__))
    logs_dir = os.path.join(root, "logs")
    tools_dir = os.path.join(root, "tools")

    checks = []

    def add_check(name, ok, detail=""):
        status = "OK" if ok else "MISSING"
        row = f"<tr><td>{name}</td><td>{status}</td><td>{detail}</td></tr>"
        checks.append(row)

    def exists(p):
        return os.path.exists(p)

    # Logs dir and key CSV files
    add_check("logs dir", exists(logs_dir), logs_dir)

    sim_report = os.path.join(logs_dir, "sim_report.csv")
    sim_loop = os.path.join(logs_dir, "sim_loop_log.csv")
    bt_csv = os.path.join(logs_dir, "sim_backtest.csv")
    decisions = os.path.join(logs_dir, "decisions.csv")

    add_check("sim_report.csv", exists(sim_report), sim_report)
    add_check("sim_loop_log.csv", exists(sim_loop), sim_loop)
    add_check("sim_backtest.csv", exists(bt_csv), bt_csv)
    add_check("decisions.csv", exists(decisions), decisions)

    # Tools scripts
    run_sim = os.path.join(tools_dir, "run-sim.ps1")
    run_backtest = os.path.join(tools_dir, "run-sim-backtest.ps1")
    summarize_back = os.path.join(tools_dir, "summarize-backtest.ps1")

    add_check("run-sim.ps1", exists(run_sim), run_sim)
    add_check("run-sim-backtest.ps1", exists(run_backtest), run_backtest)
    add_check("summarize-backtest.ps1", exists(summarize_back), summarize_back)

    rows = "\n".join(checks)
    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <h1>cTrader dashboard health</h1>
      <table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse'>
        <tr><th>Item</th><th>Status</th><th>Details</th></tr>
        {rows}
      </table>
      <p><a href='/'>← Back to dashboard</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


@app.route("/admin/sim-backtest-now")
def admin_sim_backtest_now():
    """
    Run the sim backtest + summary generation, then show a simple status page.
    """
    import os
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
        msg = "Backtest + summary completed."
    except Exception as e:
        msg = f"Backtest run failed: {e}"

    html = f"""<!doctype html><meta charset='utf-8'>
    <body style='font-family:system-ui'>
      <p>{msg}</p>
      <p><a href='/'>← Back to dashboard</a></p>
      <p><a href='/admin/backtest'>View backtest summary</a></p>
    </body>"""
    return Response(html, mimetype="text/html")


if __name__ == "__main__":
    print("Starting cTrader dashboard on http://127.0.0.1:8080")
    app.run(host="127.0.0.1", port=8080)
