<#
.SYNOPSIS
    Diagnostic des réglages d'impression d'une file Toshiba.

.DESCRIPTION
    Compare trois états du DEVMODE d'une file :
      - le blob de référence devmode\<Pilote>.bin ;
      - les « Paramètres par défaut de l'impression » (niveau machine) ;
      - les « Préférences d'impression » (niveau utilisateur).

    Puis réapplique le blob au niveau machine et relit, pour déterminer si le
    spouleur conserve réellement l'écriture ou s'il la normalise en silence.

    À lancer sur le poste où le copieur est installé, via
    Diagnostiquer-Reglages.bat (élévation requise pour l'écriture machine).

.PARAMETER PrinterName
    File à analyser. Proposée dans une liste si absente.

.PARAMETER DevModeDir
    Dossier des blobs de référence. Par défaut : .\devmode

.PARAMETER SansEcriture
    Se contente de lire et comparer, n'écrit rien.
#>

[CmdletBinding()]
param(
    [string]$PrinterName,
    [string]$DevModeDir,
    [switch]$SansEcriture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$racine = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $racine 'lib\DevMode.ps1')

function Write-Titre { param([string]$Message) Write-Host "`n=== $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Bon { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Mauvais { param([string]$Message) Write-Host "    KO  $Message" -ForegroundColor Red }

# Zones exclues : dmDeviceName (0-63) porte le nom de la file, dmFields (72-75)
# est renormalisé différemment selon le chemin de lecture.
function Compare-DevMode {
    param([byte[]]$A, [byte[]]$B)

    if ($A.Length -ne $B.Length) {
        return [pscustomobject]@{ Identique = $false; Ecarts = -1; Offsets = @(); Detail = "tailles différentes : $($A.Length) contre $($B.Length)" }
    }

    $offsets = New-Object System.Collections.Generic.List[int]
    foreach ($plage in @(@(64, 72), @(76, $A.Length))) {
        for ($i = $plage[0]; $i -lt $plage[1]; $i++) {
            if ($A[$i] -ne $B[$i]) { $offsets.Add($i) }
        }
    }

    return [pscustomobject]@{
        Identique = ($offsets.Count -eq 0)
        Ecarts    = $offsets.Count
        Offsets   = @($offsets | Select-Object -First 16)
        Detail    = if ($offsets.Count -eq 0) { 'identiques' } else { "$($offsets.Count) octets différents" }
    }
}

function Show-Comparaison {
    param([string]$Libelle, $Resultat)

    if ($Resultat.Identique) {
        Write-Bon "$Libelle : identiques"
        return
    }
    Write-Mauvais "$Libelle : $($Resultat.Detail)"
    if ($Resultat.Offsets.Count -gt 0) {
        Write-Info "    premiers offsets : $($Resultat.Offsets -join ', ')"
    }
}

function Show-Champs {
    param([string]$Libelle, [byte[]]$Data)

    $papier = [BitConverter]::ToUInt16($Data, 78)
    $couleur = [BitConverter]::ToUInt16($Data, 92)
    $duplex = [BitConverter]::ToUInt16($Data, 94)
    Write-Info ("{0,-14} taille={1,-6} dmPaperSize={2,-4} dmColor={3} dmDuplex={4}" -f $Libelle, $Data.Length, $papier, $couleur, $duplex)
}

$codeSortie = 0
try {
    Write-Host ''
    Write-Host '  Diagnostic des réglages TOSHIBA' -ForegroundColor White
    Write-Host '  -------------------------------' -ForegroundColor DarkGray

    if (-not $PrinterName) {
        $files = @(Get-Printer | Where-Object { $_.DriverName -like '*TOSHIBA*' } | Sort-Object Name)
        if ($files.Count -eq 0) { throw "Aucune file utilisant un pilote TOSHIBA sur ce poste." }

        Write-Host ''
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ("    {0}. {1}  [{2}]" -f ($i + 1), $files[$i].Name, $files[$i].DriverName)
        }
        Write-Host ''
        while (-not $PrinterName) {
            $choix = (Read-Host '    Numéro de la file').Trim()
            $n = 0
            if ([int]::TryParse($choix, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
                $PrinterName = $files[$n - 1].Name
            }
            else { Write-Host '    Choix invalide.' -ForegroundColor Yellow }
        }
    }

    $file = Get-Printer -Name $PrinterName -ErrorAction Stop
    Initialize-DevModeInterop

    Write-Titre 'File analysée'
    Write-Info "Nom    : $($file.Name)"
    Write-Info "Pilote : $($file.DriverName)"
    Write-Info "Port   : $($file.PortName)"

    $dossier = if ($DevModeDir) { $DevModeDir } else { Join-Path $racine 'devmode' }
    $cheminBlob = Join-Path $dossier "$($file.DriverName).bin"
    $blob = $null
    if (Test-Path -LiteralPath $cheminBlob) {
        $blob = [IO.File]::ReadAllBytes($cheminBlob)
        Write-Info "Blob   : $cheminBlob"
    }
    else {
        Write-Mauvais "Aucun blob de référence : $cheminBlob"
    }

    Write-Titre 'État actuel'
    $machine = [OMB.PrinterDevMode]::ExportPrinterDefaults($file.Name)
    $utilisateur = [OMB.PrinterDevMode]::Export($file.Name)
    if ($blob) { Show-Champs -Libelle 'blob' -Data $blob }
    Show-Champs -Libelle 'machine' -Data $machine
    Show-Champs -Libelle 'utilisateur' -Data $utilisateur

    Write-Titre 'Comparaisons'
    if ($blob) {
        Show-Comparaison -Libelle 'blob      vs machine    ' -Resultat (Compare-DevMode -A $blob -B $machine)
        Show-Comparaison -Libelle 'blob      vs utilisateur' -Resultat (Compare-DevMode -A $blob -B $utilisateur)
    }
    Show-Comparaison -Libelle 'machine   vs utilisateur' -Resultat (Compare-DevMode -A $machine -B $utilisateur)

    if ($SansEcriture -or -not $blob) {
        Write-Host ''
        Write-Info 'Test d''écriture non effectué.'
        return
    }

    Write-Titre 'Test d''écriture au niveau machine'
    Write-Info 'Application du blob puis relecture immédiate...'
    [OMB.PrinterDevMode]::Apply($file.Name, $blob, $true)
    $machineApres = [OMB.PrinterDevMode]::ExportPrinterDefaults($file.Name)

    $resultat = Compare-DevMode -A $blob -B $machineApres
    Show-Comparaison -Libelle 'blob      vs machine    ' -Resultat $resultat

    Write-Titre 'Verdict'
    if ($resultat.Identique) {
        Write-Bon "Le spouleur conserve l'écriture machine. Le blob est bien appliqué."
        Write-Info "Si l'interface affiche encore l'ancien réglage, fermer et rouvrir la fenêtre des propriétés."
    }
    else {
        Write-Mauvais "Le spouleur ne conserve pas la zone privée du pilote au niveau machine."
        Write-Info "Comparer avec la valeur brute stockée sous"
        Write-Info "HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers\<file>\Default DevMode :"
        Write-Info "c'est le défaut machine réel, indépendant des préférences de l'utilisateur."
    }

    Write-Titre 'Stockage brut'
    $cleHklm = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$($file.Name)"
    try {
        $brut = (Get-ItemProperty -Path $cleHklm -Name 'Default DevMode' -ErrorAction Stop).'Default DevMode'
        Show-Comparaison -Libelle 'blob      vs HKLM       ' -Resultat (Compare-DevMode -A $blob -B $brut)
    }
    catch {
        Write-Info "Valeur HKLM illisible : $($_.Exception.Message)"
    }

    Write-Titre 'Contenu brut pour analyse'
    $sortie = Join-Path $env:TEMP ("diagnostic-{0}.txt" -f ($file.Name -replace '[^A-Za-z0-9]', '_'))
    $lignes = New-Object System.Collections.Generic.List[string]
    $lignes.Add("file=$($file.Name)")
    $lignes.Add("pilote=$($file.DriverName)")
    $lignes.Add("blob=$($blob.Length) machine=$($machine.Length) utilisateur=$($utilisateur.Length) machineApres=$($machineApres.Length)")
    $lignes.Add("ecarts blob/machineApres=$($resultat.Ecarts)")
    $lignes.Add("offsets=$($resultat.Offsets -join ',')")
    [IO.File]::WriteAllLines($sortie, $lignes)
    Write-Info "Rapport : $sortie"
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
