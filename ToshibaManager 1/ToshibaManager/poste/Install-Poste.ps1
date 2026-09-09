<#
.SYNOPSIS
    Installe et configure un poste Windows a partir de config.json.

.DESCRIPTION
    Genere par ToshibaManager (page "Installer un poste"). Ne pas modifier a la
    main : regenerer le ZIP depuis la page.

    Le fichier config.json place a cote de ce script decrit tout ce qui a ete
    demande : applications, reglages Windows, comptes locaux, mots de passe.

.NOTES
    ATTENTION : config.json contient des mots de passe en clair. Le script
    propose de supprimer le dossier en fin d'execution -- repondre oui.

.EXAMPLE
    Installer-Poste.bat
#>

$ErrorActionPreference = 'Continue'

# --- Auto-elevation ---------------------------------------------------------
$identite = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identite)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation des privileges requise. Relance en administrateur..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' `
                      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"" `
                      -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "Elevation refusee. Relancez Installer-Poste.bat en tant qu'administrateur." -ForegroundColor Red
        exit 1
    }
    exit 0
}

$Racine = Split-Path -Parent $PSCommandPath
$FichierConfig = Join-Path $Racine 'config.json'

if (-not (Test-Path $FichierConfig)) {
    Write-Host "config.json introuvable dans $Racine" -ForegroundColor Red
    Read-Host 'Appuyez sur Entree pour fermer'
    exit 1
}

foreach ($module in 'Journal', 'Winget', 'Outils', 'Comptes', 'AnyDesk', 'Navigateur', 'Windows') {
    . (Join-Path $Racine "lib\$module.ps1")
}

try {
    $config = Get-Content -Path $FichierConfig -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "config.json illisible : $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Appuyez sur Entree pour fermer'
    exit 1
}

$journal = Initialize-Journal

# Tout ce qui suit peut se retrouver dans une ligne de journal : declare ici,
# une fois pour toutes, pour ne jamais atterrir sur disque en clair.
if ($config.anydesk) { Add-Secret $config.anydesk.motDePasse }
foreach ($compte in $config.comptes) { Add-Secret $compte.motDePasse }

$Travail = Join-Path $env:TEMP ('InstallationPoste_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Travail -Force | Out-Null

$redemarrageRequis = $false

Ecrire ''
Ecrire '  ============================================================' 'Cyan'
Ecrire '   Installation d''un poste Windows - OMB Informatique' 'Cyan'
Ecrire '  ============================================================' 'Cyan'
Ecrire ''
if ($config.client) { Ecrire ('  Client   : {0}' -f $config.client) }
if ($config.codeClient) { Ecrire ('  Code     : {0}' -f $config.codeClient) }
Ecrire ('  Genere   : {0}' -f $config.genereLe)
Ecrire ('  Journal  : {0}' -f $journal)
Ecrire ''


# ============================================================================
# 1 - Nettoyage
# ============================================================================
if ($config.windows.desinstaller -and $config.windows.desinstaller.Count -gt 0) {
    Ecrire-Titre 'Nettoyage'
    foreach ($motif in $config.windows.desinstaller) {
        Add-Resultat $motif (Remove-Logiciel -Motif $motif) 'desinstallation'
    }
}


# ============================================================================
# 2 - Applications
# ============================================================================
$viaWinget = @($config.applications | Where-Object { $_.source -eq 'winget' })
$viaOutil  = @($config.applications | Where-Object { $_.source -eq 'outil' })

# Les paquets longs passent en dernier. Microsoft 365 immobilise le script une
# demi-heure : place au milieu, il donne l'impression que tout est bloque alors
# que les paquets suivants auraient pris quelques secondes. Deux filtres plutot
# qu'un Sort-Object : en PowerShell 5.1 le tri n'est pas stable et melangerait
# l'ordre du catalogue, dont dependent les prerequis comme VCRedist.
$viaWinget = @($viaWinget | Where-Object { -not $_.lent }) +
             @($viaWinget | Where-Object { $_.lent })

if ($viaWinget.Count -gt 0) {
    Ecrire-Titre 'Applications (winget)'

    if (-not (Test-Winget)) {
        foreach ($app in $viaWinget) {
            Add-Resultat $app.nom 'Echec (winget absent)' $app.wingetId
        }
    } else {
        Ecrire "  winget affiche sa propre progression ci-dessous." 'DarkGray'
        Ecrire "  Le premier paquet est le plus long : winget met a jour son index." 'DarkGray'
        $index = 0
        foreach ($app in $viaWinget) {
            $index++
            Ecrire ''
            Ecrire ('[{0}/{1}] {2}' -f $index, $viaWinget.Count, $app.nom) 'Cyan'

            # Microsoft 365 n'est installe que s'il manque : jamais par-dessus
            # une edition deja en place, dont on ignore la licence.
            if ($app.siAbsent -eq 'office' -and (Test-OfficePresent)) {
                Ecrire '  Office deja present : installation ignoree.' 'Green'
                Add-Resultat $app.nom 'Deja present' $app.wingetId
                continue
            }

            if ($app.avertissement) { Ecrire ('  ' + $app.avertissement) 'Yellow' }

            $depart = Get-Date
            $statut = Install-AppWinget -Nom $app.nom -Id $app.wingetId `
                                        -SkipDeps:([bool]$app.skipDeps) -Lent:([bool]$app.lent)
            $duree = (Get-Date) - $depart
            if ($duree.TotalSeconds -ge 20) {
                Ecrire ('  Duree : {0:mm\:ss}' -f $duree) 'DarkGray'
            }
            Add-Resultat $app.nom $statut $app.wingetId
        }
    }
}

