@echo off
REM AEDT one-click cluster wizard for a pair of workstations.
REM scan-ok: generic product description, no customer name here.
setlocal
cd /d "%~dp0"
set "WIZARD=%~dp0Start-OneClickCluster.ps1"
if not exist "%WIZARD%" (
    echo [ERROR] Start-OneClickCluster.ps1 not found.
    echo Please unzip the whole toolkit into one folder and try again.
    pause
    exit /b 1
)
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%WIZARD%"
exit /b 0
