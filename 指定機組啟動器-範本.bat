@echo off
REM ---------------------------------------------------------------
REM  Template launcher for a FIXED pair of workstations.
REM
REM  HOW TO USE
REM    1. Copy this file and give the copy any name you like.
REM    2. Replace HOSTA and HOSTB below with your two computer names.
REM    3. Put the copy on BOTH machines and double-click it on each.
REM
REM  The wizard detects which of the two machines it is running on
REM  and fills in the other one automatically - no typing needed.
REM  If it is run on a machine that is in neither slot it says so
REM  instead of guessing a peer.
REM
REM  Keep your edited copy out of version control: real machine
REM  names are internal asset information. See .gitignore.
REM ---------------------------------------------------------------
setlocal
cd /d "%~dp0"
set "PAIR=HOSTA,HOSTB"
set "WIZARD=%~dp0Start-OneClickCluster.ps1"
if not exist "%WIZARD%" (
    echo [ERROR] Start-OneClickCluster.ps1 not found.
    echo Please unzip the whole toolkit into one folder and try again.
    pause
    exit /b 1
)
echo %PAIR% | findstr /C:"HOSTA" >nul
if not errorlevel 1 (
    echo [ERROR] This is the template. Copy it and set PAIR to your two
    echo         computer names before running it.
    pause
    exit /b 1
)
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%WIZARD%" -PairHosts "%PAIR%"
exit /b 0
