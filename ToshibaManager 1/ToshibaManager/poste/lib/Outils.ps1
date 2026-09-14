<#
.SYNOPSIS
    Installeurs specifiques heberges par le serveur (Kudu, CrystalDiskInfo...).

.DESCRIPTION
    Ces binaires ne sont pas dans le ZIP : ils pesent 150 Mo et ne sont pas des
    secrets. Le poste les recupere sur /poste/outils/<fichier>.

    L'empreinte SHA-256 est verifiee avant toute execution. C'est le seul
    controle qui distingue le fichier attendu de ce qu'un intermediaire aurait
    pu substituer : un fichier dont l'empreinte ne correspond pas n'est jamais
    lance.
#>

function Remove-Dossier {
    <#
        Supprime un dossier et tout son contenu, sans jamais rien afficher.

        [IO.Directory]::Delete plutot que Remove-Item : sur un poste client,
        Remove-Item -Recurse -Force a leve une PSArgumentException que meme
        -ErrorAction SilentlyContinue ne masquait pas, en nommant un chemin
        tronque au profil. La cause n'a pas pu etre reproduite ailleurs ;
        l'appel .NET ne passe pas par le fournisseur PowerShell et n'a pas ce
        comportement. Le chemin est journalise en cas d'echec, pour qu'une
        recidive soit diagnosticable.
    #>
    param([string]$Chemin)

    if (-not $Chemin) { return }
    try {
        if ([System.IO.Directory]::Exists($Chemin)) {
            [System.IO.Directory]::Delete($Chemin, $true)
        }
    } catch {
        Ecrire ('  Dossier temporaire conserve ({0}) : {1}' -f $Chemin, $_.Exception.Message) 'DarkGray'
    }
}

function Get-Outil {
    param(
        [string]$BaseUrl,
        [string]$Fichier,
        [string]$Sha256,
        [string]$Destination
    )

    $url = '{0}/poste/outils/{1}' -f $BaseUrl.TrimEnd('/'), [uri]::EscapeDataString($Fichier)
    $cible = Join-Path $Destination $Fichier

    Ecrire ('  Telechargement de {0}...' -f $Fichier)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # La barre de progression d'Invoke-WebRequest divise le debit par dix sous
    # PowerShell 5.1 : sur les 113 Mo de Kudu, la difference se compte en
    # minutes. On l'eteint et on affiche la duree reelle a la place.
    $progressionAvant = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $depart = Get-Date
    try {
        Invoke-WebRequest -Uri $url -OutFile $cible -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
    } finally {
        $ProgressPreference = $progressionAvant
    }

    $taille = (Get-Item $cible).Length / 1MB
    $duree = (Get-Date) - $depart
    Ecrire ('  {0:N0} Mo recus en {1:mm\:ss}.' -f $taille, $duree)

    if ($Sha256) {
        $empreinte = (Get-FileHash -Path $cible -Algorithm SHA256).Hash
        if ($empreinte -ne $Sha256.ToUpper()) {
            Remove-Item -LiteralPath $cible -Force -ErrorAction SilentlyContinue
            throw "Empreinte SHA-256 incorrecte pour $Fichier (attendu $Sha256, obtenu $empreinte)."
        }
    }

    return $cible
}

