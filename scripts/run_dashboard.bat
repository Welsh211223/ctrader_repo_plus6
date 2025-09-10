@echo off
setlocal
set "PROJ=C:\Users\User\Downloads\ctrader_repo_plus6"
set "PY=%PROJ%\.venv\Scripts\python.exe"
"%PY%" -m streamlit run "%PROJ%\src\ctrader\app.py"
endlocal
