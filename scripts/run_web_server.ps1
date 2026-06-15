# Launch the ATC_Transcribe browser console (Windows PowerShell).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/run_web_server.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/run_web_server.ps1 -Port 9000 -Device cuda

param(
    [string]$BindHost = "0.0.0.0",
    [int]$Port = 8000,
    [string]$Device = "auto",
    [switch]$Warm
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$activate = Join-Path $Root ".venv\Scripts\Activate.ps1"
if (Test-Path $activate) { & $activate }

# Ensure the web layer is installed.
python -c "import fastapi, uvicorn" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing web server dependencies (fastapi, uvicorn) ..."
    python -m pip install -r requirements-server.txt
}

$serverArgs = @("-m", "server.app", "--host", $BindHost, "--port", "$Port", "--device", $Device)
if ($Warm) { $serverArgs += "--warm" }

Write-Host "Starting ATC_Transcribe web UI on ${BindHost}:${Port} (device=$Device)"
Write-Host "Open the printed URL in a browser on this network."
python @serverArgs
