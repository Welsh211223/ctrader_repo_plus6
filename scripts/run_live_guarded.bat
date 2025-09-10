@echo off
setlocal
set PROJ=C:\Users\User\Downloads\ctrader_repo_plus6
set PY=%PROJ%\.venv\Scripts\python.exe
set PYTHONPATH=%PROJ%\src
"%PY%" -m ctrader.cli.trade ^
  --pool conservative --mode both ^
  --coinspot-use-quote --coinspot-threshold 0.5 --coinspot-direction BOTH ^
  --min-order-value 10 --qty-precision "BTC:6,ETH:6,SOL:6,DOGE:0,SHIB:0" ^
  --turnover-cap-mode net --turnover-adaptive --turnover-priority sell_first ^
  --cooldown-minutes 15 --cooldown-bypass-drift-pct 4 ^
  --missing-price-pct-hard 50 ^
  --notify
endlocal
