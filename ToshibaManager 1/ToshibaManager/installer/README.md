# Installation automatique des copieurs Toshiba

Script PowerShell d'installation d'un copieur Toshiba en port TCP/IP, avec
détection du modèle en SNMP, choix automatique du pilote, nommage normalisé
`TOSHIBA <MODELE>`, réglages par défaut (noir & blanc et recto simple sauf
commutateur contraire, A4, impression intelligente) et affectation en
imprimante par défaut.

## Utilisation

Double-cliquer sur **`Installer-Copieur.bat`**. Le lanceur demande l'élévation
UAC puis exécute le script en contournant la stratégie d'exécution PowerShell
(`-ExecutionPolicy Bypass`), sans modifier la configuration du poste.

Le script demande ensuite l'adresse IP du copieur et déroule l'installation.

### En ligne de commande

```powershell
.\Install-CopieurToshiba.ps1 -IP 192.168.22.3
.\Install-CopieurToshiba.ps1 -IP 192.168.22.3 -Modele 3525AC -Pilote Universal -NonInteractif
```

| Paramètre        | Rôle |
|------------------|------|
| `-IP`            | Adresse du copieur. Demandée si absente. |
| `-Modele`        | Force le modèle et court-circuite le SNMP. |
| `-Pilote`        | `Universal`, `Generic` ou `GenericPCL5`. |
| `-SourceRacine`  | Dossier local ou racine web des archives de pilotes. |
| `-DevModeDir`    | Dossier des DEVMODE de référence. Défaut : `.\devmode`. |
| `-Communaute`    | Communauté SNMP en lecture. Défaut : `public`. |
| `-FormatPapier`  | Format papier par défaut. Défaut : `A4`. Chaîne vide pour ne pas y toucher. |
| `-Couleur`       | Couleur par défaut. Sans ce commutateur : noir et blanc. |
| `-RectoVerso`    | Recto/verso bord long par défaut. Sans ce commutateur : recto simple. |
| `-NonInteractif` | Échoue au lieu de poser une question. |
| `-PasDeParDefaut`| N'affecte pas l'imprimante comme imprimante par défaut. |

Codes de sortie : `0` succès, `1` échec.
Journal complet dans `%ProgramData%\OMB\InstallCopieur\install-<horodatage>.log`.

## Ce que fait le script

1. Vérifie les droits administrateur et démarre le journal.
2. Valide l'adresse IP, teste le ping puis les ports 9100 et 515.
3. Interroge le copieur en SNMP (`hrDeviceDescr`, `sysDescr`,
   `prtGeneralPrinterName`) et extrait le modèle. Le technicien confirme.
   Sans réponse SNMP, saisie manuelle du modèle puis choix explicite du pilote.
4. Choisit le pilote via `config/modeles.json`, avec confirmation.
5. Récupère l'archive (dossier local ou serveur web avec contrôle SHA256),
   la décompresse dans `%TEMP%` et résout l'INF selon l'architecture.
6. Installe le pilote (`pnputil` puis `Add-PrinterDriver`, repli `printui.dll`).
   Le succès est contrôlé par présence réelle via `Get-PrinterDriver`, jamais
   par le code de retour.
7. Crée le port TCP/IP `IP_<adresse>` (RAW 9100), ou réutilise l'existant.
8. Crée la file `TOSHIBA <MODELE>`. Si le nom est déjà pris : `TOSHIBA 3525AC 2`,
   `TOSHIBA 3525AC 3`, etc. Si une file existe déjà sur le même port, elle est
   reconfigurée au lieu d'être dupliquée. En cas de nom inattendu, la file est
   retrouvée par son port ou son pilote puis renommée.
9. Force le mode couleur, le recto/verso et le format papier par cmdlet, puis
   applique le DEVMODE de référence s'il existe, avec ces mêmes choix réécrits
   dedans.
10. Désactive la gestion automatique de l'imprimante par défaut par Windows et
    définit la file comme imprimante par défaut.
