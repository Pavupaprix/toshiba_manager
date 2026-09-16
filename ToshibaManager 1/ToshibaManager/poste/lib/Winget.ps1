<#
.SYNOPSIS
    Installation et mise a jour des applications par winget.

.DESCRIPTION
    Reprend la logique eprouvee en clientele : si l'application est absente on
    installe, si elle est presente on tente une mise a jour, et le code
    -1978335189 ("aucune mise a jour applicable") est un succes, pas un echec.
#>

# Code winget : "aucune mise a jour applicable".
$script:NO_APPLICABLE_UPGRADE = -1978335189

# Code winget : l'empreinte du fichier telecharge ne correspond pas au
# catalogue. Vu sur Microsoft.Office, dont l'installeur est un lanceur que
# Microsoft remplace sur son CDN sans que le catalogue winget suive.
$script:EMPREINTE_DIFFERENTE = -1978335215

# --disable-interactivity est volontairement absent : il supprime aussi la barre
# de progression de winget, et le script paraissait alors fige pendant chaque
# telechargement. Les deux --accept-* couvrent les seules invites que winget
# poserait ici, et --exact --id ecarte le choix entre plusieurs paquets.
#
# --source winget epingle la source communautaire, d'ou viennent toutes nos
# applications. Sans lui, winget interroge aussi msstore : derriere un pare-feu
# qui inspecte le TLS, cette source echoue (certificat resigne, winget epingle
# celui de Microsoft), winget ne sait plus arbitrer entre ses sources et
# renonce en demandant --source. Cela s'est produit sur un reseau d'entreprise.
$script:WingetArgs = @(
    '--exact',
    '--source', 'winget',
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements'
)

function Test-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }

    Ecrire ''
    Ecrire "winget est introuvable sur ce poste." 'Red'
    Ecrire "Installez 'Programme d'installation d'application' depuis le Microsoft Store," 'Red'
    Ecrire "puis relancez ce script." 'Red'
    Ecrire ''
    return $false
}

function Test-OfficePresent {
    <#
        Microsoft 365 n'est installe que s'il manque. Deux pistes, parce
        qu'aucune n'est fiable seule : la configuration Click-to-Run couvre les
        versions modernes, les entrees de desinstallation couvrent les
        installations MSI plus anciennes.
    #>
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r -and $c2r.ProductReleaseIds) { return $true }

    $cles = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $trouve = Get-ItemProperty $cles -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -match 'Microsoft (365|Office)' -and
                             $_.DisplayName -notmatch 'Runtime|Tools|Language Pack' }
    return [bool]$trouve
}

function Invoke-Winget {
    <#
        Lance winget et renvoie son code de sortie.

        Pour un paquet marque lent -- Microsoft 365 telecharge plusieurs Go
        depuis les serveurs Microsoft et, installe en silencieux, n'affiche
        rien pendant ce temps -- winget est lance comme processus distinct pour
        qu'un compteur de temps ecoule puisse tourner a cote. Sans ce repere,
        rien ne distingue une installation en cours d'un blocage.
    #>
    param(
        [string]$Action,
        [string]$Id,
        [string[]]$Arguments,
        [switch]$Lent
    )

    $parametres = @($Action, '--id', $Id) + $Arguments

    # Start-Process, et jamais "& winget" : appele directement dans une
    # fonction dont on recupere la valeur, winget ecrit sur le pipeline de
    # PowerShell et sa sortie se melange au code de retour. La fonction
    # renvoyait alors un tableau, "-eq 0" n'etait jamais vrai, et le texte de
    # winget s'affichait a la place du code -- toute installation reussie
    # passait pour un echec.
    #
    # -NoNewWindow fait heriter la console : winget garde sa barre de
    # progression, ce qu'une redirection par pipe lui ferait abandonner.
    $exe = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = 'winget.exe' }

    $proc = Start-Process -FilePath $exe -ArgumentList $parametres `
                          -NoNewWindow -PassThru -ErrorAction Stop
    # Sans cette lecture, .NET ne conserve pas le handle du processus et
    # ExitCode revient vide une fois qu'il s'est termine.
    $null = $proc.Handle

    if (-not $Lent) {
        $proc.WaitForExit()
        return $proc.ExitCode
    }

    $debut = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 5
        $ecoule = (Get-Date) - $debut
        Write-Host ("`r    en cours depuis {0:mm\:ss} - ne fermez pas cette fenetre    " -f $ecoule) `
                   -NoNewline -ForegroundColor DarkGray
    }
    Write-Host "`r                                                                    " -NoNewline
    Write-Host ''
    return $proc.ExitCode
}

