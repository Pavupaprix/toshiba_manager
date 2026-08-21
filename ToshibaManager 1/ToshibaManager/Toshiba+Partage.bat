@echo off
chcp 65001 >nul
REM ====================================================
REM Script de creation utilisateur + dossier + partage
REM ====================================================

REM --- Variables ---
set "UserName=Toshiba"
set "Password=T0sh!b@"
set "FolderPath=C:\Scan"
set "ShareName=Scan"
set "CommentPartage=Scan copieur TOSHIBA"
set "NbrMaxUtilisateurs=10"

echo ============================
echo  Creation de l'utilisateur
echo ============================

REM Creation de l'utilisateur local Toshiba (ignore si deja cree)
net user %UserName% >nul 2>&1
if %errorlevel%==0 goto userExists
net user %UserName% %Password% /add /comment:"%UserName%" /fullname:"%UserName%" /logonpasswordchg:no
if errorlevel 1 goto :echec
:userExists
echo Utilisateur %UserName% pret.

REM Le mot de passe ne doit pas expirer
powershell -NoProfile -Command "Set-LocalUser -Name '%UserName%' -PasswordNeverExpires $true"

REM Ajout au groupe Administrateurs locaux (erreur si deja membre = ignoree)
net localgroup Administrateurs %UserName% /add 2>nul

echo ============================
echo  Creation du dossier partage
echo ============================

REM Creation du dossier s'il n'existe pas
if not exist "%FolderPath%" (
    mkdir "%FolderPath%"
    echo Dossier %FolderPath% cree.
) else (
    echo Dossier %FolderPath% deja existant.
)

echo ============================
echo  Attribution des droits SMB (partage)
echo ============================

REM Suppression du partage existant (nettoie les anciens droits et SID orphelins)
powershell -NoProfile -Command "Get-SmbShare -Name '%ShareName%' -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue"

REM Creation propre du partage avec controle total pour Toshiba et Tout le monde
powershell -NoProfile -Command "New-SmbShare -Name '%ShareName%' -Path '%FolderPath%' -Description '%CommentPartage%' -FullAccess '%UserName%','Tout le monde' | Out-Null"
if errorlevel 1 goto :echec

echo ============================
echo  Attribution des droits NTFS
echo ============================

REM Controle total NTFS pour Toshiba et Tout le monde
icacls "%FolderPath%" /grant "%UserName%":(OI)(CI)F /grant "Tout le monde":(OI)(CI)F /C /Q
if errorlevel 1 goto :echec

echo.
echo Configuration terminee avec succes !
echo Utilisateur : %UserName%
echo Dossier partage : %FolderPath%
echo Partage : \\%COMPUTERNAME%\%ShareName%
echo.
pause
goto :eof

:echec
echo.
echo ERREUR : la configuration a echoue.
echo Verifiez que le script est lance en Administrateur.
pause