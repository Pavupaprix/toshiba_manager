@echo off
setlocal
title Capture des reglages TOSHIBA

rem Ouvre les preferences d'impression d'une file de reference et enregistre
rem le DEVMODE dans devmode\<NomDuPilote>.bin

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-ReglagesToshiba.ps1" %*
exit /b %errorlevel%