11. Affiche un récapitulatif contrôlé (`Get-Printer`, `Get-PrintConfiguration`,
    `Win32_Printer`) et la liste des avertissements.

## Réglages par défaut et DEVMODE

Windows conserve **deux jeux de réglages distincts** par file :

- **Paramètres par défaut de l'impression** (onglet *Avancé* des propriétés) :
  niveau machine, commun à tous les utilisateurs. C'est le seul jeu atteint par
  `Set-PrintConfiguration`.
- **Préférences d'impression** (bouton *Préférences*) : niveau utilisateur,
  c'est celui réellement appliqué lors d'une impression.

Le script écrit les deux, dans cet ordre précis :

1. `Set-PrintConfiguration` pour le mode couleur, le recto/verso et le format
   papier. Cette cmdlet reconstruit le DEVMODE machine via WMI et **perd au
   passage la zone privée du pilote** : elle doit donc passer en premier.
2. Le DEVMODE de référence en dernier, appliqué aux deux niveaux. Il porte les
   options Toshiba et a le dernier mot. Comme il fige aussi le mode couleur et
   le recto/verso tels que capturés, `Set-DevModeReglages` y réécrit `dmColor`
   (offset 92) et `dmDuplex` (offset 94) avant application, pour respecter
   `-Couleur` et `-RectoVerso` sans toucher à la zone privée.
3. Sans DEVMODE de référence, `Sync-PrinterUserDefaults` recopie les paramètres
   par défaut dans les préférences de l'utilisateur.

Inverser 1 et 2 donne une file où l'impression intelligente apparaît dans les
préférences mais pas dans les paramètres par défaut. En fin d'installation, le
script compare les deux jeux et prévient s'ils diffèrent encore.

Le mode couleur et le recto/verso passent par `Set-PrintConfiguration`.
L'**impression intelligente** et les autres options propres au pilote Toshiba
vivent dans la partie privée du DEVMODE et ne sont accessibles à aucune cmdlet
Windows. Elles sont donc capturées une fois sur un poste de référence.

### Produire un DEVMODE de référence

1. Installer un copieur avec le pilote voulu sur un poste de référence.
2. Lancer **`Exporter-Reglages.bat`**.
3. Choisir la file, régler à la main noir & blanc, recto/verso et impression
   intelligente dans la fenêtre de préférences, valider par OK.
