<#
.SYNOPSIS
    Installation de Microsoft 365 par l'outil de deploiement Office (ODT).

.DESCRIPTION
    winget ne convient pas pour Office. Son paquet Microsoft.Office telecharge
    le lanceur setup.exe depuis le CDN Microsoft puis verifie son empreinte
    contre le catalogue communautaire. Microsoft remplace ce fichier sans que
    le catalogue suive, l'empreinte ne correspond plus, et winget refuse de
    passer outre en session administrateur -- c'est volontaire de sa part.
    Releve en clientele : code -1978335215, installation impossible.

    L'ODT est la methode que Microsoft prevoit pour un deploiement. Le meme
    setup.exe, mais heberge par nos soins dans outils/ : c'est alors notre
    empreinte qui fait foi, et elle ne bouge que quand nous decidons de mettre
    le fichier a jour.

    setup.exe ne sait rien faire seul : il lit un configuration.xml. Celui-ci
    est ecrit a la volee dans le dossier de travail, a partir de l'edition
    choisie sur la page et des exclusions declarees au catalogue. L'edition
    compte : installer Apps for enterprise sous une licence Business donne un
    Office qui s'installe mais ne s'active jamais.
#>

# Editions acceptees. La page valide deja le choix, mais config.json est un
# fichier texte pose a cote du script : il peut avoir ete modifie a la main, et
# un Product ID inconnu ferait echouer setup.exe sur un code opaque.
$script:OFFICE_EDITIONS = @('O365BusinessRetail', 'O365ProPlusRetail')

$script:OFFICE_EDITION_DEFAUT = 'O365BusinessRetail'

# Au-dela, on cesse d'attendre et on le dit. Office telecharge plusieurs Go.
$script:OFFICE_DELAI = 90

function New-ConfigurationOffice {
    <#
        Ecrit le configuration.xml et renvoie son chemin.

        Display Level="None" est ce qui rend l'installation silencieuse ;
        AcceptEULA evite la seule invite qui resterait. Le journal est dirige
        vers le dossier de travail pour etre conserve en cas d'echec, comme
        pour les installeurs MSI.
    #>
    param(
        [psobject]$Office,
        [string]$Travail
    )

    $edition = $script:OFFICE_EDITION_DEFAUT
    if ($Office -and $Office.edition -and
        ($script:OFFICE_EDITIONS -contains $Office.edition)) {
        $edition = $Office.edition
    } elseif ($Office -and $Office.edition) {
        Ecrire ("  Edition inconnue ({0}) : on retient {1}." -f $Office.edition, $edition) 'Yellow'
    }

    $langue = 'fr-fr'
    if ($Office -and $Office.langue) { $langue = $Office.langue }

    $canal = 'Current'
    if ($Office -and $Office.canal) { $canal = $Office.canal }

    $exclusions = @()
    if ($Office -and $Office.exclusions) { $exclusions = @($Office.exclusions) }

    $lignes = New-Object System.Collections.Generic.List[string]
    $lignes.Add('<Configuration>')
    $lignes.Add(('  <Add OfficeClientEdition="64" Channel="{0}">' -f $canal))
    $lignes.Add(('    <Product ID="{0}">' -f $edition))
    $lignes.Add(('      <Language ID="{0}" />' -f $langue))
    foreach ($app in $exclusions) {
        if ($app) { $lignes.Add(('      <ExcludeApp ID="{0}" />' -f $app)) }
    }
    $lignes.Add('    </Product>')
    $lignes.Add('  </Add>')
    $lignes.Add('  <Display Level="None" AcceptEULA="TRUE" />')
    $lignes.Add(('  <Logging Level="Standard" Path="{0}" />' -f $Travail))
    $lignes.Add('</Configuration>')

    $chemin = Join-Path $Travail 'configuration-office.xml'
    [System.IO.File]::WriteAllLines($chemin, $lignes, (New-Object System.Text.UTF8Encoding($false)))

    Ecrire ('  Edition : {0}' -f $edition)
    if ($exclusions.Count -gt 0) {
        Ecrire ('  Exclues : {0}' -f ($exclusions -join ', '))
    }
    return $chemin
}

