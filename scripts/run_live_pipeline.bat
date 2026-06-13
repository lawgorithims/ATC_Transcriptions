@echo off
REM Live KDFW Lone Star Approach (17/35C Final) — real-time transcription + latency
REM Requires ffmpeg on PATH. Run scripts\install.bat first for a fresh setup.

cd /d "%~dp0.."

python live_atc_pipeline.py %*

pause