4. Le fichier `devmode\<NomDuPilote>.bin` est produit.
5. Le déposer dans le dossier `devmode\` distribué avec le script.

Un fichier par pilote suffit ; il est réutilisable sur tous les postes et tous
les modèles partageant ce pilote :

- `devmode\TOSHIBA Universal Printer 2.bin`
- `devmode\TOSHIBA Generic Printer XL.bin`

Tant qu'un fichier est absent, l'installation se termine normalement mais
affiche un avertissement : l'impression intelligente reste à régler à la main.

### Le cas de la couleur

Le pilote Toshiba distingue **trois** modes couleur — Noir & blanc, Auto,
Couleur — là où le champ standard `dmColor` n'en connaît que deux. Mesuré sur
un 2010AC : `dmColor=1` donne Noir & blanc, `dmColor=2` donne **Auto**, et le
mode Couleur n'existe que dans la zone privée, où les blocs sont protégés par
des sommes de contrôle (marqueurs `55 55`).

`-Couleur` charge donc une capture dédiée plutôt que de bricoler ces octets :

```
devmode\<NomDuPilote>.couleur.bin
```

Produite de la même façon que l'autre, en sélectionnant **Couleur** (et non
Auto) dans l'onglet Basique :

```powershell
.\Export-ReglagesToshiba.ps1 -Couleur
```

Sans ce fichier, l'installation en couleur se termine mais avertit que la file
restera probablement en Auto. Inutile pour les pilotes monochromes.

Le blob est écrit **sans repasser par `DocumentProperties`**. Cette fonction
renormalise la zone privée et y remet le mode Auto : mesuré sur un 2010AC, les
octets 280 et 284 revenaient à 1 dans les trois emplacements de stockage. En
écriture directe ils restent à 0, donc en Couleur. La validation n'est reprise
que si la taille du blob ne correspond pas à celle attendue par le pilote
installé, cas où une écriture brute serait risquée ; un avertissement le signale
alors.

Le recto/verso, lui, ne demande aucune capture supplémentaire : `dmDuplex` est
respecté par le pilote, vérifié sur matériel.


## Pilotes

Les archives ne sont pas versionnées dans ce dépôt (plus de 200 Mo au total) :
elles se placent dans `Drivers Toshiba\`, ou sur le serveur web.

| Clé            | Pilote Windows                | Archive | Usage |
|----------------|-------------------------------|---------|-------|
| `Universal`    | `TOSHIBA Universal Printer 2` | `TOSHIBA e-STUDIO Universal Printer Driver 2 [V.7.222.5412.313].zip` | Multifonctions |
| `Generic`      | `TOSHIBA Generic Printer XL`  | `Toshiba Generic Printer Driver 3.0.3.0 [XL-PCL6].zip` | Imprimantes |
| `GenericPCL5`  | `TOSHIBA Generic Printer`     | `Toshiba Generic Printer Driver 3.0.3.0 [PCL5].zip` | Compatibilité applis anciennes |

Téléchargement : <https://www.toshibatec.eu/support/drivers/>

La correspondance modèle → pilote se règle dans `config/modeles.json`, sans
toucher au code. Les règles sont évaluées dans l'ordre :

```json
{ "motif": "^[0-9]{4}(AC|AG|A|C|G)?$", "pilote": "Universal" }
```

## Hébergement web

Renseigner `racineWeb` dans `config/sources.json`, ou passer `-SourceRacine` :

```powershell
.\Install-CopieurToshiba.ps1 -SourceRacine https://outils.exemple.fr/toshiba
```

Le script attend les archives à la racine indiquée, sous le nom exact du champ
`archive`, et vérifie leur empreinte SHA256 après téléchargement. Recalculer
l'empreinte après toute mise à jour de pilote :

```powershell
Get-FileHash '.\Drivers Toshiba\<archive>.zip' -Algorithm SHA256
```

Si les fichiers `config\*.json` ne sont pas présents localement, ils sont
également téléchargés depuis `<racine>/config/`.

## Points d'attention

- **Élévation avec un autre compte.** L'imprimante par défaut et les
  préférences d'impression sont des réglages *par utilisateur*. Si l'UAC est
  validé avec un compte administrateur différent de la session ouverte, ils
  s'appliquent à ce compte, pas à l'utilisateur. Le script le détecte et
  l'affiche en avertissement.
- **Pilote Generic 3.0.3.0.** Il date de 2016. Sur les versions récentes de
  Windows 11, si le catalogue de signature est refusé, l'installation s'arrête
  avec un message explicite plutôt qu'en silence.
- **SNMP.** Le script embarque son propre client SNMPv1 (aucune dépendance).
  Si la communauté n'est pas `public`, utiliser `-Communaute`.

## Structure

```
Installer-Copieur.bat          lanceur : UAC + ExecutionPolicy Bypass
Exporter-Reglages.bat          lanceur de la capture DEVMODE
Install-CopieurToshiba.ps1     script principal
Export-ReglagesToshiba.ps1     capture du DEVMODE de référence
lib\Snmp.ps1                   client SNMPv1 et extraction du modèle
lib\DevMode.ps1                lecture/écriture du DEVMODE via winspool.drv
config\modeles.json            table modèle -> pilote
config\sources.json            archives, URL et empreintes SHA256
devmode\                       DEVMODE de référence, un par pilote
Drivers Toshiba\               archives des pilotes (hors dépôt)
```
