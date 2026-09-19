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

function Disable-SelectionRapide {
    <#
        Desactive le mode "selection rapide" de la console.

        Un clic dans la fenetre -- meme celui qui la met simplement au premier
        plan -- y fait passer Windows en mode selection. Le processus se bloque
        alors des sa premiere ecriture sur la sortie, et rien ne l'annonce : la
        console parait figee. Une frappe la libere et tout s'affiche d'un coup.

        Sur une installation qui dure vingt minutes, ce gel passe pour un
        plantage et le technicien coupe -- releve pendant les essais sur VM. Le
        confort de selectionner du texte a la souris ne vaut pas ce risque ; la
        selection reste accessible par le menu de la fenetre.
    #>
    $signature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@

    # Sans console reelle -- sortie redirigee, ISE, execution automatisee --
    # il n'y a rien a desactiver, et l'echec est alors sans consequence.
    try {
        $api = Add-Type -MemberDefinition $signature -Name 'ConsoleOmb' `
                        -Namespace 'Omb' -PassThru -ErrorAction Stop
        $entree = $api::GetStdHandle(-10)   # STD_INPUT_HANDLE
        $mode = [uint32]0
        if (-not $api::GetConsoleMode($entree, [ref]$mode)) { return }

        $SELECTION_RAPIDE = [uint32]0x0040
        # ENABLE_EXTENDED_FLAGS doit accompagner tout changement de ce bit,
        # sinon Windows ignore purement et simplement la demande.
        $DRAPEAUX_ETENDUS = [uint32]0x0080

        $nouveau = ($mode -band (-bnot $SELECTION_RAPIDE)) -bor $DRAPEAUX_ETENDUS
        $api::SetConsoleMode($entree, $nouveau) | Out-Null
    } catch {
        return
    }
}

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