function Install-Outil {
    param(
        [psobject]$App,
        [string]$BaseUrl,
        [string]$Travail
    )

    try {
        $installeur = Get-Outil -BaseUrl $BaseUrl -Fichier $App.fichier `
                                -Sha256 $App.sha256 -Destination $Travail
    } catch {
        Ecrire ('  Echec du telechargement : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (telechargement)'
    }

    Ecrire '  Installation en cours...'
    $journalMsi = $null

    try {
        switch ($App.type) {
            'inno' {
                # Inno Setup : ces trois commutateurs sont les seuls a garantir
                # qu'aucune fenetre n'attend une reponse.
                $proc = Start-Process -FilePath $installeur -Wait -PassThru -ErrorAction Stop `
                            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
                $code = $proc.ExitCode
            }
            'nsis' {
                $proc = Start-Process -FilePath $installeur -Wait -PassThru -ErrorAction Stop `
                            -ArgumentList '/S'
                $code = $proc.ExitCode
            }
            'msi' {
                # Journal detaille systematique : msiexec ne renvoie que des
                # codes opaques -- 1603 signifie "erreur fatale" et rien de
                # plus. Sans ce journal la cause reelle est perdue, et elle ne
                # se reproduit pas forcement sur un autre poste.
                $journalMsi = Join-Path $Travail ('msi-' + $App.id + '.log')
                $arguments = @('/i', "`"$installeur`"", '/quiet', '/norestart',
                               '/l*v', "`"$journalMsi`"")

                # Proprietes MSI passees en ligne de commande : c'est la
                # methode documentee par Teclib pour l'agent GLPI, et elle
                # evite d'avoir a reecrire le MSI. Chaque valeur est mise entre
                # guillemets : un TAG comme "ATELIER de la VIREOrdinateurs"
                # serait sinon tronque au premier espace, et le poste
                # remonterait dans la mauvaise entite sans le moindre message.
                if ($App.proprietes) {
                    foreach ($propriete in $App.proprietes.PSObject.Properties) {
                        $arguments += ('{0}="{1}"' -f $propriete.Name, $propriete.Value)
                    }
                }

                $proc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ErrorAction Stop `
                            -ArgumentList $arguments
                $code = $proc.ExitCode
            }
            'exe' {
                $arguments = @()
                if ($App.arguments) { $arguments = $App.arguments -split ' ' }
                $proc = Start-Process -FilePath $installeur -Wait -PassThru -ErrorAction Stop `
                            -ArgumentList $arguments
                $code = $proc.ExitCode
            }
            'zip' {
                # Outil portable : on l'extrait sous Program Files et on pose un
                # raccourci, sinon il resterait introuvable pour l'utilisateur.
                $cible = Join-Path $env:ProgramFiles ('OMB\' + $App.dossierCible)
                Remove-Dossier $cible
                New-Item -ItemType Directory -Path $cible -Force | Out-Null
                Expand-Archive -LiteralPath $installeur -DestinationPath $cible -Force -ErrorAction Stop

                $exe = Get-ChildItem -Path $cible -Filter $App.executable -Recurse -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($exe) {
                    $raccourci = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) ($App.nom + '.lnk')
                    $shell = New-Object -ComObject WScript.Shell
                    $lien = $shell.CreateShortcut($raccourci)
                    $lien.TargetPath = $exe.FullName
                    $lien.WorkingDirectory = $exe.DirectoryName
                    $lien.Save()
                } else {
                    Ecrire ('  Archive extraite mais {0} introuvable : pas de raccourci.' -f $App.executable) 'Yellow'
                }
                $code = 0
            }
            default {
                Ecrire ('  Type d''installeur inconnu : {0}' -f $App.type) 'Red'
                return 'Echec (type inconnu)'
            }
        }
    } catch {
        Ecrire ('  Echec : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (installation)'
    }

    if ($code -eq 0) {
        Ecrire '  Installe.' 'Green'
        return 'Installe'
    }

    # 3010 = installe, redemarrage requis. C'est un succes cote MSI.
    if ($code -eq 3010) {
        Ecrire '  Installe (redemarrage requis).' 'Green'
        return 'Installe (redemarrage requis)'
    }

    Ecrire ("  Echec de l'installation (code {0})." -f $code) 'Red'
    if ($journalMsi) { Show-EchecMsi -Journal $journalMsi -Id $App.id }
    return "Echec ($code)"
}

function Show-EchecMsi {
    <#
        Extrait du journal msiexec ce qui explique l'echec, et le conserve a
        cote du journal d'installation.

        Un journal MSI fait des milliers de lignes ; deux motifs suffisent
        presque toujours : la ligne "Return value 3" marque l'action qui a
        echoue, et les lignes "Error" en donnent la raison.
    #>
    param(
        [string]$Journal,
        [string]$Id
    )

    if (-not (Test-Path -LiteralPath $Journal)) {
        Ecrire '  Aucun journal msiexec produit.' 'Yellow'
        return
    }

    # Conserve avant tout : le dossier de travail est efface en fin de script.
    $dossier = Join-Path $env:ProgramData 'OMB\InstallationPoste'
    $garde = Join-Path $dossier ('msi-{0}-{1}.log' -f $Id, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    Copy-Item -LiteralPath $Journal -Destination $garde -Force -ErrorAction SilentlyContinue

    $lignes = @(Select-String -LiteralPath $Journal -Pattern 'Return value 3', '^MSI \(s\).*: Error', 'Product: .* -- Error' -ErrorAction SilentlyContinue |
                Select-Object -Last 6 -ExpandProperty Line)

    if ($lignes.Count -gt 0) {
        Ecrire '  Extrait du journal msiexec :' 'Yellow'
        foreach ($ligne in $lignes) {
            Ecrire ('    ' + $ligne.Trim()) 'DarkGray'
        }
    }
    Ecrire ('  Journal complet conserve : {0}' -f $garde) 'Yellow'
}
