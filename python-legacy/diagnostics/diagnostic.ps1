# Proof-of-life diagnostic for ATC_Transcribe (Windows PowerShell)
# Usage: powershell -ExecutionPolicy Bypass -File diagnostics/diagnostic.ps1 [-- extra args]
#
# Resolves device "auto" to CUDA on an NVIDIA GPU, else CPU, then transcribes a
# few short bundled ATC snippets and prints a PASS/FAIL verdict.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    Write-Host "No .venv found - falling back to system python."
    Write-Host "Run scripts/install.ps1 first for an isolated environment."
    $python = "python"
}

& $python (Join-Path $Root "diagnostics\diagnostic.py") @args
exit $LASTEXITCODE
