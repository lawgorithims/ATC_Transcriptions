@echo off
REM Test 250 entries on ATCoSIM database (GPU).
REM Run from project root:  run_atcosim_250.bat
REM Or from anywhere:        c:\Users\bsusl\ATC_Transcribe\run_atcosim_250.bat

cd /d "%~dp0.."

echo ============================================================
echo  ATCoSIM - 250 samples (Distil-Whisper on GPU)
echo ============================================================
python evaluate_atco2.py --data-dir data/atcosim --metadata metadata.json --max-samples 250 --device cuda --output results/evaluation/atcosim_250_whisper.json

REM ------------------------------------------------------------
REM Voxtral comparison DISABLED: evaluate_voxtral_val.py does not
REM exist in this repo. Re-enable this block once that script is added.
REM ------------------------------------------------------------
REM echo.
REM echo ============================================================
REM echo  ATCoSIM - 250 samples (Voxtral on GPU)
REM echo ============================================================
REM python evaluate_voxtral_val.py --data-dir data/atcosim --metadata metadata.json --max-samples 250 --device cuda --output results/evaluation/atcosim_250_voxtral.json

echo.
echo Done. Check results/evaluation/atcosim_250_whisper.json
pause
