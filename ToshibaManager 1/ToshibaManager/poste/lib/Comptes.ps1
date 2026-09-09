<#
.SYNOPSIS
    Creation et mise a jour des comptes locaux, et ouverture de session
    automatique.

.DESCRIPTION
    Les groupes sont resolus par SID et non par nom : sur un Windows anglais le
    groupe s'appelle "Administrators", sur un Windows francais
    "Administrateurs". Le SID, lui, ne change pas.

    Un compte deja present n'est pas recree : son mot de passe est reinitialise
    et son appartenance corrigee, ce qui rend le script rejouable sur un poste
    deja traite.
#>

function Get-GroupesLocaux {
    $admins = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue
    $users  = Get-LocalGroup -SID 'S-1-5-32-545' -ErrorAction SilentlyContinue
    if (-not $admins -or -not $users) {
        throw 'Groupes locaux Administrateurs/Utilisateurs introuvables.'
    }
    return @{ Admins = $admins; Users = $users }
}

function Set-CompteLocal {
    param(
        [psobject]$Compte,
        [hashtable]$Groupes
    )

    $nom = $Compte.nom
    $groupeCible = if ($Compte.admin) { $Groupes.Admins } else { $Groupes.Users }
    $role = if ($Compte.admin) { 'Administrateur' } else { 'Utilisateur' }

    Ecrire ('- {0} ({1})' -f $nom, $role) 'Cyan'

    try {
        $existant = Get-LocalUser -Name $nom -ErrorAction SilentlyContinue
        $avecMotDePasse = -not [string]::IsNullOrEmpty($Compte.motDePasse)

        if ($avecMotDePasse) {
            $securise = ConvertTo-SecureString $Compte.motDePasse -AsPlainText -Force
        }

        if ($existant) {
            if ($avecMotDePasse) {
                Set-LocalUser -Name $nom -Password $securise -ErrorAction Stop
            } else {
                # Set-LocalUser refuse un mot de passe nul : son parametre
                # -Password n'accepte pas $null. "net user <nom> """ est la
                # seule facon de retirer le mot de passe d'un compte existant.
                $sortie = & net.exe user $nom '""' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw ("Retrait du mot de passe refuse : {0}" -f ($sortie -join ' '))
                }
            }
            Set-LocalUser -Name $nom -PasswordNeverExpires $Compte.motDePasseNExpireJamais -ErrorAction SilentlyContinue
            Enable-LocalUser -Name $nom -ErrorAction SilentlyContinue
            Ecrire '  Deja present : mot de passe et parametres mis a jour.'
            $statut = 'Mis a jour'
        } else {
            $parametres = @{
                Name               = $nom
                FullName           = $nom
                Description        = "Compte $role - OMB"
                AccountNeverExpires = $true
                ErrorAction        = 'Stop'
            }
            if ($avecMotDePasse) {
                $parametres['Password'] = $securise
                $parametres['PasswordNeverExpires'] = [bool]$Compte.motDePasseNExpireJamais
            } else {
                $parametres['NoPassword'] = $true
            }
            New-LocalUser @parametres | Out-Null
            Ecrire '  Cree.'
            $statut = 'Cree'
        }

        $membre = Get-LocalGroupMember -Group $groupeCible.Name -Member $nom -ErrorAction SilentlyContinue
        if (-not $membre) {
            Add-LocalGroupMember -Group $groupeCible.Name -Member $nom -ErrorAction Stop
        }
        Ecrire ('  Membre de : {0}' -f $groupeCible.Name) 'Green'

        # Un compte standard ne doit pas rester administrateur d'un passage
        # precedent : le script doit pouvoir retrograder un compte.
        if (-not $Compte.admin) {
            $dansAdmins = Get-LocalGroupMember -Group $Groupes.Admins.Name -Member $nom -ErrorAction SilentlyContinue
            if ($dansAdmins) {
                Remove-LocalGroupMember -Group $Groupes.Admins.Name -Member $nom -ErrorAction SilentlyContinue
                Ecrire '  Retire du groupe Administrateurs.' 'Yellow'
            }
        }

        return $statut
    } catch {
        $msg = $_.Exception.Message
        Ecrire ('  Echec : {0}' -f $msg) 'Red'
        if ($msg -match 'password|mot de passe|complex') {
            Ecrire '  Cause probable : strategie de complexite des mots de passe active.' 'Yellow'
        }
        return 'Echec'
    }
}

function Set-Autologon {
    param(
        [string]$Nom,
        [string]$MotDePasse
    )

    # Windows n'a pas d'autre moyen : le mot de passe est stocke en clair dans
    # la ruche. C'est annonce sur la page web, sous la case.
    $cle = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        Set-ItemProperty -Path $cle -Name 'AutoAdminLogon' -Value '1' -ErrorAction Stop
        Set-ItemProperty -Path $cle -Name 'DefaultUserName' -Value $Nom -ErrorAction Stop
        Set-ItemProperty -Path $cle -Name 'DefaultPassword' -Value $MotDePasse -ErrorAction Stop
        Set-ItemProperty -Path $cle -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -ErrorAction SilentlyContinue
        Ecrire ('  Ouverture de session automatique : {0}' -f $Nom) 'Green'
        return 'Configure'
    } catch {
        Ecrire ('  Echec de la connexion automatique : {0}' -f $_.Exception.Message) 'Red'
        return 'Echec'
    }
}
