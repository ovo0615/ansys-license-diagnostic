@echo off
REM AEDT Multi-PC Toolkit GUI - no custom EXE
setlocal
cd /d "%~dp0"
set "GUI=%~dp0MpiToolkit-GUI.ps1"
if not exist "%GUI%" (
    echo [ERROR] MpiToolkit-GUI.ps1 not found.
    pause
    exit /b 1
)
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%GUI%"
exit /b 0
