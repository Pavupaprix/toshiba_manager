<#
.SYNOPSIS
    Reglages Windows, desinstallation ciblee et renommage du poste.

.DESCRIPTION
    Les reglages d'explorateur vivent dans HKCU : appliques au seul technicien,
    ils ne serviraient a personne. Ils sont donc ecrits deux fois -- pour la
    session en cours, et dans C:\Users\Default\NTUSER.DAT pour que tout compte
    cree ensuite en herite des sa premiere ouverture de session.
#>

$script:RUCHE_DEFAUT = 'OMBDefaut'

# Filet de securite : un antivirus ne doit jamais etre desinstalle par ce
# script, quel que soit le motif demande.
$script:ProtegesAv = @('SentinelOne', 'Sentinel Agent', 'Windows Defender',
                       'Microsoft Defender', 'CrowdStrike', 'ESET', 'Bitdefender')

$script:ClesDesinstallation = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Set-ValeurRegistre {
    param(
        [string]$Chemin,
        [string]$Nom,
        $Valeur,
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path $Chemin)) {
        New-Item -Path $Chemin -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $Chemin -Name $Nom -Value $Valeur -Type $Type -ErrorAction SilentlyContinue
}

function Invoke-SurRuchesUtilisateur {
    <#
        Applique le meme bloc a la session courante et a la ruche par defaut.
        Le bloc recoit la racine a utiliser ("HKCU:" ou le chemin de la ruche
        montee) et compose ses chemins a partir de la.
    #>
    param([scriptblock]$Bloc)

    # Le bloc ne doit rien renvoyer : sa sortie remonterait dans le pipeline de
    # la fonction appelante et corromprait sa valeur de retour.
    & $Bloc 'HKCU:' | Out-Null

    $ntuser = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path $ntuser)) {
        Ecrire '  Ruche par defaut introuvable : les futurs comptes ne l''heriteront pas.' 'Yellow'
        return
    }

    $monte = $false
    try {
        & reg.exe load "HKU\$script:RUCHE_DEFAUT" $ntuser 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg load a echoue (code $LASTEXITCODE)." }
        $monte = $true
        & $Bloc "Registry::HKEY_USERS\$script:RUCHE_DEFAUT" | Out-Null
    } catch {
        Ecrire ('  Ruche par defaut non modifiee : {0}' -f $_.Exception.Message) 'Yellow'
    } finally {
        if ($monte) {
            # Sans ce ramassage, PowerShell garde des handles ouverts sur la
            # ruche et reg unload echoue silencieusement.
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$script:RUCHE_DEFAUT" 2>&1 | Out-Null
        }
    }
}

function Set-ReglagesWindows {
    param([psobject]$Windows)

    $resultats = @{}

    # --- UAC ----------------------------------------------------------------
    if ($Windows.uac -ne 'inchange') {
        $cle = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if ($Windows.uac -eq 'desactive') {
            Set-ValeurRegistre $cle 'EnableLUA' 0
            Set-ValeurRegistre $cle 'ConsentPromptBehaviorAdmin' 0
            Ecrire '  UAC desactive completement (redemarrage requis).' 'Yellow'
            Ecrire '  Rappel : les applications du Store ne s''ouvriront plus.' 'Yellow'
            $resultats['uac'] = 'Desactive (redemarrage requis)'
        } else {
            Set-ValeurRegistre $cle 'ConsentPromptBehaviorAdmin' 0
            Ecrire '  UAC : plus de demande de confirmation pour les administrateurs.' 'Green'
            $resultats['uac'] = 'Sans confirmation'
        }
    }

    # --- Explorateur --------------------------------------------------------
    if ($Windows.extensionsVisibles) {
        Invoke-SurRuchesUtilisateur {
            param($racine)
            $avance = "$racine\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-ValeurRegistre $avance 'HideFileExt' 0
            Set-ValeurRegistre $avance 'Hidden' 1
        } | Out-Null
        Ecrire '  Extensions et fichiers caches visibles.' 'Green'
        $resultats['extensions'] = 'Applique'
    }

    if ($Windows.paveNumerique) {
        Invoke-SurRuchesUtilisateur {
            param($racine)
            Set-ValeurRegistre "$racine\Control Panel\Keyboard" 'InitialKeyboardIndicators' '2' 'String'
        } | Out-Null
        # .DEFAULT porte l'ecran de connexion, avant toute session utilisateur.
        Set-ValeurRegistre 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' `
                           'InitialKeyboardIndicators' '2' 'String'
        Ecrire '  Pave numerique actif au demarrage.' 'Green'
        $resultats['paveNumerique'] = 'Applique'
    }

    if ($Windows.supprimerPubs) {
        Invoke-SurRuchesUtilisateur {
            param($racine)
            $cdm = "$racine\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            foreach ($nom in 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                             'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                             'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled',
                             'SystemPaneSuggestionsEnabled', 'SilentInstalledAppsEnabled',
                             'SoftLandingEnabled', 'RotatingLockScreenOverlayEnabled') {
                Set-ValeurRegistre $cdm $nom 0
            }
            Set-ValeurRegistre "$racine\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
                               'ShowSyncProviderNotifications' 0
        } | Out-Null
        Ecrire '  Suggestions et publicites Windows desactivees.' 'Green'
        $resultats['pubs'] = 'Applique'
    }

    if ($Windows.desactiverDemarrageRapide) {
        Set-ValeurRegistre 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                           'HiberbootEnabled' 0
        Ecrire '  Demarrage rapide desactive.' 'Green'
        $resultats['demarrageRapide'] = 'Applique'
    }

    return $resultats
}

