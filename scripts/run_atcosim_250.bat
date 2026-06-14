@echo off
REM Test 250 entries on ATCoSIM database (GPU).
REM Run from project root:  run_atcosim_250.bat
REM Or from anywhere:        c:\Users\bsusl\ATC_Transcribe\run_atcosim_250.bat

cd /d "%~dp0.."

echo ============================================================
echo  ATCoSIM - 250 samples (Distil-Whisper on GPU)
echo ============================================================
python evaluate_atco2.py --data-dir data/atcosim --metadata metadata.json --max-samples 250 --device cuda --output results/evaluation/atcosim_250_whisper.json

echo.
echo ============================================================
echo  ATCoSIM - 250 samples (Voxtral on GPU)
echo ============================================================
python evaluate_voxtral_val.py --data-dir data/atcosim --metadata metadata.json --max-samples 250 --device cuda --output results/evaluation/atcosim_250_voxtral.json

echo.
echo Done. Check results/evaluation/atcosim_250_whisper.json and results/evaluation/atcosim_250_voxtral.json
pause