if ($viaOutil.Count -gt 0) {
    Ecrire-Titre 'Applications (installeurs OMB)'
    $index = 0
    foreach ($app in $viaOutil) {
        $index++
        Ecrire ''
        Ecrire ('[{0}/{1}] {2}' -f $index, $viaOutil.Count, $app.nom) 'Cyan'
        $statut = Install-Outil -App $app -BaseUrl $config.baseUrl -Travail $Travail
        Add-Resultat $app.nom $statut $app.fichier
        if ($statut -like '*redemarrage*') { $redemarrageRequis = $true }
    }
}


# ============================================================================
# 3 - AnyDesk
# ============================================================================
if ($config.anydesk) {
    Ecrire-Titre 'AnyDesk (acces sans surveillance)'
    Add-Resultat 'AnyDesk (sans surveillance)' (Set-AnyDeskMotDePasse -MotDePasse $config.anydesk.motDePasse) 'config'
}


# ============================================================================
# 4 - Reglages Windows
# ============================================================================
Ecrire-Titre 'Reglages Windows'
$reglages = Set-ReglagesWindows -Windows $config.windows
if ($reglages.Count -eq 0) {
    Ecrire '  Aucun reglage demande.'
} else {
    foreach ($cle in $reglages.Keys) {
        Add-Resultat $cle $reglages[$cle] 'reglage'
        if ($reglages[$cle] -like '*redemarrage*') { $redemarrageRequis = $true }
    }
}


# ============================================================================
# 5 - Navigateur par defaut
# ============================================================================
if ($config.navigateurParDefaut -eq 'chrome') {
    Ecrire-Titre 'Navigateur par defaut'
    Add-Resultat 'Chrome par defaut' (Set-ChromeParDefaut) 'config'
}


# ============================================================================
# 6 - Comptes locaux
# ============================================================================
# En dernier : les associations DISM et la ruche par defaut sont deja en place,
# donc chaque compte cree en herite a sa premiere ouverture de session.
if ($config.comptes -and $config.comptes.Count -gt 0) {
    Ecrire-Titre 'Comptes locaux'
    Ecrire ''
    try {
        $groupes = Get-GroupesLocaux
        foreach ($compte in $config.comptes) {
            $statut = Set-CompteLocal -Compte $compte -Groupes $groupes
            $role = if ($compte.admin) { 'Administrateur' } else { 'Utilisateur' }
            Add-Resultat ('Compte ' + $compte.nom) $statut $role
            Ecrire ''

            if ($compte.autologon -and $statut -ne 'Echec') {
                Add-Resultat ('Autologon ' + $compte.nom) `
                             (Set-Autologon -Nom $compte.nom -MotDePasse $compte.motDePasse) 'config'
            }
        }
    } catch {
        Ecrire ('  {0}' -f $_.Exception.Message) 'Red'
        Add-Resultat 'Comptes locaux' 'Echec' $_.Exception.Message
    }
}


# ============================================================================
# 7 - Renommage du poste
# ============================================================================
if ($config.poste.renommer -and $config.poste.nom) {
    Ecrire-Titre 'Nom du poste'
    $statut = Rename-Poste -Nom $config.poste.nom
    Add-Resultat 'Nom du poste' $statut $config.poste.nom
    if ($statut -like '*redemarrage*') { $redemarrageRequis = $true }
}


# ============================================================================
# Resume
# ============================================================================
Remove-Item $Travail -Recurse -Force -ErrorAction SilentlyContinue

$resultats = Get-Resultats

Ecrire-Titre 'Resume'
Ecrire ''
foreach ($r in $resultats) {
    $couleur = if ($r.Resultat -like 'Echec*') { 'Red' }
               elseif ($r.Resultat -like '*Manuel*') { 'Yellow' }
               else { 'Green' }
    Ecrire ('  {0,-34} {1}' -f $r.Element, $r.Resultat) $couleur
}
Ecrire ''

$echecs = @($resultats | Where-Object { $_.Resultat -like 'Echec*' })
if ($echecs.Count -gt 0) {
    Ecrire ('{0} element(s) en echec.' -f $echecs.Count) 'Red'
    Ecrire 'Un redemarrage puis une relance du script resout la plupart des cas.' 'Yellow'
    $codeSortie = 1
} else {
    Ecrire 'Tout est installe et configure.' 'Green'
    $codeSortie = 0
}

if ($redemarrageRequis) {
    Ecrire ''
    Ecrire 'REDEMARRAGE NECESSAIRE pour que tous les reglages prennent effet.' 'Yellow'
}

Ecrire ''
Ecrire ('Journal : {0}' -f $journal)
Ecrire ''


# ============================================================================
# Nettoyage
# ============================================================================
# config.json contient les mots de passe du client : le laisser sur le poste
# serait le vrai risque de cette procedure. Le journal, lui, est ailleurs et
# expurge, il survit dans les deux cas.
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host " Le dossier suivant contient les mots de passe du client :" -ForegroundColor Yellow
Write-Host ("   {0}" -f $Racine) -ForegroundColor Yellow
Write-Host ''
$reponse = Read-Host ' Tout supprimer maintenant ? (O/N)'

if ($reponse -match '^(o|oui|y|yes)$') {
    # Un script ne peut pas supprimer le dossier depuis lequel il s'execute :
    # la suppression est confiee a un processus detache qui attend sa sortie.
    Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden `
                  -ArgumentList '/c', 'timeout /t 3 /nobreak >nul & rd /s /q', ('"' + $Racine + '"')
    Write-Host ''
    Write-Host ' Suppression en cours, cette fenetre peut etre fermee.' -ForegroundColor Green
    Start-Sleep -Seconds 2
} else {
    Write-Host ''
    Write-Host ' Dossier conserve. Pensez a le supprimer avant de quitter le site.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host ' Appuyez sur Entree pour fermer'
}

exit $codeSortie
