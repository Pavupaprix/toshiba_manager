@echo off
setlocal
cd /d "%~dp0"
title Installation d'un poste - OMB Informatique

rem Genere par ToshibaManager. Lanceur du script d'installation : une seule
rem elevation pour tout le traitement.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation des privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%~dp0Install-Poste.ps1" (
    echo.
    echo   ECHEC : Install-Poste.ps1 introuvable dans "%~dp0"
    echo   Decompressez l'integralite du ZIP avant de lancer ce fichier.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0config.json" (
    echo.
    echo   ECHEC : config.json introuvable dans "%~dp0"
    echo   Regenerez le ZIP depuis la page "Installer un poste".
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Poste.ps1"

exit /b %errorlevel%
