<#
.SYNOPSIS
    Chrome comme navigateur par defaut.

.DESCRIPTION
    Windows 10 et 11 protegent ce choix par une empreinte (UserChoice) que seule
    l'interface graphique sait calculer : aucune ecriture directe dans le
    registre ne tient. Trois mecanismes sont donc empiles, du plus large au plus
    etroit.

      1. La strategie DefaultAssociationsConfiguration. Windows relit le fichier
         d'associations a CHAQUE ouverture de session et applique ce qu'il
         contient, y compris aux comptes deja existants. C'est le seul moyen
         supporte par Microsoft d'agir sur un profil deja cree. Les editions
         Famille peuvent l'ignorer.

      2. DISM /Import-DefaultAppAssociations, qui garnit le profil par defaut :
         il ne touche pas les comptes existants, mais fonctionne sur toutes les
         editions pour les comptes crees ensuite -- dont ceux que ce script
         cree juste apres.

      3. SetUserFTA, s'il a ete depose a cote du script, seul a pouvoir basculer
         la session en cours sans deconnexion. Outil tiers non fourni : son
         auteur exige une licence pour un usage professionnel. Son absence
         n'est pas une erreur.

    Aucun des deux premiers ne prend effet dans la session ouverte : le
    changement se voit a la prochaine ouverture de session.
#>

function Set-ChromeParDefaut {

    $chrome = $null
    foreach ($chemin in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                          "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
        if (Test-Path $chemin) { $chrome = $chemin; break }
    }
    if (-not $chrome) {
        Ecrire '  Chrome introuvable : association ignoree.' 'Red'
        return 'Echec (Chrome absent)'
    }

    # Le fichier est relu a chaque ouverture de session : il doit rester sur le
    # poste, pas dans un dossier temporaire efface en fin d'execution.
    $dossier = Join-Path $env:ProgramData 'OMB'
    New-Item -ItemType Directory -Path $dossier -Force -ErrorAction SilentlyContinue | Out-Null
    $fichier = Join-Path $dossier 'associations-omb.xml'

    $xml = @(
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<DefaultAssociations>'
    )
    # .pdf est volontairement absent : Acrobat ou Foxit doivent garder cette
    # extension, alors que Chrome la revendiquerait aussi.
    foreach ($ext in '.htm', '.html', '.shtml', '.xht', '.xhtml', '.svg', '.webp') {
        $xml += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $ext)
    }
    foreach ($proto in 'http', 'https', 'ftp') {
        $xml += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $proto)
    }
    $xml += '</DefaultAssociations>'

    try {
        [System.IO.File]::WriteAllLines($fichier, $xml, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Ecrire ('  Impossible d''ecrire {0} : {1}' -f $fichier, $_.Exception.Message) 'Red'
        return 'Echec (fichier)'
    }

    $statuts = @()

    # --- 1. Strategie appliquee a chaque ouverture de session ----------------
    try {
        $cle = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        if (-not (Test-Path $cle)) { New-Item -Path $cle -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $cle -Name 'DefaultAssociationsConfiguration' `
                         -Value $fichier -Type String -ErrorAction Stop
        Ecrire '  Strategie d''associations posee (tous les comptes).' 'Green'
        $statuts += 'tous les comptes'
    } catch {
        Ecrire ('  Strategie non posee : {0}' -f $_.Exception.Message) 'Yellow'
    }

    # --- 2. Profil par defaut, via DISM --------------------------------------
    try {
        $proc = Start-Process -FilePath 'dism.exe' -Wait -PassThru -NoNewWindow -ErrorAction Stop `
                    -ArgumentList '/Online', '/Quiet', '/NoRestart', "/Import-DefaultAppAssociations:`"$fichier`""
        if ($proc.ExitCode -eq 0) {
            Ecrire '  Profil par defaut garni (comptes crees ensuite).' 'Green'
            $statuts += 'nouveaux comptes'
        } else {
            Ecrire ('  DISM a echoue (code {0}).' -f $proc.ExitCode) 'Yellow'
        }
    } catch {
        Ecrire ('  DISM a echoue : {0}' -f $_.Exception.Message) 'Yellow'
    }

    # --- 3. Session en cours, via SetUserFTA si present ----------------------
    $setUserFta = Join-Path $PSScriptRoot 'SetUserFTA.exe'
    if (Test-Path $setUserFta) {
        try {
            foreach ($cible in '.htm', '.html', 'http', 'https') {
                & $setUserFta $cible ChromeHTML 2>&1 | Out-Null
            }
            Ecrire '  Session en cours basculee sur Chrome.' 'Green'
            $statuts += 'session en cours'
        } catch {
            Ecrire ('  SetUserFTA a echoue : {0}' -f $_.Exception.Message) 'Yellow'
        }
    } else {
        Ecrire '  La session ouverte garde son navigateur jusqu''a la prochaine' 'Yellow'
        Ecrire '  ouverture de session. C''est normal : Windows verrouille ce' 'Yellow'
        Ecrire '  reglage pour la session en cours.' 'Yellow'
    }

    if ($statuts.Count -eq 0) { return 'Echec' }
    return 'Configure (' + ($statuts -join ', ') + ')'
}
