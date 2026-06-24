@echo off
REM Check GPUs and NVIDIA driver status on Windows.
REM Run: check_gpu_driver.bat   or double-click the file.

echo ============================================================
echo  GPU and driver check (Dell XPS 17 9700)
echo ============================================================
echo.

echo --- All video controllers (WMI) ---
powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | ForEach-Object { Write-Host ('Name: ' + $_.Name); Write-Host ('  Adapter RAM: ' + [math]::Round($_.AdapterRAM/1GB, 2) + ' GB'); Write-Host ('  Driver: ' + $_.DriverVersion); Write-Host ('  Status: ' + $_.Status); Write-Host '' }"
echo.

echo --- NVIDIA driver (nvidia-smi) ---
where nvidia-smi >nul 2>&1
if %ERRORLEVEL% neq 0 (
  echo nvidia-smi NOT FOUND.
  echo This usually means the NVIDIA driver is not installed or not on PATH.
  echo Install/update from: https://www.nvidia.com/Download/index.aspx
  goto :done
)
nvidia-smi
if %ERRORLEVEL% neq 0 (
  echo nvidia-smi failed. Driver may be corrupted or GPU disabled.
)
:done
echo.
echo ============================================================
pause
