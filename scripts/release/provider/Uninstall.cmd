@echo off
rem Vyomanaut provider uninstaller - tells the network you are leaving, then removes everything.
setlocal
cd /d "%~dp0"
title Vyomanaut provider uninstall

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking for administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT=%~dp0uninstall.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%ProgramFiles%\Vyomanaut\uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
pause
