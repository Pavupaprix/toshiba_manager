<#
.SYNOPSIS
    Acces sans surveillance AnyDesk.

.DESCRIPTION
    Sequence reprise telle quelle d'une intervention client qui a fonctionne :
    le service doit tourner avant que --set-password soit accepte, et le mot de
    passe se transmet sur l'entree standard, jamais en argument de ligne de
    commande (il apparaitrait dans la liste des processus).
#>

function Set-AnyDeskMotDePasse {
    param([string]$MotDePasse)

    $exe = $null
    foreach ($chemin in @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe",
                          "$env:ProgramFiles\AnyDesk\AnyDesk.exe")) {
        if (Test-Path $chemin) { $exe = $chemin; break }
    }

    if (-not $exe) {
        Ecrire '  AnyDesk.exe introuvable : configuration ignoree.' 'Red'
        return 'Echec (exe introuvable)'
    }

    try {
        $service = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            Start-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        # Sortie redirigee : sans Out-Null, ce qu'AnyDesk ecrit sur sa sortie
        # standard partirait dans le pipeline et se retrouverait melange a la
        # valeur de retour de cette fonction.
        $MotDePasse | & $exe --set-password 2>&1 | Out-Null
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            Ecrire '  Acces sans surveillance configure.' 'Green'
            return 'Configure'
        }

        Ecrire ('  Echec de la configuration (code {0}).' -f $code) 'Red'
        Ecrire "  Selon la version d'AnyDesk, definir le mot de passe via l'interface." 'Yellow'
        return "Echec ($code)"
    } catch {
        Ecrire ('  Erreur : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec (config)'
    }
}
