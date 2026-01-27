# Crypto Trader — CoinSpot + Paper
All-in-one scaffold: V2 live trading (guarded), paper simulator, robust signals (SMA, 12–1 momentum, inverse-vol), caching, backtests, Streamlit dashboard, scheduler, healthcheck, risk reports, Discord alerts.

## Quick start
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
export PYTHONPATH=src  # Windows: $env:PYTHONPATH="src"
python src/ctrader/cli/trade.py --pool conservative --paper --preview-guards
```

## Live trading (guarded)
Set in `.env`:
```
COINSPOT_API_KEY=...
COINSPOT_API_SECRET=...
COINSPOT_LIVE_DANGEROUS=true
```
Then run (with exchange-side guard):
```bash
python src/ctrader/cli/trade.py --pool conservative   --coinspot-use-quote --coinspot-threshold 0.5 --coinspot-direction BOTH --notify
```

## Dashboard
```
streamlit run src/ctrader/app.py
```


> CI bootstrap test: 2025-11-03T17:36:55.9011578+08:00

## ctrader live runner (CoinSpot) – Quick Usage

### 1. Secrets & config

This project expects sensitive values in the PowerShell SecretStore:

- LIVE_EXCHANGE = coinspot
- LIVE_BASE_CCY = AUD
- LIVE_API_KEY / LIVE_API_SECRET = your CoinSpot API credentials
- DISCORD_WEBHOOK_URL = your Discord webhook URL
- GITHUB_TOKEN = token with repo access (for CI/automation helpers)

Example (run once):

    Set-Secret -Name LIVE_EXCHANGE       -Secret 'coinspot'
    Set-Secret -Name LIVE_BASE_CCY       -Secret 'AUD'
    Set-Secret -Name LIVE_API_KEY        -Secret '<your_coinspot_key>'
    Set-Secret -Name LIVE_API_SECRET     -Secret '<your_coinspot_secret>'
    Set-Secret -Name DISCORD_WEBHOOK_URL -Secret '<your_discord_webhook>'
    Set-Secret -Name GITHUB_TOKEN        -Secret '<your_github_token>'

### 2. Running in SAFE / DRY_RUN mode

One-off run:

    pwsh .\tools\run-live.ps1

What it does:

- Loads secrets & environment.
- Calls `strategies.custom.generate_signal(cfg, client)`.
- Uses pools:
  - CORE  = conservative BTC accumulation.
  - AGGRO = small ETH / higher beta probes with tight caps.
- Enforces:
  - MAX_ORDER_NOTIONAL
  - DAILY_MAX_LOSS_PCT (via your strategy logic)
  - KILL_SWITCH
- Logs decisions to `logs/decisions.csv`.
- Sends Discord alerts if `DISCORD_WEBHOOK_URL` is configured.
- Does **not** send live orders while DRY_RUN is enabled.

Select pool per run:

    $env:CTRADER_POOL = "CORE"
    pwsh .\tools\run-live.ps1

    $env:CTRADER_POOL = "AGGRO"
    pwsh .\tools\run-live.ps1

### 3. Dashboard

Run:

    pwsh .\tools\run-dashboard.ps1

Then open:

    http://127.0.0.1:8080

The dashboard reads `logs/decisions.csv` and shows:

- Timestamp, pool, side, size, symbol, reason
- DRY_RUN vs LIVE
- Whether a live trade was executed

### 4. Discord alerts

With a valid `DISCORD_WEBHOOK_URL`:

- DRY_RUN: posts simulated actions like
  `🧪 [CORE] Would BUY ...`
- LIVE (once enabled): posts
  `✅ LIVE [...]` or `❌` on failures.

If you get 403 errors:
- Regenerate the webhook in Discord,
- Update it via `Set-Secret -Name DISCORD_WEBHOOK_URL -Secret '...'`.

### 5. Scheduling examples (Windows)

CORE every 30 minutes:

    schtasks /Create /TN "ctrader-core-dryrun-30min" ^
      /TR "pwsh -NoLogo -NonInteractive -ExecutionPolicy Bypass -Command `"$env:CTRADER_POOL='CORE'; & 'tools/run-live.ps1'`"" ^
      /SC MINUTE /MO 30 /F

AGGRO every 60 minutes:

    schtasks /Create /TN "ctrader-aggro-dryrun-60min" ^
      /TR "pwsh -NoLogo -NonInteractive -ExecutionPolicy Bypass -Command `"$env:CTRADER_POOL='AGGRO'; & 'tools/run-live.ps1'`"" ^
      /SC MINUTE /MO 60 /F

### 6. Going LIVE (optional, heavily guarded)

To enable real orders:

1. Confirm CoinSpot keys are correct and funded with an amount you can afford to lose.
2. In `run.py` → `execute_order(...)`, ensure your CoinSpot client is wired, for example:

       if side == "buy":
           resp = client.buy_market(base, amount=size)
       else:
           resp = client.sell_market(base, amount=size)

3. Flip to live:

       pwsh .\tools\run-live.ps1 -ReallyLive

Safeguards:

- `KILL_SWITCH=1` stops all trading.
- `MAX_ORDER_NOTIONAL` caps order size.
- `DAILY_MAX_LOSS_PCT` enforced in strategy logic.
- Interactive "yes" confirmation before any live trade.
- All decisions logged + Discord notifications for auditability.

You can iterate on `strategies/custom.py` (CORE/AGGRO logic) without changing this wiring.
