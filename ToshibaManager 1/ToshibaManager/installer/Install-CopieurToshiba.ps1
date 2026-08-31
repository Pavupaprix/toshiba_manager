<#
.SYNOPSIS
    Installation automatique d'un copieur Toshiba en port TCP/IP.

.DESCRIPTION
    Demande l'adresse IP du copieur, détecte le modèle en SNMP, choisit le pilote
    adapté (TOSHIBA Universal Printer 2 pour les multifonctions, TOSHIBA Generic
    Printer XL pour les imprimantes), installe le pilote, crée le port TCP/IP,
    crée la file « TOSHIBA <MODELE> », applique les réglages par défaut
    (noir & blanc, recto/verso, options Toshiba via DEVMODE de référence) et
    définit la file comme imprimante par défaut.

.PARAMETER IP
    Adresse IP du copieur. Demandée interactivement si absente.

.PARAMETER Modele
    Force le modèle (ex. 3525AC) et court-circuite la détection SNMP.

.PARAMETER Pilote
    Force le pilote : Universal, Generic ou GenericPCL5.

.PARAMETER SourceRacine
    Dossier local ou racine web (https://...) contenant les archives de pilotes.
    Par défaut : le dossier « Drivers Toshiba » à côté du script.

.PARAMETER DevModeDir
    Dossier contenant les DEVMODE de référence. Par défaut : .\devmode

.PARAMETER Communaute
    Communauté SNMP en lecture. Par défaut : public

.PARAMETER FormatPapier
    Format papier par défaut. Par défaut : A4. Chaîne vide pour ne pas y toucher.

.PARAMETER NonInteractif
    Échoue au lieu de poser une question. Impose -IP et, si le SNMP ne répond
    pas, -Modele et -Pilote.

.PARAMETER PasDeParDefaut
    N'affecte pas l'imprimante comme imprimante par défaut.

.EXAMPLE
    .\Install-CopieurToshiba.ps1

.EXAMPLE
    .\Install-CopieurToshiba.ps1 -IP 192.168.22.3 -Modele 3525AC -Pilote Universal -NonInteractif
#>

[CmdletBinding()]
param(
    [string]$IP,
    [string]$Modele,
    [ValidateSet('Universal', 'Generic', 'GenericPCL5')]
    [string]$Pilote,
    [string]$SourceRacine,
    [string]$DevModeDir,
    [string]$Communaute = 'public',
    [string]$FormatPapier = 'A4',
    [switch]$NonInteractif,
    [switch]$PasDeParDefaut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Expand-Archive est nettement plus rapide sans barre de progression

# --------------------------------------------------------------------------
# Constantes et état
# --------------------------------------------------------------------------

$script:RacineScript = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:DossierTravail = Join-Path $env:TEMP 'InstallCopieurToshiba'
$script:DossierCache = Join-Path $script:DossierTravail 'cache'
$script:Avertissements = New-Object System.Collections.Generic.List[string]
$script:TranscriptActif = $false

# --------------------------------------------------------------------------
# Affichage
# --------------------------------------------------------------------------

function Write-Etape { param([string]$Message) Write-Host "`n=== $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Succes { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }

function Write-Avertissement {
    param([string]$Message)
    Write-Host "    /!\ $Message" -ForegroundColor Yellow
    $script:Avertissements.Add($Message)
}

function Read-Saisie {
    param(
        [string]$Invite,
        [string]$Defaut
    )
    if ($NonInteractif) { throw "Mode non interactif : information manquante ($Invite)." }

    if ($Defaut) {
        $reponse = Read-Host "$Invite [$Defaut]"
        if ([string]::IsNullOrWhiteSpace($reponse)) { return $Defaut }
        return $reponse.Trim()
    }
    return (Read-Host $Invite).Trim()
}

function Confirm-Oui {
    param(
        [string]$Question,
        [bool]$DefautOui = $true
    )
    if ($NonInteractif) { return $DefautOui }

    $suffixe = if ($DefautOui) { '[O/n]' } else { '[o/N]' }
    while ($true) {
        $reponse = (Read-Host "$Question $suffixe").Trim()
        if ([string]::IsNullOrWhiteSpace($reponse)) { return $DefautOui }
        if ($reponse -match '^(o|oui|y|yes)$') { return $true }
        if ($reponse -match '^(n|non|no)$') { return $false }
        Write-Host "    Répondre par o ou n." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Pré-vol
# --------------------------------------------------------------------------

function Test-Administrateur {
    $identite = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identite)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Journal {
    $dossier = Join-Path $env:ProgramData 'OMB\InstallCopieur'
    try {
        if (-not (Test-Path -LiteralPath $dossier)) {
            New-Item -ItemType Directory -Path $dossier -Force | Out-Null
        }
        $fichier = Join-Path $dossier ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $fichier -Force | Out-Null
        $script:TranscriptActif = $true
        Write-Info "Journal : $fichier"
    }
    catch {
        Write-Host "    Journalisation indisponible : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-Journal {
    if ($script:TranscriptActif) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptActif = $false
    }
}

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

function Get-Configuration {
    param([string]$NomFichier)

    $chemin = Join-Path $script:RacineScript "config\$NomFichier"
    if (Test-Path -LiteralPath $chemin) {
        return (Get-Content -LiteralPath $chemin -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    if ($SourceRacine -and $SourceRacine -match '^https?://') {
        $url = "$($SourceRacine.TrimEnd('/'))/config/$NomFichier"
        Write-Info "Configuration locale absente, téléchargement de $url"
        return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
    }

    throw "Fichier de configuration introuvable : $chemin"
}

# --------------------------------------------------------------------------
# Réseau et détection
# --------------------------------------------------------------------------

function Read-AdresseIP {
    param([string]$Valeur)

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Valeur)) {
            $Valeur = Read-Saisie -Invite 'Adresse IP du copieur'
        }

        $analysee = $null
        if ([System.Net.IPAddress]::TryParse($Valeur.Trim(), [ref]$analysee)) {
            return $Valeur.Trim()
        }

        Write-Host "    Adresse IP invalide : '$Valeur'" -ForegroundColor Yellow
        if ($NonInteractif) { throw "Adresse IP invalide : $Valeur" }
        $Valeur = $null
    }
}

function Test-Copieur {
    param([string]$Adresse)

    $ping = Test-Connection -ComputerName $Adresse -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Succes "Copieur joignable en ICMP"
    }
    else {
        Write-Info "Pas de réponse ICMP (peut être filtré), test des ports d'impression"
    }

    $portOuvert = $null
    foreach ($port in 9100, 515) {
        $test = Test-NetConnection -ComputerName $Adresse -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($test) { $portOuvert = $port; break }
    }

    if ($portOuvert) {
        Write-Succes "Port d'impression $portOuvert ouvert"
        return $true
    }

    Write-Avertissement "Aucun port d'impression (9100, 515) ne répond sur $Adresse."
    if (-not $ping) {
        if (-not (Confirm-Oui -Question "    Le copieur semble injoignable. Continuer quand même ?" -DefautOui $false)) {
            throw "Installation annulée : copieur injoignable sur $Adresse."
        }
    }
    return $false
}

function Resolve-Modele {
    param([string]$Adresse)

    if ($Modele) {
        $valeur = ($Modele -replace '\s', '').ToUpperInvariant()
        Write-Info "Modèle imposé en paramètre : $valeur"
        return [pscustomobject]@{ Modele = $valeur; Source = 'parametre'; Description = $null }
    }

    Write-Info "Interrogation SNMP de $Adresse (communauté '$Communaute')..."
    $reponse = Get-ToshibaDescription -IPAddress $Adresse -Community $Communaute

    if ($reponse) {
        Write-Info "Réponse SNMP : $($reponse.Description)"
        $detecte = Get-ModeleDepuisDescription -Description $reponse.Description
        if ($detecte) {
            Write-Succes "Modèle détecté : $detecte"
            Write-Host "    La file sera nommée « TOSHIBA $detecte »." -ForegroundColor Gray
            Write-Host "    Entrée pour valider, ou saisir un autre modèle sans espace (ex. 3525AC, 5015AC, 305CP)." -ForegroundColor Gray
            $valide = Read-Saisie -Invite '    Modèle' -Defaut $detecte
            return [pscustomobject]@{
                Modele      = ($valide -replace '\s', '').ToUpperInvariant()
                Source      = 'snmp'
                Description = $reponse.Description
            }
        }
        Write-Avertissement "Le copieur a répondu mais le modèle n'a pas pu être extrait de la description."
    }
    else {
        Write-Avertissement "Aucune réponse SNMP (service désactivé, communauté différente ou filtrage réseau)."
    }

    $saisi = Read-Saisie -Invite '    Modèle du copieur (ex. 3525AC)'
    if ([string]::IsNullOrWhiteSpace($saisi)) { throw "Modèle non renseigné." }

    return [pscustomobject]@{
        Modele      = ($saisi -replace '\s', '').ToUpperInvariant()
        Source      = 'manuel'
        Description = if ($reponse) { $reponse.Description } else { $null }
    }
}

function Resolve-Pilote {
    param(
        [string]$ModeleCopieur,
        [string]$DetectionSource,
        $ConfigModeles,
        $ConfigSources
    )

    if ($Pilote) {
        Write-Info "Pilote imposé en paramètre : $Pilote"
        return $Pilote
    }

    $propose = $null
    if ($DetectionSource -ne 'manuel') {
        foreach ($regle in $ConfigModeles.regles) {
            if ([regex]::IsMatch($ModeleCopieur, $regle.motif, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $propose = $regle.pilote
                Write-Info "Règle « $($regle.commentaire) » appliquée."
                break
            }
        }
        if (-not $propose) {
            $propose = $ConfigModeles.piloteParDefaut
            Write-Info "Aucune règle ne correspond à $ModeleCopieur, pilote par défaut retenu."
        }
        Write-Succes "Pilote proposé : $propose ($($ConfigSources.pilotes.$propose.nomPilote))"
        if (Confirm-Oui -Question "    Utiliser ce pilote ?" -DefautOui $true) {
            return $propose
        }
    }
    else {
        Write-Info "Détection automatique indisponible : choix du pilote à faire manuellement."
    }

    # Choix explicite par nom de pilote, jamais par « gros / petit ».
    $cles = @($ConfigSources.pilotes.PSObject.Properties.Name)
    Write-Host ''
    for ($i = 0; $i -lt $cles.Count; $i++) {
        Write-Host ("    {0}. {1} — {2}" -f ($i + 1), $cles[$i], $ConfigSources.pilotes.($cles[$i]).libelle)
    }
    while ($true) {
        $choix = Read-Saisie -Invite '    Numéro du pilote'
        $n = 0
        if ([int]::TryParse($choix, [ref]$n) -and $n -ge 1 -and $n -le $cles.Count) {
            return $cles[$n - 1]
        }
        Write-Host "    Choix invalide." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Récupération et installation du pilote
# --------------------------------------------------------------------------

function Get-ArchivePilote {
    param($DefinitionPilote, $ConfigSources)

    $archive = $DefinitionPilote.archive

    # 1. Source explicite ou racine web déclarée dans la configuration.
    $racine = $SourceRacine
    if (-not $racine -and $ConfigSources.racineWeb) { $racine = $ConfigSources.racineWeb }

    if ($racine -and $racine -match '^https?://') {
        return Get-ArchiveDepuisWeb -RacineWeb $racine -Archive $archive -Sha256 $DefinitionPilote.sha256
    }

    # 2. Dossier local (paramètre, puis dossier déclaré à côté du script).
    $dossiers = New-Object System.Collections.Generic.List[string]
    if ($racine) { $dossiers.Add($racine) }
    $dossiers.Add((Join-Path $script:RacineScript $ConfigSources.racineLocale))
    $dossiers.Add($script:RacineScript)

    foreach ($dossier in $dossiers) {
        $chemin = Join-Path $dossier $archive
        if (Test-Path -LiteralPath $chemin) {
            Write-Succes "Archive locale : $chemin"
            return $chemin
        }
    }

    throw "Archive « $archive » introuvable. Dossiers examinés : $($dossiers -join ' ; ')"
}

function Get-ArchiveDepuisWeb {
    param(
        [string]$RacineWeb,
        [string]$Archive,
        [string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $script:DossierCache)) {
        New-Item -ItemType Directory -Path $script:DossierCache -Force | Out-Null
    }
    $destination = Join-Path $script:DossierCache $Archive

    if ((Test-Path -LiteralPath $destination) -and $Sha256) {
        $empreinte = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($empreinte -eq $Sha256.ToUpperInvariant()) {
            Write-Succes "Archive déjà en cache : $destination"
            return $destination
        }
        Remove-Item -LiteralPath $destination -Force
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = "$($RacineWeb.TrimEnd('/'))/$([uri]::EscapeDataString($Archive))"
    Write-Info "Téléchargement de $url"
    try {
        Start-BitsTransfer -Source $url -Destination $destination -ErrorAction Stop
    }
    catch {
        Write-Info "BITS indisponible, repli sur Invoke-WebRequest."
        Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing -TimeoutSec 600
    }

    if ($Sha256) {
        $empreinte = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($empreinte -ne $Sha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            throw "Empreinte SHA256 incorrecte pour $Archive (attendu $Sha256, obtenu $empreinte)."
        }
        Write-Succes "Empreinte SHA256 vérifiée"
    }
    else {
        Write-Avertissement "Aucune empreinte SHA256 déclarée pour $Archive : intégrité non vérifiée."
    }

    return $destination
}

function Expand-ArchivePilote {
    param([string]$CheminArchive)

    $nom = [System.IO.Path]::GetFileNameWithoutExtension($CheminArchive)
    $cible = Join-Path $script:DossierTravail ("extrait\" + ($nom -replace '[^A-Za-z0-9\.\-]', '_'))
    $marqueur = Join-Path $cible '.extraction-terminee'

    if (Test-Path -LiteralPath $marqueur) {
        Write-Succes "Pilote déjà décompressé : $cible"
        return $cible
    }

    if (Test-Path -LiteralPath $cible) { Remove-Item -LiteralPath $cible -Recurse -Force }
    New-Item -ItemType Directory -Path $cible -Force | Out-Null

    Write-Info "Décompression de $([System.IO.Path]::GetFileName($CheminArchive))..."
    Expand-Archive -LiteralPath $CheminArchive -DestinationPath $cible -Force
    New-Item -ItemType File -Path $marqueur -Force | Out-Null
    Write-Succes "Décompressé dans $cible"
    return $cible
}

function Resolve-CheminInf {
    param(
        [string]$DossierExtrait,
        $DefinitionPilote
    )

    $architecture = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
    $nomInf = if ($architecture -eq 'amd64') { $DefinitionPilote.infAmd64 } else { $DefinitionPilote.infX86 }

    $candidats = @(Get-ChildItem -LiteralPath $DossierExtrait -Filter $nomInf -Recurse -File -ErrorAction SilentlyContinue)
    if ($candidats.Count -eq 0) {
        throw "Fichier INF « $nomInf » introuvable dans $DossierExtrait."
    }

    if ($candidats.Count -gt 1) {
        $motif = if ($architecture -eq 'amd64') { '64bit' } else { '32bit' }
        $filtre = @($candidats | Where-Object { $_.FullName -like "*$motif*" })
        if ($filtre.Count -gt 0) { $candidats = $filtre }
    }

    Write-Succes "INF retenu : $($candidats[0].FullName)"
    return $candidats[0].FullName
}

function Install-PiloteImpression {
    param(
        [string]$CheminInf,
        [string]$NomPilote
    )

    if (Get-PrinterDriver -Name $NomPilote -ErrorAction SilentlyContinue) {
        Write-Succes "Pilote « $NomPilote » déjà présent"
        return
    }

    Write-Info "Injection dans le magasin de pilotes (pnputil)..."
    # pnputil ecrit sur stderr meme en cas de succes partiel : on neutralise
    # temporairement le mode Stop pour eviter un NativeCommandError.
    $preferenceInitiale = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sortie = @(& pnputil.exe /add-driver "$CheminInf" /install 2>&1 | ForEach-Object { "$_" })
    $ErrorActionPreference = $preferenceInitiale
    Write-Verbose ($sortie -join [Environment]::NewLine)

    # Le code de retour de pnputil n'est pas fiable : on contrôle par présence réelle.
    try {
        Add-PrinterDriver -Name $NomPilote -ErrorAction Stop
    }
    catch {
        Write-Info "Add-PrinterDriver a échoué, repli sur printui.dll."
        $arguments = '/ia /m "{0}" /f "{1}"' -f $NomPilote, $CheminInf
        Start-Process -FilePath 'rundll32.exe' -ArgumentList "printui.dll,PrintUIEntry $arguments" -Wait -NoNewWindow
    }

    if (-not (Get-PrinterDriver -Name $NomPilote -ErrorAction SilentlyContinue)) {
        $detail = ($sortie | Where-Object { $_ -match 'chec|ailed|rror|rreur|signature' } | Select-Object -First 3) -join ' | '
        throw "Le pilote « $NomPilote » n'est pas installé après pnputil. $detail"
    }
    Write-Succes "Pilote « $NomPilote » installé"
}

# --------------------------------------------------------------------------
# Port, file et réglages
# --------------------------------------------------------------------------

function Install-PortTcpIp {
    param([string]$Adresse)

    $nomPort = "IP_$Adresse"
    $existant = Get-PrinterPort -Name $nomPort -ErrorAction SilentlyContinue

    if ($existant) {
        Write-Succes "Port TCP/IP « $nomPort » déjà présent"
        return $nomPort
    }

    Add-PrinterPort -Name $nomPort -PrinterHostAddress $Adresse -ErrorAction Stop
    if (-not (Get-PrinterPort -Name $nomPort -ErrorAction SilentlyContinue)) {
        throw "Le port TCP/IP « $nomPort » n'a pas été créé."
    }
    Write-Succes "Port TCP/IP « $nomPort » créé sur $Adresse"
    return $nomPort
}

function Get-NomFileLibre {
    param(
        [string]$Base,
        [string]$NomAExclure
    )

    $existants = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $candidat = $Base
    $index = 1
    while ($existants -contains $candidat -and $candidat -ne $NomAExclure) {
        $index++
        $candidat = "$Base $index"
    }
    return $candidat
}

function Install-FileImpression {
    param(
        [string]$NomBase,
        [string]$NomPort,
        [string]$NomPilote
    )

    $existante = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $NomPort })

    if ($existante.Count -gt 0) {
        $file = $existante[0]
        Write-Info "Une file existe déjà sur ce port : « $($file.Name) »"
        if (-not (Confirm-Oui -Question "    La reconfigurer plutôt que d'en créer une seconde ?" -DefautOui $true)) {
            throw "Installation annulée : une file utilise déjà le port $NomPort."
        }

        if ($file.DriverName -ne $NomPilote) {
            Write-Info "Changement de pilote : « $($file.DriverName) » -> « $NomPilote »"
            Set-Printer -Name $file.Name -DriverName $NomPilote
        }

        $nomVoulu = Get-NomFileLibre -Base $NomBase -NomAExclure $file.Name
        if ($file.Name -ne $nomVoulu) {
            Rename-Printer -Name $file.Name -NewName $nomVoulu
            Write-Succes "File renommée en « $nomVoulu »"
        }
        return $nomVoulu
    }

    $nomFinal = Get-NomFileLibre -Base $NomBase
    Add-Printer -Name $nomFinal -DriverName $NomPilote -PortName $NomPort -ErrorAction Stop

    # Contrôle par présence réelle, pas par code de retour.
    if (-not (Get-Printer -Name $nomFinal -ErrorAction SilentlyContinue)) {
        # Repli : retrouver la file par son port, puis par son pilote, et la renommer.
        $retrouvee = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $NomPort })
        if ($retrouvee.Count -eq 0) {
            $retrouvee = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.DriverName -eq $NomPilote })
        }
        if ($retrouvee.Count -eq 0) {
            throw "La file « $nomFinal » est introuvable après Add-Printer."
        }
        Write-Avertissement "File créée sous un autre nom (« $($retrouvee[0].Name) »), renommage en cours."
        Rename-Printer -Name $retrouvee[0].Name -NewName $nomFinal
    }

    Write-Succes "File « $nomFinal » créée sur $NomPort"
    return $nomFinal
}

function Set-ReglagesImpression {
    param(
        [string]$NomFile,
        [string]$NomPilote
    )

    $dossierDevMode = if ($DevModeDir) { $DevModeDir } else { Join-Path $script:RacineScript 'devmode' }
    $blob = Join-Path $dossierDevMode "$NomPilote.bin"
    $blobPresent = Test-Path -LiteralPath $blob

    # 1. Réglages standard par cmdlet. Set-PrintConfiguration reconstruit le
    #    DEVMODE machine via WMI et perd au passage la zone privée du pilote :
    #    ces appels doivent donc précéder l'application du DEVMODE de référence,
    #    jamais la suivre.
    try {
        Set-PrintConfiguration -PrinterName $NomFile -Color $false -ErrorAction Stop
        Write-Succes "Noir et blanc par défaut"
    }
    catch {
        Write-Avertissement "Impossible de forcer le noir et blanc : $($_.Exception.Message)"
    }

    try {
        Set-PrintConfiguration -PrinterName $NomFile -DuplexingMode TwoSidedLongEdge -ErrorAction Stop
        Write-Succes "Recto/verso (reliure bord long) par défaut"
    }
    catch {
        Write-Avertissement "Impossible de forcer le recto/verso : $($_.Exception.Message)"
    }

    if ($FormatPapier) {
        try {
            Set-PrintConfiguration -PrinterName $NomFile -PaperSize $FormatPapier -ErrorAction Stop
            Write-Succes "Format papier $FormatPapier par défaut"
        }
        catch {
            Write-Avertissement "Impossible de forcer le format papier $FormatPapier : $($_.Exception.Message)"
        }
    }

    # 2. DEVMODE de référence en dernier : seul moyen d'appliquer les options
    #    propres au pilote Toshiba (impression intelligente, redimensionnement),
    #    et il écrit les deux niveaux, machine et utilisateur.
    if ($blobPresent) {
        try {
            Import-PrinterDevMode -PrinterName $NomFile -Path $blob
            Write-Succes "Réglages Toshiba de référence appliqués ($blob)"
        }
        catch {
            Write-Avertissement "Application du DEVMODE de référence impossible : $($_.Exception.Message)"
        }
    }
    else {
        Write-Avertissement "Aucun DEVMODE de référence pour « $NomPilote » ($blob). L'impression intelligente reste à régler à la main — voir Export-ReglagesToshiba.ps1."

        # Sans blob, les cmdlets n'ont écrit que le niveau machine : on aligne
        # les préférences de l'utilisateur, seules utilisées à l'impression.
        try {
            Sync-PrinterUserDefaults -PrinterName $NomFile
            Write-Succes "Préférences d'impression de l'utilisateur alignées sur les paramètres par défaut"
        }
        catch {
            Write-Avertissement "Impossible d'aligner les préférences d'impression de l'utilisateur : $($_.Exception.Message)"
        }
    }

    # 3. Contrôle : les deux jeux de réglages doivent être identiques.
    try {
        if (Test-PrinterDevModeCoherence -PrinterName $NomFile) {
            Write-Succes "Paramètres par défaut et préférences d'impression identiques"
        }
        else {
            Write-Avertissement "Les « Paramètres par défaut de l'impression » et les « Préférences d'impression » diffèrent encore pour « $NomFile »."
        }
    }
    catch {
        Write-Avertissement "Contrôle de cohérence des réglages impossible : $($_.Exception.Message)"
    }
}

function Set-ImprimanteParDefaut {
    param([string]$NomFile)

    # Sans cette clé, Windows réaffecte l'imprimante par défaut à la dernière utilisée.
    $cle = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'
    try {
        Set-ItemProperty -Path $cle -Name 'LegacyDefaultPrinterMode' -Value 1 -Type DWord -ErrorAction Stop
        Write-Info "Gestion automatique de l'imprimante par défaut désactivée"
    }
    catch {
        Write-Avertissement "Impossible de désactiver la gestion automatique de l'imprimante par défaut : $($_.Exception.Message)"
    }

    $filtre = "Name='{0}'" -f ($NomFile -replace "'", "\'")
    $imprimante = Get-CimInstance -ClassName Win32_Printer -Filter $filtre -ErrorAction SilentlyContinue
    if (-not $imprimante) {
        Write-Avertissement "Imprimante « $NomFile » introuvable via WMI : imprimante par défaut non affectée."
        return
    }

    Invoke-CimMethod -InputObject $imprimante -MethodName SetDefaultPrinter | Out-Null

    $defaut = Get-CimInstance -ClassName Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue
    if ($defaut -and $defaut.Name -eq $NomFile) {
        Write-Succes "« $NomFile » définie comme imprimante par défaut"
    }
    else {
        Write-Avertissement "L'imprimante par défaut n'a pas pu être vérifiée."
    }
}

function Test-ContexteUtilisateur {
    $sessionInteractive = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    $courant = "$env:USERDOMAIN\$env:USERNAME"

    if ($sessionInteractive -and $sessionInteractive -ne $courant) {
        Write-Avertissement "Le script tourne sous $courant alors que la session ouverte est $sessionInteractive. L'imprimante par défaut et les préférences utilisateur ont été appliquées à $courant : les réappliquer depuis la session de l'utilisateur, ou relancer le script sans changer de compte à l'élévation."
    }
}

# --------------------------------------------------------------------------
# Programme principal
# --------------------------------------------------------------------------

$codeSortie = 0
try {
    Write-Host ''
    Write-Host '  Installation d''un copieur TOSHIBA' -ForegroundColor White
    Write-Host '  ---------------------------------' -ForegroundColor DarkGray

    if (-not (Test-Administrateur)) {
        throw "Ce script doit être exécuté en tant qu'administrateur : lancez-le par son fichier .bat, ou faites un clic droit puis Exécuter en tant qu'administrateur."
    }

    . (Join-Path $script:RacineScript 'lib\Snmp.ps1')
    . (Join-Path $script:RacineScript 'lib\DevMode.ps1')

    Start-Journal

    Write-Etape 'Configuration'
    $configSources = Get-Configuration -NomFichier 'sources.json'
    $configModeles = Get-Configuration -NomFichier 'modeles.json'
    Write-Succes 'Fichiers de configuration chargés'

    Write-Etape 'Copieur'
    $adresse = Read-AdresseIP -Valeur $IP
    Test-Copieur -Adresse $adresse | Out-Null

    Write-Etape 'Détection du modèle'
    $detection = Resolve-Modele -Adresse $adresse

    Write-Etape 'Choix du pilote'
    $clePilote = Resolve-Pilote -ModeleCopieur $detection.Modele -DetectionSource $detection.Source `
        -ConfigModeles $configModeles -ConfigSources $configSources
    $definition = $configSources.pilotes.$clePilote
    if (-not $definition) { throw "Pilote inconnu dans sources.json : $clePilote" }
    Write-Succes "Pilote retenu : $($definition.nomPilote)"

    Write-Etape 'Récupération du pilote'
    $archive = Get-ArchivePilote -DefinitionPilote $definition -ConfigSources $configSources
    $dossierExtrait = Expand-ArchivePilote -CheminArchive $archive
    $inf = Resolve-CheminInf -DossierExtrait $dossierExtrait -DefinitionPilote $definition

    Write-Etape 'Installation du pilote'
    Install-PiloteImpression -CheminInf $inf -NomPilote $definition.nomPilote

    Write-Etape 'Port TCP/IP'
    $nomPort = Install-PortTcpIp -Adresse $adresse

    Write-Etape 'File d''impression'
    $nomFile = Install-FileImpression -NomBase "TOSHIBA $($detection.Modele)" -NomPort $nomPort -NomPilote $definition.nomPilote

    Write-Etape 'Réglages par défaut'
    Set-ReglagesImpression -NomFile $nomFile -NomPilote $definition.nomPilote

    if (-not $PasDeParDefaut) {
        Write-Etape 'Imprimante par défaut'
        Set-ImprimanteParDefaut -NomFile $nomFile
        Test-ContexteUtilisateur
    }

    Write-Etape 'Contrôle final'
    $file = Get-Printer -Name $nomFile -ErrorAction Stop
    $reglages = Get-PrintConfiguration -PrinterName $nomFile -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host "    Nom            : $($file.Name)"
    Write-Host "    Pilote         : $($file.DriverName)"
    Write-Host "    Port           : $($file.PortName) ($adresse)"
    if ($reglages) {
        Write-Host "    Couleur        : $($reglages.Color)"
        Write-Host "    Recto/verso    : $($reglages.DuplexingMode)"
    }
    $defaut = Get-CimInstance -ClassName Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue
    if ($defaut) { Write-Host "    Par défaut     : $($defaut.Name)" }

    if ($script:Avertissements.Count -gt 0) {
        Write-Host ''
        Write-Host "  $($script:Avertissements.Count) avertissement(s) :" -ForegroundColor Yellow
        foreach ($a in $script:Avertissements) { Write-Host "    - $a" -ForegroundColor Yellow }
    }

    Write-Host ''
    if (Confirm-Oui -Question '  Imprimer une page de test ?' -DefautOui $false) {
        $filtre = "Name='{0}'" -f ($nomFile -replace "'", "\'")
        $wmi = Get-CimInstance -ClassName Win32_Printer -Filter $filtre
        Invoke-CimMethod -InputObject $wmi -MethodName PrintTestPage | Out-Null
        Write-Succes 'Page de test envoyée'
    }

    Write-Host ''
    Write-Host "  Installation terminée." -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "  ECHEC : $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
    $codeSortie = 1
}
finally {
    Stop-Journal
    if (-not $NonInteractif) {
        Write-Host ''
        Read-Host '  Appuyez sur Entrée pour fermer' | Out-Null
    }
}

exit $codeSortie
