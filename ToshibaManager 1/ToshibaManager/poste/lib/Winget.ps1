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

# --disable-interactivity est volontairement absent : il supprime aussi la barre
# de progression de winget, et le script paraissait alors fige pendant chaque
# telechargement. Les deux --accept-* couvrent les seules invites que winget
# poserait ici, et --exact --id ecarte le choix entre plusieurs paquets.
$script:WingetArgs = @(
    '--exact',
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

function Install-AppWinget {
    param(
        [string]$Nom,
        [string]$Id,
        [switch]$SkipDeps,
        [switch]$Lent
    )

    $wgArgs = $script:WingetArgs
    if ($SkipDeps) { $wgArgs = $script:WingetArgs + '--skip-dependencies' }

    winget list --id $Id --exact --accept-source-agreements | Out-Null
    $presente = ($LASTEXITCODE -eq 0)

    if ($presente) {
        Ecrire "  Deja presente : recherche d'une mise a jour..."
        $code = Invoke-Winget -Action 'upgrade' -Id $Id -Arguments $wgArgs -Lent:$Lent

        if ($code -eq 0) {
            Ecrire '  Mis a jour.' 'Green'
            return 'Mis a jour'
        }
        if ($code -eq $script:NO_APPLICABLE_UPGRADE) {
            Ecrire '  Deja a jour.' 'Green'
            return 'Deja a jour'
        }
        Ecrire ("  Echec de la mise a jour (code {0})." -f $code) 'Red'
        return "Echec ($code)"
    }

    Ecrire '  Absente : installation en cours...'
    $code = Invoke-Winget -Action 'install' -Id $Id -Arguments $wgArgs -Lent:$Lent

    if ($code -eq 0) {
        Ecrire '  Installe.' 'Green'
        return 'Installe'
    }
    Ecrire ("  Echec de l'installation (code {0})." -f $code) 'Red'
    return "Echec ($code)"
}
