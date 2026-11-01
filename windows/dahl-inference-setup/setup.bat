@echo off
rem Double-click me. Runs the setup script with the execution policy bypassed for this run only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dahl-ant2oai-setup.ps1" %*
echo.
pause
