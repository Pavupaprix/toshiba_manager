<#
.SYNOPSIS
    Capture les réglages d'impression d'une file Toshiba de référence.

.DESCRIPTION
    Produit le fichier DEVMODE de référence consommé par Install-CopieurToshiba.ps1.
    Mode d'emploi :
      1. Installer une file avec le pilote voulu sur un poste de référence.
      2. Lancer ce script : il ouvre les préférences d'impression.
      3. Régler à la main noir & blanc, recto/verso et l'impression intelligente,
         puis valider par OK.
      4. Le script écrit devmode\<NomDuPilote>.bin.

    Un fichier par pilote suffit : il est réutilisable sur tous les postes et
    tous les modèles partageant ce pilote.

.PARAMETER PrinterName
    File de référence. Proposée dans une liste si absente.

.PARAMETER DevModeDir
    Dossier de sortie. Par défaut : .\devmode

.PARAMETER SansOuverture
    N'ouvre pas les préférences d'impression, exporte l'état actuel.

.EXAMPLE
    .\Export-ReglagesToshiba.ps1

.EXAMPLE
    .\Export-ReglagesToshiba.ps1 -PrinterName 'TOSHIBA 3525AC' -SansOuverture
#>

[CmdletBinding()]
param(
    [string]$PrinterName,
    [string]$DevModeDir,
    [switch]$Couleur,
    [switch]$SansOuverture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$racine = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $racine 'lib\DevMode.ps1')

function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Succes { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }

$codeSortie = 0
try {
    Write-Host ''
    Write-Host '  Capture des réglages d''impression TOSHIBA' -ForegroundColor White
    Write-Host '  -----------------------------------------' -ForegroundColor DarkGray
    Write-Host ''

    if (-not $PrinterName) {
        $files = @(Get-Printer | Where-Object { $_.DriverName -like '*TOSHIBA*' } | Sort-Object Name)
        if ($files.Count -eq 0) {
            throw "Aucune file utilisant un pilote TOSHIBA sur ce poste. Installer d'abord un copieur de référence."
        }

        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ("    {0}. {1}  [{2}]" -f ($i + 1), $files[$i].Name, $files[$i].DriverName)
        }
        Write-Host ''

        while (-not $PrinterName) {
            $choix = (Read-Host '    Numéro de la file de référence').Trim()
            $n = 0
            if ([int]::TryParse($choix, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
                $PrinterName = $files[$n - 1].Name
            }
            else {
                Write-Host '    Choix invalide.' -ForegroundColor Yellow
            }
        }
    }

    $file = Get-Printer -Name $PrinterName -ErrorAction Stop
    Write-Info "File retenue  : $($file.Name)"
    Write-Info "Pilote        : $($file.DriverName)"

    if (-not $SansOuverture) {
        Write-Host ''
        Write-Host '    Les préférences d''impression vont s''ouvrir.' -ForegroundColor White
        Write-Host '    Tout ce qui est réglé dans cette fenêtre sera rejoué sur chaque' -ForegroundColor White
        Write-Host '    installation. Points à vérifier onglet par onglet :' -ForegroundColor White
        Write-Host ''
        if ($Couleur) {
            Write-Host '      Basique  : Couleur = Couleur (pas Auto)' -ForegroundColor Gray
        }
        else {
            Write-Host '      Basique  : Couleur = Noir & blanc' -ForegroundColor Gray
        }
        Write-Host '                 Format papier original = A4' -ForegroundColor Gray
        Write-Host '      Finition : Recto/verso = Livre (reliure bord long)' -ForegroundColor Gray
        Write-Host '      Effet    : cocher « Impression intelligente pour plusieurs' -ForegroundColor Gray
        Write-Host '                 formats et orientations (Q) »' -ForegroundColor Gray
        Write-Host ''
        Write-Host '    Puis valider par OK.' -ForegroundColor White
        Write-Host ''
        Read-Host '    Entrée pour ouvrir' | Out-Null

        Start-Process -FilePath 'rundll32.exe' `
            -ArgumentList ('printui.dll,PrintUIEntry /e /n "{0}"' -f $file.Name) `
            -Wait -NoNewWindow

        Write-Host ''
        Read-Host '    Réglages terminés ? Entrée pour capturer' | Out-Null
    }

    $dossier = if ($DevModeDir) { $DevModeDir } else { Join-Path $racine 'devmode' }
    $suffixe = if ($Couleur) { '.couleur' } else { '' }
    $destination = Join-Path $dossier ("{0}{1}.bin" -f $file.DriverName, $suffixe)

    $precedent = $null
    if (Test-Path -LiteralPath $destination) {
        $precedent = [IO.File]::ReadAllBytes($destination)
        $sauvegarde = "$destination.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $destination -Destination $sauvegarde
        Write-Info "Ancien fichier sauvegardé : $sauvegarde"
    }

    $taille = Export-PrinterDevMode -PrinterName $file.Name -Path $destination
    Write-Succes "$taille octets écrits dans $destination"

    # Comparaison avec la capture précédente : si rien n'a bougé, c'est que les
    # réglages n'ont pas été modifiés dans la fenêtre, ou qu'elle a été annulée.
    if ($precedent) {
        $nouveau = [IO.File]::ReadAllBytes($destination)
        $ecarts = 0
        if ($precedent.Length -ne $nouveau.Length) {
            $ecarts = -1
        }
        else {
            for ($i = 64; $i -lt $nouveau.Length; $i++) {
                if ($precedent[$i] -ne $nouveau[$i]) { $ecarts++ }
            }
        }

        if ($ecarts -eq 0) {
            Write-Host '    /!\ Capture identique à la précédente : aucun réglage modifié.' -ForegroundColor Yellow
            Write-Host '        Si vous vouliez changer quelque chose, relancez et validez par OK.' -ForegroundColor Yellow
        }
        elseif ($ecarts -gt 0) {
            Write-Info "$ecarts octets modifiés par rapport à la capture précédente"
        }
    }

    Write-Host ''
    Write-Host '    Déposer ce fichier dans le dossier devmode\ distribué avec' -ForegroundColor White
    Write-Host '    le script d''installation.' -ForegroundColor White
}
catch {
    Write-Host ''
    Write-Host "  ECHEC : $($_.Exception.Message)" -ForegroundColor Red
    $codeSortie = 1
}
finally {
    Write-Host ''
    Read-Host '  Appuyez sur Entrée pour fermer' | Out-Null
}

exit $codeSortie