function Invoke-WingetAvecAttente {
    <#
        Invoke-Winget, precede d'une attente et suivi d'une reprise si Windows
        Installer etait occupe.

        La plupart des paquets winget posent un MSI, et Windows Installer ne
        mene qu'une transaction a la fois. Sur un poste neuf, Windows Update et
        le Microsoft Store travaillent en arriere-plan pendant toute la
        preparation : sans cette attente, l'installation qui tombe au mauvais
        moment echoue en 1618 et le poste repart avec une application en moins.

        Le second essai retelecharge le paquet, winget ne gardant pas ce qu'il
        vient de prendre. C'est le prix d'une application installee plutot
        qu'absente, et il n'est paye que si le verrou etait effectivement pris.
    #>
    param(
        [string]$Action,
        [string]$Id,
        [string[]]$Arguments,
        [switch]$Lent
    )

    Wait-InstallateurMsi | Out-Null
    $code = Invoke-Winget -Action $Action -Id $Id -Arguments $Arguments -Lent:$Lent

    if ($code -eq $script:WINGET_DEJA_EN_COURS -or $code -eq $script:MSI_DEJA_EN_COURS) {
        Ecrire '  Windows Installer etait occupe, nouvel essai...' 'Yellow'
        Wait-InstallateurMsi | Out-Null
        $code = Invoke-Winget -Action $Action -Id $Id -Arguments $Arguments -Lent:$Lent
    }
    return $code
}

function Install-AppWinget {
    param(
        [string]$Nom,
        [string]$Id,
        [switch]$SkipDeps,
        [switch]$Lent
    )

    $wgArgs = $script:WingetArgs
    if ($SkipDeps) { $wgArgs = $script:WingetArgs + '--skip-dependencies' }

    winget list --id $Id --exact --source winget --accept-source-agreements | Out-Null
    $presente = ($LASTEXITCODE -eq 0)

    if ($presente) {
        Ecrire "  Deja presente : recherche d'une mise a jour..."
        $code = Invoke-WingetAvecAttente -Action 'upgrade' -Id $Id -Arguments $wgArgs -Lent:$Lent

        if ($code -eq 0) {
            Ecrire '  Mis a jour.' 'Green'
            return 'Mis a jour'
        }
        if ($code -eq $script:NO_APPLICABLE_UPGRADE) {
            Ecrire '  Deja a jour.' 'Green'
            return 'Deja a jour'
        }
        Ecrire ("  Echec de la mise a jour (code {0})." -f $code) 'Red'
        Show-EchecWinget -Code $code -Nom $Nom
        return "Echec ($code)"
    }

    Ecrire '  Absente : installation en cours...'
    $code = Invoke-WingetAvecAttente -Action 'install' -Id $Id -Arguments $wgArgs -Lent:$Lent

    if ($code -eq 0) {
        Ecrire '  Installe.' 'Green'
        return 'Installe'
    }
    Ecrire ("  Echec de l'installation (code {0})." -f $code) 'Red'
    Show-EchecWinget -Code $code -Nom $Nom
    return "Echec ($code)"
}

function Show-EchecWinget {
    <#
        Traduit les codes winget que le technicien va reellement rencontrer.

        Un code brut comme -1978335215 n'apprend rien sur place et envoie
        chercher ailleurs. Les deux cas ci-dessous ont une suite a donner
        differente, d'ou l'interet de les distinguer a l'ecran.
    #>
    param(
        [int]$Code,
        [string]$Nom
    )

    if ($Code -eq $script:EMPREINTE_DIFFERENTE) {
        Ecrire "  L'empreinte du fichier telecharge ne correspond pas au catalogue winget." 'Yellow'
        Ecrire "  L'editeur a remplace son installeur sans que le catalogue suive, et winget" 'Yellow'
        Ecrire "  refuse de passer outre en session administrateur. Ce n'est pas un probleme" 'Yellow'
        Ecrire "  de ce poste : la correction vient du catalogue." 'Yellow'
        Ecrire ("  Installez {0} a la main pour ce poste." -f $Nom) 'Yellow'
        return
    }

    if ($Code -eq $script:WINGET_DEJA_EN_COURS -or $Code -eq $script:MSI_DEJA_EN_COURS) {
        Ecrire "  Une autre installation Windows tenait encore le verrou apres l'attente." 'Yellow'
        Ecrire "  Relancer le script apres redemarrage suffit en general." 'Yellow'
    }
}
