@echo off
REM ===========================================================================
REM  Ansys License Troubleshooting Toolkit - Launcher
REM  Taiwan Auto-Design Co.   cae-support@cadmen.com
REM
REM  IMPORTANT: This file must stay ASCII-only, including these comments.
REM  Non-ASCII characters in a .bat under chcp 65001 get doubled or eaten
REM  by the console. All Chinese output is produced by the PowerShell script.
REM ===========================================================================

setlocal
chcp 65001 >nul 2>&1
title Ansys License Diagnostic - Taiwan Auto-Design Co.

cd /d "%~dp0"

set "PS1=%~dp0Check-AnsysLicense.ps1"

if not exist "%PS1%" (
    echo.
    echo  [ERROR] Check-AnsysLicense.ps1 not found.
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
