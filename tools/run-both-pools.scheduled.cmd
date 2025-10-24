@echo off
setlocal
set "_HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%_HERE%run-both-pools.scheduled.ps1" -Live
endlocal
