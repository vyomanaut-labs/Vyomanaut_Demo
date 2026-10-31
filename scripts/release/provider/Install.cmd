@echo off
rem Vyomanaut provider installer - double-click, or right-click > Run as administrator.
setlocal
cd /d "%~dp0"
title Vyomanaut provider setup

if not exist "%~dp0install.ps1" goto notextracted
if not exist "%~dp0config.json" goto notextracted

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking for administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
exit /b

:notextracted
echo.
echo  This file was opened from inside the zip.
echo  Right-click the zip ^> Extract All..., open the extracted folder,
echo  then run Install.cmd from there.
echo.
pause
