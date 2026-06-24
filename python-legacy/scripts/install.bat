@echo off
REM Fresh install — creates .venv and installs all dependencies
cd /d "%~dp0.."
powershell -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
