<#
.SYNOPSIS
    Chrome comme navigateur par defaut.

.DESCRIPTION
    Windows 10 et 11 protegent ce choix par une empreinte (UserChoice) que seule
    l'interface graphique sait calculer : aucune ecriture directe dans le
    registre ne tient. Deux approches complementaires, dans cet ordre :

      1. DISM /Import-DefaultAppAssociations, methode officielle Microsoft. Elle
         ne touche pas le profil courant mais s'applique a tous les profils
         crees ensuite -- donc aux comptes que ce script cree juste apres.
      2. SetUserFTA, s'il a ete depose a cote du script, pour le profil courant.
         Outil tiers non fourni : son auteur exige une licence pour un usage
         professionnel. Son absence n'est pas une erreur.

    En dernier recours, le chemin des Parametres est affiche pour un reglage a
    la main.
#>

function Set-ChromeParDefaut {
    param([string]$Travail)

    $chrome = $null
    foreach ($chemin in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                          "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
        if (Test-Path $chemin) { $chrome = $chemin; break }
    }
    if (-not $chrome) {
        Ecrire '  Chrome introuvable : association ignoree.' 'Red'
        return 'Echec (Chrome absent)'
    }

    $statuts = @()

    # --- 1. Profils a venir, via DISM ---------------------------------------
    try {
        $xml = @(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<DefaultAssociations>'
        )
        foreach ($ext in '.htm', '.html', '.shtml', '.xht', '.xhtml', '.svg', '.webp') {
            $xml += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $ext)
        }
        foreach ($proto in 'http', 'https', 'ftp') {
            $xml += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $proto)
        }
        $xml += '</DefaultAssociations>'

        $fichier = Join-Path $Travail 'associations-chrome.xml'
        [System.IO.File]::WriteAllLines($fichier, $xml, (New-Object System.Text.UTF8Encoding($false)))

        $proc = Start-Process -FilePath 'dism.exe' -Wait -PassThru -NoNewWindow -ErrorAction Stop `
                    -ArgumentList '/Online', '/Quiet', '/NoRestart', "/Import-DefaultAppAssociations:`"$fichier`""
        if ($proc.ExitCode -eq 0) {
            Ecrire '  Associations par defaut appliquees aux futurs profils.' 'Green'
            $statuts += 'futurs profils'
        } else {
            Ecrire ('  DISM a echoue (code {0}).' -f $proc.ExitCode) 'Yellow'
        }
    } catch {
        Ecrire ('  DISM a echoue : {0}' -f $_.Exception.Message) 'Yellow'
    }

    # --- 2. Profil courant, via SetUserFTA si present ------------------------
    $setUserFta = Join-Path $PSScriptRoot 'SetUserFTA.exe'
    if (Test-Path $setUserFta) {
        try {
            foreach ($cible in '.htm', '.html', 'http', 'https') {
                & $setUserFta $cible ChromeHTML | Out-Null
            }
            Ecrire '  Profil courant bascule sur Chrome (SetUserFTA).' 'Green'
            $statuts += 'profil courant'
        } catch {
            Ecrire ('  SetUserFTA a echoue : {0}' -f $_.Exception.Message) 'Yellow'
        }
    } else {
        Ecrire '  SetUserFTA absent : le profil courant reste a regler a la main.' 'Yellow'
        Ecrire '  Parametres > Applications > Applications par defaut > Google Chrome.' 'Yellow'
    }

    if ($statuts.Count -eq 0) { return 'Echec' }
    return 'Configure (' + ($statuts -join ', ') + ')'
}
