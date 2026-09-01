<#
    Snmp.ps1 — mini client SNMPv1 (GetRequest) en .NET pur.

    PowerShell 5.1 n'expose aucune cmdlet SNMP et le composant COM historique
    olePrn.OleSNMP n'existe pas en 64 bits. On encode donc nous-memes le paquet
    BER et on l'envoie en UDP sur le port 161.

    Fonctions exposees :
      Get-SnmpString -IPAddress <ip> -Oid <oid> [-Community public] [-TimeoutMs 2000]
      Get-ToshibaDescription -IPAddress <ip> [-Community public]
      Get-ModeleDepuisDescription -Description <texte>
#>

Set-StrictMode -Version Latest

# OID interroges, dans l'ordre de preference.
$script:OidsToshiba = @(
    '1.3.6.1.2.1.25.3.2.1.3.1',    # hrDeviceDescr
    '1.3.6.1.2.1.1.1.0',           # sysDescr
    '1.3.6.1.2.1.43.5.1.1.16.1'    # prtGeneralPrinterName
)

# Ces fonctions renvoient toujours un [byte[]] protege par la virgule unaire :
# sans elle, PowerShell deroule la collection dans le pipeline.

function ConvertTo-BerLength {
    param([int]$Length)

    $sortie = New-Object System.Collections.Generic.List[byte]
    if ($Length -lt 128) {
        $sortie.Add([byte]$Length)
        return , $sortie.ToArray()
    }

    $octets = New-Object System.Collections.Generic.List[byte]
    $reste = $Length
    while ($reste -gt 0) {
        $octets.Insert(0, [byte]($reste -band 0xFF))
        $reste = $reste -shr 8
    }
    $sortie.Add([byte](0x80 -bor $octets.Count))
    $sortie.AddRange($octets)
    return , $sortie.ToArray()
}

function New-BerTlv {
    param(
        [byte]$Tag,
        [byte[]]$Value
    )

    $sortie = New-Object System.Collections.Generic.List[byte]
    $sortie.Add($Tag)
    $sortie.AddRange((ConvertTo-BerLength -Length $Value.Length))
    if ($Value.Length -gt 0) { $sortie.AddRange($Value) }
    return , $sortie.ToArray()
}

function ConvertTo-BerOid {
    param([string]$Oid)

    $arcs = @($Oid.Split('.') | ForEach-Object { [int]$_ })
    if ($arcs.Count -lt 2) { throw "OID invalide : $Oid" }

    $sortie = New-Object System.Collections.Generic.List[byte]
    $sortie.Add([byte](40 * $arcs[0] + $arcs[1]))

    for ($i = 2; $i -lt $arcs.Count; $i++) {
        $valeur = $arcs[$i]
        if ($valeur -lt 128) {
            $sortie.Add([byte]$valeur)
            continue
        }
        # Encodage base 128, bit de poids fort a 1 sauf sur le dernier octet.
        $groupe = New-Object System.Collections.Generic.List[byte]
        $groupe.Insert(0, [byte]($valeur -band 0x7F))
        $valeur = $valeur -shr 7
        while ($valeur -gt 0) {
            $groupe.Insert(0, [byte](($valeur -band 0x7F) -bor 0x80))
            $valeur = $valeur -shr 7
        }
        $sortie.AddRange($groupe)
    }
    return , $sortie.ToArray()
}

function New-SnmpGetRequest {
    param(
        [string]$Oid,
        [string]$Community,
        [int]$RequestId
    )

    $oidBytes = ConvertTo-BerOid -Oid $Oid

    $varbind = New-Object System.Collections.Generic.List[byte]
    $varbind.AddRange((New-BerTlv -Tag 0x06 -Value $oidBytes))
    $varbind.AddRange((New-BerTlv -Tag 0x05 -Value ([byte[]]@())))

    $varbindSeq = New-BerTlv -Tag 0x30 -Value $varbind.ToArray()
    $varbindList = New-BerTlv -Tag 0x30 -Value $varbindSeq

    $idBytes = New-Object System.Collections.Generic.List[byte]
    foreach ($b in [System.BitConverter]::GetBytes([int]$RequestId)) { $idBytes.Insert(0, $b) }
    while ($idBytes.Count -gt 1 -and $idBytes[0] -eq 0 -and ($idBytes[1] -band 0x80) -eq 0) { $idBytes.RemoveAt(0) }

    $zero = [byte[]]@(0)

    $pdu = New-Object System.Collections.Generic.List[byte]
    $pdu.AddRange((New-BerTlv -Tag 0x02 -Value $idBytes.ToArray()))   # request-id
    $pdu.AddRange((New-BerTlv -Tag 0x02 -Value $zero))                # error-status
    $pdu.AddRange((New-BerTlv -Tag 0x02 -Value $zero))                # error-index
    $pdu.AddRange($varbindList)

    $communityBytes = [System.Text.Encoding]::ASCII.GetBytes($Community)

    $message = New-Object System.Collections.Generic.List[byte]
    $message.AddRange((New-BerTlv -Tag 0x02 -Value $zero))            # version : 0 = SNMPv1
    $message.AddRange((New-BerTlv -Tag 0x04 -Value $communityBytes))
    $message.AddRange((New-BerTlv -Tag 0xA0 -Value $pdu.ToArray()))   # 0xA0 = GetRequest

    return , (New-BerTlv -Tag 0x30 -Value $message.ToArray())
}

