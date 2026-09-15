@echo off
chcp 65001 >nul
REM ====================================================
REM Script de creation utilisateur + dossier + partage
REM ====================================================

REM --- Variables ---
set "UserName=Toshiba"
set "Password=__MOT_DE_PASSE__"
set "FolderPath=C:\Scan"
set "ShareName=Scan"
set "CommentPartage=Scan copieur TOSHIBA"
set "NbrMaxUtilisateurs=10"

echo ============================
echo  Creation de l'utilisateur
echo ============================

REM Creation de l'utilisateur local Toshiba (ignore si deja cree)
net user %UserName% >nul 2>&1
if %errorlevel%==0 goto motDePasse
net user %UserName% "%Password%" /add /comment:"%UserName%" /fullname:"%UserName%" /logonpasswordchg:no
if errorlevel 1 goto :echec
goto :comptePret

:motDePasse
REM Compte deja present : on applique le mot de passe saisi, sinon le
REM copieur configure avec celui-ci ne pourrait plus deposer ses scans.
REM
REM Le resultat est controle. Sans cela, un refus de la strategie de mots
REM de passe laisserait l'ancien mot de passe en place pendant que le
REM copieur serait configure avec le nouveau : le scan echouerait par la
REM suite en "erreur d'enregistrement fichier", sans que rien ici ne
REM l'ait annonce. Et pas de redirection vers nul : le message de net.exe
REM est precisement le diagnostic.
net user %UserName% "%Password%"
if errorlevel 1 goto :echecMotDePasse

:comptePret
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
exit /b 1

:echecMotDePasse
echo.
echo ERREUR : le mot de passe n'a pas pu etre applique au compte %UserName%.
echo Le compte conserve son ancien mot de passe, et le partage n'a pas ete
echo modifie. Le message de Windows ci-dessus en donne la raison ; la plus
echo frequente est une strategie de mots de passe non respectee (longueur
echo ou complexite).
echo Relancez le script avec un autre mot de passe.
pause
exit /b 1