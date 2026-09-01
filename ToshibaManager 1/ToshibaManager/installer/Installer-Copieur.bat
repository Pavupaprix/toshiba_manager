@echo off
setlocal
title Installation copieur TOSHIBA

rem Lanceur : eleve les privileges puis execute le script PowerShell en
rem contournant la strategie d'execution, sans la modifier durablement.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation des privileges...
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CopieurToshiba.ps1" %*
exit /b %errorlevel%