function Read-BerNodes {
    param(
        [byte[]]$Buffer,
        [int]$Start,
        [int]$End
    )

    $noeuds = New-Object System.Collections.Generic.List[object]
    $i = $Start
    while ($i -lt $End) {
        $tag = $Buffer[$i]; $i++
        if ($i -ge $End) { break }

        $premier = $Buffer[$i]; $i++
        if ($premier -lt 0x80) {
            $longueur = [int]$premier
        }
        else {
            $nbOctets = $premier -band 0x7F
            $longueur = 0
            for ($k = 0; $k -lt $nbOctets; $k++) {
                $longueur = ($longueur -shl 8) -bor $Buffer[$i]
                $i++
            }
        }
        if (($i + $longueur) -gt $End) { break }

        if (($tag -band 0x20) -ne 0) {
            # Type construit : on descend dedans.
            $noeuds.AddRange((Read-BerNodes -Buffer $Buffer -Start $i -End ($i + $longueur)))
        }
        else {
            $valeur = New-Object byte[] $longueur
            if ($longueur -gt 0) { [Array]::Copy($Buffer, $i, $valeur, 0, $longueur) }
            $noeuds.Add([pscustomobject]@{ Tag = $tag; Value = $valeur })
        }
        $i += $longueur
    }
    return , $noeuds
}

function Get-SnmpString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$Oid,
        [string]$Community = 'public',
        [int]$TimeoutMs = 2000
    )

    $requete = New-SnmpGetRequest -Oid $Oid -Community $Community -RequestId (Get-Random -Minimum 1 -Maximum 65535)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.UdpClient
        $client.Client.ReceiveTimeout = $TimeoutMs
        $client.Client.SendTimeout = $TimeoutMs
        $client.Connect($IPAddress, 161)
        [void]$client.Send($requete, $requete.Length)

        $distant = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $reponse = $client.Receive([ref]$distant)
    }
    catch {
        Write-Verbose "SNMP $Oid sur $IPAddress : $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($client) { $client.Close() }
    }

    $noeuds = Read-BerNodes -Buffer $reponse -Start 0 -End $reponse.Length
    if ($noeuds.Count -lt 6) { return $null }

    # version, community, request-id, error-status, error-index, oid, valeur
    $erreur = $noeuds[3]
    if ($erreur.Tag -eq 0x02 -and $erreur.Value.Length -ge 1 -and $erreur.Value[0] -ne 0) {
        Write-Verbose "SNMP $Oid : error-status $($erreur.Value[0])"
        return $null
    }

    $indexOid = -1
    for ($i = 0; $i -lt $noeuds.Count; $i++) {
        if ($noeuds[$i].Tag -eq 0x06) { $indexOid = $i }
    }
    if ($indexOid -lt 0 -or ($indexOid + 1) -ge $noeuds.Count) { return $null }

    $valeur = $noeuds[$indexOid + 1]
    switch ($valeur.Tag) {
        0x04 { return ([System.Text.Encoding]::UTF8.GetString($valeur.Value)).Trim([char]0, ' ') }
        0x02 {
            $n = 0
            foreach ($b in $valeur.Value) { $n = ($n -shl 8) -bor $b }
            return "$n"
        }
        default { return $null }
    }
}

function Get-ToshibaDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Community = 'public',
        [int]$TimeoutMs = 2000
    )

    foreach ($oid in $script:OidsToshiba) {
        $valeur = Get-SnmpString -IPAddress $IPAddress -Oid $oid -Community $Community -TimeoutMs $TimeoutMs
        if ($valeur -and $valeur.Trim().Length -gt 0) {
            return [pscustomobject]@{ Oid = $oid; Description = $valeur.Trim() }
        }
    }
    return $null
}

function Get-ModeleDepuisDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Description)

    if ([string]::IsNullOrWhiteSpace($Description)) { return $null }

    $motifs = @(
        'e-?STUDIO\s*([0-9]{3,4}\s*[A-Za-z]{0,3})',
        'TOSHIBA\s+([0-9]{3,4}\s*[A-Za-z]{0,3})',
        '([0-9]{3,4}\s*(?:AC|AG|CS|CP|C|A|G|S|P))'
    )

    foreach ($motif in $motifs) {
        $m = [regex]::Match($Description, $motif, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $modele = ($m.Groups[1].Value -replace '\s', '').ToUpperInvariant()
            if ($modele.Length -ge 3) { return $modele }
        }
    }
    return $null
}
