@echo off
REM AEDT Multi-Workstation Cluster Checker - ASCII launcher
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"
set "PS1=%~dp0Test-AedtCluster.ps1"
if not exist "%PS1%" (
    echo [ERROR] Test-AedtCluster.ps1 not found.
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [ERROR] Cluster check failed. Exit code: %RC%
exit /b %RC%
