# Toolkit « Installer un poste »

Ce dossier est le contenu du ZIP généré par la page `/poste` de ToshibaManager.
Il n'est pas destiné à être lancé depuis le dépôt : le serveur l'archive avec un
`config.json` décrivant l'intervention.

## Utilisation sur le poste client

1. Décompressez le ZIP entier (les sous-dossiers `lib/` et `config/` sont
   nécessaires).
2. Double-cliquez sur `Installer-Poste.bat` et acceptez l'élévation UAC.
3. Laissez le script aller au bout, lisez le résumé.
4. Répondez **oui** à la question finale : c'est ce qui efface les mots de passe
   du poste.

> `config.json` contient en clair le mot de passe d'accès sans surveillance
> AnyDesk et ceux des comptes locaux. Il ne doit pas rester sur le poste.

Le journal est écrit dans `%ProgramData%\OMB\InstallationPoste\` et **ne
contient aucun mot de passe** : il survit volontairement au nettoyage.

## Contenu

| Fichier | Rôle |
|---|---|
| `Installer-Poste.bat` | Lanceur : élévation UAC puis appel du script principal |
| `Install-Poste.ps1` | Orchestrateur : lit `config.json`, enchaîne les phases, résumé, nettoyage |
| `lib/Journal.ps1` | Affichage et journalisation, avec expurgation des mots de passe |
| `lib/Winget.ps1` | Installation/mise à jour winget, détection d'Office |
| `lib/Outils.ps1` | Installeurs OMB : téléchargement, vérification SHA-256, exécution silencieuse |
| `lib/Comptes.ps1` | Comptes locaux (groupes par SID) et ouverture de session automatique |
| `lib/AnyDesk.ps1` | Accès sans surveillance |
| `lib/Navigateur.ps1` | Chrome par défaut (DISM, puis SetUserFTA si présent) |
| `lib/Windows.ps1` | Réglages système, désinstallation ciblée, renommage |
| `config/catalogue.json` | Catalogue de référence des applications (source de vérité côté serveur) |

## Ordre d'exécution

Nettoyage → applications winget → installeurs OMB → AnyDesk → réglages Windows →
navigateur par défaut → comptes locaux → renommage → résumé → nettoyage.

Les comptes sont créés **après** les réglages Windows et les associations DISM :
c'est ce qui fait qu'un compte créé ici hérite des extensions visibles, du pavé
numérique et de Chrome par défaut dès sa première ouverture de session.

## Points d'attention

- **Le script est rejouable.** Une application présente est mise à jour, un
  compte existant voit son mot de passe réinitialisé. Relancer après un
  redémarrage est la première chose à faire en cas d'échec.
- **`EnableLUA=0`** (UAC « désactiver complètement ») empêche les applications
  du Store de s'ouvrir et exige un redémarrage. C'est un effet de bord Windows,
  pas un bug du script.
- **SetUserFTA n'est pas fourni** : son auteur exige une licence pour un usage
  professionnel. Sans lui, Chrome devient le navigateur par défaut des comptes
  créés par le script, mais pas de la session du technicien. Déposer
  `SetUserFTA.exe` dans `lib/` suffit à activer ce second passage.
- **VNC Viewer** : le commutateur silencieux `/S` de l'installeur RealVNC n'a
  pas encore été validé sur une machine réelle. Le résumé signalera un code de
  retour non nul si c'est le mauvais.
- **Antivirus** : la désinstallation ne touchera jamais SentinelOne, Defender,
  CrowdStrike, ESET ou Bitdefender, quel que soit le motif demandé.
