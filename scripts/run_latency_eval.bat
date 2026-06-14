@echo off
REM Offline latency evaluation — replays recorded ATC at high speed
REM Produces a JSON latency report under results/live/kjfk/

cd /d "%~dp0.."

python live_atc_pipeline.py ^
    --simulate-file "data/live_atc/KJFK-Twr2-Mar-15-2026-0000Z.mp3" ^
    --fast-simulate ^
    --max-segments 20 ^
    --output-json "results/live/kdfw/latency_report.json"

pause
