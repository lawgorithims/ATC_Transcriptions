# Fresh install for ATC_Transcribe (Windows PowerShell)
# Usage: powershell -ExecutionPolicy Bypass -File scripts/install.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

Write-Host "========================================"
Write-Host " ATC_Transcribe - Fresh Install"
Write-Host "========================================"
Write-Host "Project root: $Root"
Write-Host ""

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Error "Python not found on PATH. Install Python 3.10+ from python.org"
}
Write-Host "[1/5] Python: $(python --version)"

$venv = Join-Path $Root ".venv"
if (-not (Test-Path $venv)) {
    Write-Host "[2/5] Creating virtual environment .venv ..."
    python -m venv $venv
} else {
    Write-Host "[2/5] Using existing .venv"
}
& "$venv\Scripts\Activate.ps1"

Write-Host "[3/5] Upgrading pip ..."
python -m pip install --upgrade pip wheel setuptools

Write-Host "[4/5] Installing Python dependencies ..."
python -m pip install -r requirements-live.txt

Write-Host "      Trying optional webrtcvad (may fail without C++ Build Tools) ..."
python -m pip install webrtcvad
if ($LASTEXITCODE -ne 0) {
    Write-Host "      webrtcvad skipped - live pipeline will use energy-based VAD fallback."
} else {
    Write-Host "      webrtcvad installed."
}

Write-Host "[5/5] Checking ffmpeg (required for live online feeds) ..."
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    Write-Host "      ffmpeg NOT found."
    Write-Host "      Install with:  winget install Gyan.FFmpeg"
    Write-Host "      Or:            winget install ffmpeg"
    Write-Host "      Offline testing works without ffmpeg via --simulate-file"
} else {
    Write-Host "      ffmpeg OK: $(ffmpeg -version 2>&1 | Select-Object -First 1)"
}

Write-Host ""
Write-Host "========================================"
Write-Host " Install complete"
Write-Host "========================================"
Write-Host ""
Write-Host "Activate the environment:"
Write-Host "  .\.venv\Scripts\Activate.ps1"
Write-Host ""
Write-Host "Start live KDFW Lone Star Approach feed:"
Write-Host "  python live_atc_pipeline.py"
Write-Host ""
Write-Host "Or:"
Write-Host "  python main.py live"
Write-Host ""
