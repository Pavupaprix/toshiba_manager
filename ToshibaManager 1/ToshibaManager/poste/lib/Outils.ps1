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

function Get-Outil {
    param(
        [string]$BaseUrl,
        [string]$Fichier,
        [string]$Sha256,
        [string]$Destination
    )

    $url = '{0}/poste/outils/{1}' -f $BaseUrl.TrimEnd('/'), [uri]::EscapeDataString($Fichier)
    $cible = Join-Path $Destination $Fichier

    Ecrire '  Telechargement...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $cible -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop

    if ($Sha256) {
        $empreinte = (Get-FileHash -Path $cible -Algorithm SHA256).Hash
        if ($empreinte -ne $Sha256.ToUpper()) {
            Remove-Item $cible -Force -ErrorAction SilentlyContinue
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
                $proc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ErrorAction Stop `
                            -ArgumentList '/i', "`"$installeur`"", '/qn', '/norestart'
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
                if (Test-Path $cible) { Remove-Item $cible -Recurse -Force -ErrorAction SilentlyContinue }
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
    return "Echec ($code)"
}
