<#
.SYNOPSIS
    Affichage a l'ecran et journalisation, avec expurgation des mots de passe.

.DESCRIPTION
    Le journal survit au nettoyage de fin d'execution : il ne doit donc contenir
    aucun secret. Toute valeur declaree via Add-Secret est remplacee par des
    asterisques avant l'ecriture sur disque, quelle que soit la ligne qui la
    contient.
#>

$script:Secrets = New-Object System.Collections.Generic.List[string]
$script:JournalFichier = $null
$script:Resultats = New-Object System.Collections.Generic.List[psobject]

function Initialize-Journal {
    $dossier = Join-Path $env:ProgramData 'OMB\InstallationPoste'
    New-Item -ItemType Directory -Path $dossier -Force -ErrorAction SilentlyContinue | Out-Null
    $script:JournalFichier = Join-Path $dossier ((Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.log')
    return $script:JournalFichier
}

function Add-Secret {
    param([string]$Valeur)
    # Les valeurs tres courtes seraient remplacees partout et rendraient le
    # journal illisible ; en pratique un mot de passe fait plus de 3 caracteres.
    if ($Valeur -and $Valeur.Length -ge 4 -and -not $script:Secrets.Contains($Valeur)) {
        $script:Secrets.Add($Valeur)
    }
}

function Protect-Ligne {
    param([string]$Ligne)
    foreach ($secret in $script:Secrets) {
        $Ligne = $Ligne.Replace($secret, '********')
    }
    return $Ligne
}

function Ecrire {
    param(
        [string]$Texte = '',
        [string]$Couleur = 'Gray'
    )
    Write-Host $Texte -ForegroundColor $Couleur
    if ($script:JournalFichier) {
        $ligne = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), (Protect-Ligne $Texte)
        Add-Content -Path $script:JournalFichier -Value $ligne -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Ecrire-Titre {
    param([string]$Texte)
    Ecrire ''
    Ecrire ('=== {0} ===' -f $Texte) 'Cyan'
}

function Add-Resultat {
    param(
        [string]$Element,
        [string]$Resultat,
        [string]$Detail = ''
    )
    $script:Resultats.Add([pscustomobject]@{
        Element  = $Element
        Resultat = $Resultat
        Detail   = $Detail
    })
}

function Get-Resultats {
    return $script:Resultats
}
