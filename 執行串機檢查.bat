@echo off
REM ===========================================================================
REM  AEDT Multi-Workstation Cluster Checker - Launcher
REM  Taiwan Auto-Design Co.   cae-support@cadmen.com
REM
REM  IMPORTANT: This file must stay ASCII-only, including these comments.
REM  Non-ASCII characters in a .bat under chcp 65001 get doubled or eaten
REM  by the console. All Chinese output is produced by the PowerShell script.
REM
REM  Usage:
REM    On each workstation:
REM      run this .bat as Administrator, e.g.
REM        (right-click) Run as administrator
REM      or from a prompt:
REM        (this .bat) -CaseId ACME-001 -Peers WS02,WS03
REM    Then collect every *.node.json into one folder and run:
REM        (this .bat) -Merge .\reports
REM ===========================================================================

setlocal
chcp 65001 >nul 2>&1
title AEDT Cluster Check - Taiwan Auto-Design Co.

cd /d "%~dp0"

set "PS1=%~dp0Test-AedtCluster.ps1"

if not exist "%PS1%" (
    echo.
    echo  [ERROR] Test-AedtCluster.ps1 not found.
    echo          Please keep this .bat and the .ps1 in the same folder.
    echo.
    pause
    exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [ERROR] Windows PowerShell not found on this machine.
    echo          Please contact cae-support@cadmen.com
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo  ---------------------------------------------------------------
    echo   The script did not complete normally. Exit code: %RC%
    echo.
    echo   If your security software blocked it, please run this command
    echo   manually in a PowerShell window instead:
    echo.
    echo     powershell -ExecutionPolicy Bypass -File "%PS1%"
    echo.
    echo   Still blocked? Please contact cae-support@cadmen.com
    echo  ---------------------------------------------------------------
)

echo.
pause
endlocal
