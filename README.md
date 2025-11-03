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
