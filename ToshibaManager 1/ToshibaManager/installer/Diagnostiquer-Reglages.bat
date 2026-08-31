@echo off
setlocal
title Diagnostic des reglages TOSHIBA

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation des privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnostic-Reglages.ps1" %*
exit /b %errorlevel%