function Show-EchecOffice {
    <#
        Traduit les codes de l'ODT, qui n'evoquent rien tels quels, et conserve
        les journaux hors du dossier de travail -- efface en fin de script.
    #>
    param(
        [int]$Code,
        [string]$Travail
    )

    switch ($Code) {
        17002 { Ecrire "  L'installation a ete interrompue avant la fin." 'Yellow' }
        17004 { Ecrire '  Edition inconnue de Microsoft : verifiez le choix fait sur la page.' 'Yellow' }
        30015 { Ecrire '  Telechargement impossible : verifiez la connexion vers Microsoft.' 'Yellow' }
        30125 { Ecrire '  Telechargement interrompu : connexion instable ou filtrage reseau.' 'Yellow' }
        default { }
    }

    $journaux = @(Get-ChildItem -Path $Travail -Filter '*.log' -ErrorAction SilentlyContinue)
    if ($journaux.Count -eq 0) { return }

    $dossier = Join-Path $env:ProgramData 'OMB\InstallationPoste'
    New-Item -ItemType Directory -Path $dossier -Force -ErrorAction SilentlyContinue | Out-Null
    $horodatage = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    foreach ($j in $journaux) {
        $garde = Join-Path $dossier ('office-{0}-{1}' -f $horodatage, $j.Name)
        Copy-Item -LiteralPath $j.FullName -Destination $garde -Force -ErrorAction SilentlyContinue
    }
    Ecrire ('  Journaux conserves dans {0}' -f $dossier) 'Yellow'
}

function Install-Office {
    <#
        Telecharge l'ODT, ecrit sa configuration, et lance l'installation.
    #>
    param(
        [psobject]$App,
        [psobject]$Office,
        [string]$BaseUrl,
        [string]$Travail
    )

    try {
        $setup = Get-Outil -BaseUrl $BaseUrl -Fichier $App.fichier `
                           -Sha256 $App.sha256 -Destination $Travail
    } catch {
        Ecrire ('  Echec du telechargement : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (telechargement)'
    }

    try {
        $xml = New-ConfigurationOffice -Office $Office -Travail $Travail
    } catch {
        Ecrire ('  Configuration illisible : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (configuration)'
    }

    # Office n'est pas un MSI, mais il en pose : la meme attente evite qu'il
    # bute sur une transaction Windows Update en cours.
    Wait-InstallateurMsi | Out-Null

    Ecrire '  Installation en cours, plusieurs dizaines de minutes possibles...'
    try {
        $proc = Start-Process -FilePath $setup -PassThru -NoNewWindow -ErrorAction Stop `
                    -ArgumentList '/configure', "`"$xml`""
        $null = $proc.Handle
    } catch {
        Ecrire ('  Lancement impossible : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (lancement)'
    }

    # setup.exe n'affiche rien avec Display Level="None" : sans compteur, rien
    # ne distingue un telechargement de plusieurs Go d'un blocage.
    $debut = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 5
        $ecoule = (Get-Date) - $debut
        if ($ecoule.TotalMinutes -ge $script:OFFICE_DELAI) { break }
        Write-Host ("`r    installation en cours depuis {0:mm\:ss}    " -f $ecoule) `
                   -NoNewline -ForegroundColor DarkGray
    }
    Write-Host "`r                                                            " -NoNewline
    Write-Host ''

    if (-not $proc.HasExited) {
        Ecrire ('  Toujours en cours apres {0} minutes : l''installation se poursuit en arriere-plan.' -f $script:OFFICE_DELAI) 'Yellow'
        return 'En cours (arriere-plan)'
    }

    $code = $proc.ExitCode
    if ($code -eq 0) {
        Ecrire '  Installe.' 'Green'
        return 'Installe'
    }

    Ecrire ("  Echec de l'installation (code {0})." -f $code) 'Red'
    Show-EchecOffice -Code $code -Travail $Travail
    return "Echec ($code)"
}
