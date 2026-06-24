@echo off
REM Full 30-minute ATC transcription with real-time saving
REM Run from project root or double-click (script cd's to repo root)

cd /d "%~dp0.."

python live_atc_transcribe.py ^
    --input "data/live_atc/KJFK-Twr2-Mar-15-2026-0000Z.mp3" ^
    --output "results/live/kjfk/finetuned_full.txt" ^
    --format txt ^
    --live-print ^
    --realtime-save ^
    --no-diarization

pause


