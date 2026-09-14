<#
.SYNOPSIS
    Installation ou reetiquetage de l'agent GLPI.

.DESCRIPTION
    L'agent ne se traite pas comme les autres installeurs, parce qu'un poste
    l'a souvent deja : prepare a l'atelier puis reetiquete au nom du client,
    c'est le flux normal et non un cas limite.

    Or msiexec /i par-dessus une installation existante echoue -- releve en
    clientele : code 1603, precede dans le journal MSI d'une erreur 1316 a
    l'action PublishProduct. Trois etats sont donc distingues :

      1. Agent absent            -> installation classique par le MSI.
      2. Agent present et sain   -> on reecrit seulement SERVER et TAG dans sa
                                    configuration, puis on relance le service.
                                    Quelques secondes, contre plusieurs minutes
                                    pour une desinstallation suivie d'une
                                    reinstallation, et pour un resultat
                                    identique.
      3. Agent enregistre mais casse (fichiers presents, service absent, comme
         apres une annulation d'installation qui a elle-meme echoue)
                                 -> desinstallation par ProductCode, puis
                                    installation propre.

    La configuration de l'agent vit dans HKLM\SOFTWARE\GLPI-Agent : c'est la
    que le MSI ecrit SERVER et TAG, et donc la qu'il faut les corriger.
#>

$script:GLPI_CLE = 'HKLM:\SOFTWARE\GLPI-Agent'
$script:GLPI_SERVICE = 'glpi-agent'

function Get-EtatAgentGlpi {
    <#
        Renvoie 'absent', 'sain' ou 'casse', et le ProductCode si le produit est
        enregistre.
    #>
    $cles = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $produit = Get-ItemProperty $cles -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -match '^GLPI Agent' } |
               Select-Object -First 1

    $service = Get-Service -Name $script:GLPI_SERVICE -ErrorAction SilentlyContinue
    $config = Get-ItemProperty -Path $script:GLPI_CLE -ErrorAction SilentlyContinue

    if (-not $produit -and -not $service) {
        return @{ Etat = 'absent'; ProductCode = $null; Version = $null }
    }

    # Le produit est enregistre : sans service ni configuration, l'installation
    # n'est pas allee au bout.
    $etat = if ($service -and $config) { 'sain' } else { 'casse' }
    return @{
        Etat        = $etat
        ProductCode = $produit.PSChildName
        Version     = $produit.DisplayVersion
    }
}

function Set-ConfigurationAgentGlpi {
    <#
        Reecrit SERVER et TAG, puis relance le service pour qu'il les relise.
    #>
    param([psobject]$Proprietes)

    $serveur = $Proprietes.SERVER
    $tag = $Proprietes.TAG

    if (-not (Test-Path $script:GLPI_CLE)) {
        New-Item -Path $script:GLPI_CLE -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $script:GLPI_CLE -Name 'server' -Value $serveur -ErrorAction Stop
    Set-ItemProperty -Path $script:GLPI_CLE -Name 'tag' -Value $tag -ErrorAction Stop

    $relu = Get-ItemProperty -Path $script:GLPI_CLE -ErrorAction SilentlyContinue
    if ($relu.tag -ne $tag) {
        throw "Le TAG n'a pas ete enregistre (lu : $($relu.tag))."
    }

    Ecrire ('  TAG : {0}' -f $tag) 'Green'
    Ecrire ('  Serveur : {0}' -f $serveur) 'Green'

    try {
        Restart-Service -Name $script:GLPI_SERVICE -Force -ErrorAction Stop
        Ecrire '  Service relance.' 'Green'
    } catch {
        Ecrire ('  Service non relance : {0}' -f $_.Exception.Message) 'Yellow'
    }

    # Un inventaire immediat evite d'attendre la prochaine echeance pour que le
    # poste remonte sous sa nouvelle entite.
    $exe = Join-Path $env:ProgramFiles 'GLPI-Agent\glpi-agent.bat'
    if (Test-Path -LiteralPath $exe) {
        try {
            Start-Process -FilePath $exe -ArgumentList '--force' `
                          -Wait -NoNewWindow -ErrorAction Stop
            Ecrire '  Inventaire envoye.' 'Green'
        } catch {
            Ecrire '  Inventaire immediat impossible : il partira a la prochaine echeance.' 'Yellow'
        }
    }
}

function Remove-AgentGlpi {
    param([string]$ProductCode, [string]$Travail)

    if (-not $ProductCode) { return $false }

    $journal = Join-Path $Travail 'msi-glpiagent-desinstallation.log'
    Ecrire '  Retrait de l installation precedente...' 'Yellow'
    $proc = Start-Process -FilePath 'msiexec.exe' -PassThru -ErrorAction Stop `
                -ArgumentList @('/x', $ProductCode, '/quiet', '/norestart', '/l*v', "`"$journal`"")
    $null = $proc.Handle

    # La desinstallation prend plusieurs minutes -- pres de 5000 fichiers a
    # retirer -- sans rien afficher. Le compteur evite de la croire figee.
    $debut = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 5
        Write-Host ("`r    retrait en cours depuis {0:mm\:ss}    " -f ((Get-Date) - $debut)) `
                   -NoNewline -ForegroundColor DarkGray
    }
    Write-Host "`r                                                    " -NoNewline
    Write-Host ''

    if ($proc.ExitCode -eq 0) {
        Ecrire '  Installation precedente retiree.' 'Green'
        return $true
    }
    Ecrire ('  Retrait en echec (code {0}).' -f $proc.ExitCode) 'Red'
    return $false
}

function Install-AgentGlpi {
    param(
        [psobject]$App,
        [string]$BaseUrl,
        [string]$Travail
    )

    $etat = Get-EtatAgentGlpi

    if ($etat.Etat -eq 'sain') {
        Ecrire ('  Agent deja installe (version {0}) : mise a jour de son etiquetage.' -f $etat.Version)
        try {
            Set-ConfigurationAgentGlpi -Proprietes $App.proprietes
            return 'Reetiquete'
        } catch {
            Ecrire ('  Echec : {0}' -f $_.Exception.Message) 'Red'
            return 'Echec (reetiquetage)'
        }
    }

    if ($etat.Etat -eq 'casse') {
        Ecrire '  Agent enregistre mais incomplet : service ou configuration absents.' 'Yellow'
        if (-not (Remove-AgentGlpi -ProductCode $etat.ProductCode -Travail $Travail)) {
            return 'Echec (retrait impossible)'
        }
    }

    return Install-Outil -App $App -BaseUrl $BaseUrl -Travail $Travail
}