function Remove-Logiciel {
    param([string]$Motif)

    $installes = Get-ItemProperty $script:ClesDesinstallation -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName }
    $cibles = $installes | Where-Object { $_.DisplayName -match [regex]::Escape($Motif) }

    if (-not $cibles) {
        Ecrire ('  {0} : absent du poste.' -f $Motif) 'Green'
        return 'Absent'
    }

    $statut = 'Non traite'
    foreach ($item in $cibles) {
        $protege = $false
        foreach ($p in $script:ProtegesAv) {
            if ($item.DisplayName -match [regex]::Escape($p)) { $protege = $true }
        }
        if ($protege) {
            Ecrire ('  Protege, ignore : {0}' -f $item.DisplayName) 'Yellow'
            continue
        }

        $nomAffiche = $item.DisplayName
        Ecrire ('  Desinstallation : {0}' -f $nomAffiche) 'Cyan'

        try {
            if ($item.QuietUninstallString) {
                # Chaine silencieuse fournie par l'editeur : executee telle quelle.
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $item.QuietUninstallString `
                              -Wait -NoNewWindow -ErrorAction Stop
            } elseif ($item.UninstallString -match 'msiexec') {
                $guid = [regex]::Match($item.UninstallString, '\{[0-9A-Fa-f\-]+\}').Value
                if ($guid) {
                    Start-Process -FilePath 'msiexec.exe' -ArgumentList '/x', $guid, '/qn', '/norestart' `
                                  -Wait -NoNewWindow -ErrorAction Stop
                }
            } elseif ($item.UninstallString) {
                if ($item.UninstallString -match '^\s*"([^"]+)"(.*)$') {
                    $exe = $Matches[1]; $reste = $Matches[2].Trim()
                } else {
                    $exe = $item.UninstallString.Trim(); $reste = ''
                }
                # Le commutateur silencieux depend du type de desinstalleur.
                if ($exe -match 'unins\d*\.exe$') {
                    $silence = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'   # Inno Setup
                } else {
                    $silence = '/S'                                          # NSIS
                }
                $ligne = ('"{0}" {1} {2}' -f $exe, $reste, $silence).Trim()
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $ligne `
                              -Wait -NoNewWindow -ErrorAction Stop
            }
        } catch {
            Ecrire ('    Erreur : {0}' -f $_.Exception.Message) 'Red'
        }

        # Le code de retour du desinstalleur ne fait pas foi : seule la
        # disparition de l'entree de desinstallation compte.
        Start-Sleep -Seconds 2
        $encorePresent = Get-ItemProperty $script:ClesDesinstallation -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -eq $nomAffiche }

        if (-not $encorePresent) {
            Ecrire '  Desinstalle.' 'Green'
            $statut = 'Desinstalle'
        } else {
            Ecrire '  Toujours present : desinstallation a terminer a la main.' 'Yellow'
            $statut = 'Manuel requis'
        }
    }

    return $statut
}

function Rename-Poste {
    param([string]$Nom)

    if ($env:COMPUTERNAME -eq $Nom) {
        Ecrire ('  Le poste s''appelle deja {0}.' -f $Nom) 'Green'
        return 'Deja nomme'
    }

    try {
        Rename-Computer -NewName $Nom -Force -ErrorAction Stop
        Ecrire ('  Poste renomme en {0} (effectif au redemarrage).' -f $Nom) 'Green'
        return 'Renomme (redemarrage requis)'
    } catch {
        Ecrire ('  Echec du renommage : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec'
    }
}
