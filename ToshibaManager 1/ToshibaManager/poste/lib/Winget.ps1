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

$script:WingetArgs = @(
    '--exact',
    '--silent',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--disable-interactivity'
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

function Install-AppWinget {
    param(
        [string]$Nom,
        [string]$Id,
        [switch]$SkipDeps
    )

    $wgArgs = $script:WingetArgs
    if ($SkipDeps) { $wgArgs = $script:WingetArgs + '--skip-dependencies' }

    winget list --id $Id --exact --accept-source-agreements | Out-Null
    $presente = ($LASTEXITCODE -eq 0)

    if ($presente) {
        Ecrire "  Deja presente : recherche d'une mise a jour..."
        winget upgrade --id $Id @wgArgs | Out-Null
        $code = $LASTEXITCODE

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
    winget install --id $Id @wgArgs | Out-Null
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Ecrire '  Installe.' 'Green'
        return 'Installe'
    }
    Ecrire ("  Echec de l'installation (code {0})." -f $code) 'Red'
    return "Echec ($code)"
}
