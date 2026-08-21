# Feature Specification: Conteneurisation (Docker) de ToshibaManager

**Feature Branch**: `001-dockerize-app`

**Created**: 2026-08-20

**Status**: Draft

**Input**: User description: "tu as acces a une application qui tourne parfaitement en locale, je te laisse l'analyser et en tirer les conclusions qu'il faut afin de la dockeriser"

## Contexte observé

ToshibaManager est une application web interne (Flask, en français) utilisée
par OMB Informatique pour trois usages autour d'un copieur multifonction
Toshiba : gérer le template XML de numérisation vers e-mail, générer le CSV
du carnet d'adresses à importer dans le copieur (TopAccess), et tester une
connexion SMTP. Elle tourne aujourd'hui en exécutant `app.py` directement sur
un poste Windows, sans fichier de dépendances ni configuration d'environnement
existants, et sans base de données — les données persistantes se limitent à
des fichiers plats (template XML actif, fichiers uploadés temporaires). Un
script `.bat` séparé (téléchargé depuis l'application) configure un partage
réseau Windows sur la machine hôte pour que le copieur y dépose ses scans ;
ce script agit sur l'hôte Windows (création d'utilisateur local, partage SMB)
et ne peut pas s'exécuter à l'intérieur d'un conteneur Linux.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Déployer l'application sans installation manuelle (Priority: P1)

En tant qu'administrateur OMB Informatique, je veux démarrer ToshibaManager
sur n'importe quel poste ou serveur avec une seule commande, sans installer
manuellement Python ni ses dépendances, pour pouvoir la déployer ou la
redéployer rapidement en cas de changement de poste ou de panne.

**Why this priority**: C'est la valeur centrale de la demande ("dockeriser
l'application") — sans ça, rien d'autre n'a de sens.

**Independent Test**: Sur une machine vierge (sans Python installé), lancer
l'application via la commande de démarrage fournie et vérifier que le hub,
le module template XML, le carnet d'adresses et le testeur SMTP fonctionnent
tous comme en local.

**Acceptance Scenarios**:

1. **Given** une machine avec seulement le moteur de conteneurs installé,
   **When** l'administrateur lance la commande de démarrage,
   **Then** l'application est accessible via un navigateur et affiche le hub
   sans erreur.
2. **Given** l'application démarrée pour la première fois,
   **When** l'administrateur ouvre la page Template,
   **Then** le template XML par défaut (`template_base.xml`) se charge
   correctement, comme en local.

---

### User Story 2 - Conserver les données entre redémarrages et mises à jour (Priority: P2)

En tant qu'administrateur, je veux que le template XML actif et les fichiers
que j'ai importés survivent à un redémarrage ou une mise à jour de
l'application, pour ne pas perdre une configuration déjà en place sur le
copieur.

**Why this priority**: Perdre le template actif obligerait à tout
reconfigurer manuellement sur le copieur physique — coût élevé si non traité.

**Independent Test**: Importer un template XML personnalisé, redémarrer le
conteneur (ou le remplacer par une nouvelle version de l'image), puis
vérifier que le même template est toujours proposé au téléchargement.

**Acceptance Scenarios**:

1. **Given** un template XML personnalisé importé et sauvegardé,
   **When** le conteneur est arrêté puis redémarré,
   **Then** le fichier `templates.xml` précédemment importé est toujours
   disponible via le téléchargement.
2. **Given** l'application en cours d'exécution,
   **When** l'administrateur la met à jour vers une nouvelle version de
   l'image,
   **Then** les fichiers précédemment importés ne sont pas perdus.

---

### User Story 3 - Ne jamais faire persister d'identifiants SMTP (Priority: P3)

En tant qu'administrateur, je veux être certain qu'aucun mot de passe SMTP
testé via la page "SMTP Tester" n'est écrit sur disque ni conservé après la
requête, pour ne pas introduire de risque de sécurité en déplaçant
l'application vers un déploiement conteneurisé partagé.

**Why this priority**: Moins critique pour le fonctionnement que P1/P2, mais
important pour la confidentialité — cohérent avec le principe "Sécurité des
données" de la constitution du projet.

**Independent Test**: Effectuer un test de connexion SMTP avec un mot de
passe donné, puis inspecter les fichiers persistés du déploiement et
confirmer qu'aucune trace du mot de passe n'y figure.

**Acceptance Scenarios**:

1. **Given** un test de connexion SMTP effectué avec succès,
   **When** on inspecte les volumes/fichiers persistés de l'application,
   **Then** aucun email ni mot de passe SMTP n'y apparaît.

---

### Edge Cases

- Que se passe-t-il si le port réseau utilisé par l'application est déjà
  occupé sur la machine hôte au démarrage ? L'échec doit être signalé
  clairement (pas un plantage silencieux).
- Que se passe-t-il si `modele_xml/template_base.xml` est absent au premier
  démarrage (image mal construite) ? La page Template doit afficher une
  erreur explicite plutôt qu'une page cassée, comme c'est déjà le cas en
  local (`Fichier template_base.xml non trouvé`).
- Que se passe-t-il si le volume de données persistantes n'existe pas encore
  au tout premier démarrage ? Il doit être créé automatiquement, sans
  intervention manuelle.
- Que se passe-t-il si un administrateur tente d'exécuter le script
  `Toshiba+Partage.bat` (création d'utilisateur/partage Windows) depuis
  l'intérieur du conteneur ? Ce n'est pas un scénario supporté : le script
  reste un outil pour l'hôte Windows et continue d'être proposé au
  téléchargement depuis l'interface, mais s'exécute en dehors du conteneur.
- Que se passe-t-il si quelqu'un accède au nom de domaine public sans être
  authentifié ? L'accès à toute fonctionnalité MUST être refusé (redirection
  vers une page de connexion), aucune donnée ni action ne doit être visible
  avant authentification.
- Que se passe-t-il si la connexion Internet de l'utilisateur (auto-hébergée)
  tombe ? L'application reste utilisable en local/LAN pendant l'incident ;
  seul l'accès via le nom de domaine public est affecté.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: L'application MUST pouvoir être démarrée sur toute machine
  disposant d'un moteur de conteneurs, via une seule commande de démarrage,
  sans installation manuelle préalable de Python ou de ses dépendances.
- **FR-002**: L'application MUST exposer les mêmes fonctionnalités
  qu'aujourd'hui en local : hub, gestion du template XML de numérisation
  (charger/importer/télécharger/supprimer un groupe), génération du CSV
  du carnet d'adresses, page de paramétrage, testeur SMTP (test de connexion
  et envoi d'e-mail de test), et téléchargement du script
  `Toshiba+Partage.bat`.
- **FR-003**: L'application MUST conserver le template XML actif
  (`uploads/templates.xml`) et le template par défaut
  (`modele_xml/template_base.xml`) à travers les redémarrages du conteneur
  et les mises à jour vers une nouvelle version de l'image.
- **FR-004**: L'application MUST NOT écrire ou faire persister, sous quelque
  forme que ce soit, les identifiants (email/mot de passe) saisis dans le
  testeur SMTP — ils restent utilisés uniquement le temps de la requête, comme
  aujourd'hui.
- **FR-005**: L'application MUST démarrer en mode adapté à un déploiement
  réel (pas de rechargement automatique de code ni de page de débogage
  exposant la stack technique), contrairement au mode actuel
  (`debug=True`) utilisé seulement en développement local.
- **FR-006**: L'application MUST rendre le template XML par défaut et les
  autres ressources statiques (logos, styles) disponibles dès le premier
  démarrage, sans étape de copie manuelle supplémentaire.
- **FR-007**: L'administrateur MUST pouvoir mettre à jour l'application vers
  une nouvelle version sans perdre les données couvertes par FR-003.
- **FR-008**: Le fichier `Toshiba+Partage.bat` MUST être embarqué dans
  l'image du conteneur (comme aujourd'hui à côté de `app.py`) afin que le
  clic sur le logo continue de le proposer au téléchargement ; seule son
  exécution (création d'utilisateur/partage réseau Windows) reste une action
  manuelle effectuée par l'administrateur sur la machine hôte Windows, hors
  du conteneur.
- **FR-009**: L'application MUST signaler clairement toute erreur de
  démarrage (ex. port déjà utilisé, fichier de template par défaut manquant)
  pour permettre un diagnostic rapide.
- **FR-010**: L'application MUST, à terme, être joignable depuis Internet via
  un nom de domaine, hébergée sur l'infrastructure de l'utilisateur
  (auto-hébergement chez lui, pas chez un fournisseur cloud tiers) — et non
  plus limitée à un accès local ou LAN uniquement.
- **FR-011**: Dès lors que l'application est exposée sur Internet, elle
  MUST exiger une authentification avant de donner accès à toute page ou
  fonctionnalité (template XML, carnet d'adresses, testeur SMTP) — aucune de
  ces fonctionnalités ne doit rester accessible anonymement à quiconque
  trouve le nom de domaine.
- **FR-012**: Toute communication avec l'application via son nom de domaine
  public MUST être chiffrée (HTTPS), pour protéger notamment les
  identifiants SMTP saisis dans le testeur.

### Key Entities

- **Template de numérisation (XML)** : configuration active envoyée au
  copieur Toshiba (scan-to-email), importée par l'administrateur ou générée
  par défaut ; doit survivre aux redémarrages/mises à jour.
- **Fichier source du carnet d'adresses** : classeur (.xlsx/.xls/.csv)
  temporairement importé par l'administrateur pour en extraire des contacts ;
  déjà traité comme éphémère (nettoyage automatique après usage).
- **CSV du carnet d'adresses généré** : résultat téléchargé par
  l'administrateur pour import dans le copieur ; non persisté côté serveur
  au-delà de la génération.
- **Identifiants SMTP de test** : email + mot de passe saisis pour un test
  ponctuel ; ne doivent jamais être écrits sur disque.
- **Script de partage hôte (`Toshiba+Partage.bat`)** : fichier embarqué dans
  l'image du conteneur pour rester téléchargeable depuis l'interface ; son
  exécution, en revanche, se fait manuellement sur l'hôte Windows, hors du
  conteneur.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001** : Un administrateur peut faire tourner l'application complète
  sur une machine neuve en moins de 10 minutes, avec une seule commande de
  démarrage, sans installer Python ni aucune dépendance manuellement.
- **SC-002** : Les trois usages existants (template XML, carnet d'adresses,
  testeur SMTP) fonctionnent à l'identique de la version locale actuelle,
  vérifié par un parcours complet de chaque fonctionnalité.
- **SC-003** : 100% des templates XML précédemment importés sont toujours
  présents après un redémarrage ou une mise à jour du déploiement.
- **SC-004** : Aucun mot de passe SMTP saisi lors d'un test n'est
  retrouvable dans les fichiers ou volumes persistés du déploiement, à
  aucun moment après la fin de la requête.
- **SC-005** : Une erreur de démarrage (port occupé, fichier par défaut
  manquant) est visible et compréhensible par l'administrateur en moins
  d'une minute, sans avoir à inspecter le code source.
- **SC-006** : Une personne non authentifiée accédant au nom de domaine
  public ne peut consulter ni modifier aucune donnée (template, carnet
  d'adresses, identifiants SMTP) — vérifié en tentant chaque action sans
  être connecté.
- **SC-007** : Une fois authentifié via le nom de domaine public, un membre
  du personnel effectue les mêmes actions qu'en local (template, carnet
  d'adresses, testeur SMTP) sans différence de comportement perçue.

## Assumptions

- L'objectif est de faire tourner l'application interne existante telle
  quelle dans un conteneur — aucune nouvelle fonctionnalité métier n'est
  demandée par "dockeriser".
- Il n'existe aujourd'hui ni fichier de dépendances (`requirements.txt`) ni
  configuration d'environnement (`.env`) ; ils font partie du travail de
  packaging à produire, mais leur contenu exact est un détail
  d'implémentation traité en phase de planification, pas dans cette
  spécification.
- Aucune base de données externe n'est nécessaire : toute la persistance
  actuelle repose sur des fichiers plats sous `uploads/` et `modele_xml/`.
- Les fichiers uploadés du carnet d'adresses (`addr_*.xlsx`) restent
  éphémères (déjà nettoyés après ~1h côté application actuelle) et ne font
  pas partie des données à garantir persistantes.
- Le script `Toshiba+Partage.bat` continue d'exister comme artefact
  téléchargeable mais reste hors du périmètre d'exécution du conteneur,
  car il agit sur la configuration Windows de la machine hôte (utilisateur
  local, partage SMB) — une opération qu'un conteneur Linux ne peut pas
  réaliser sur son hôte.
- Le port d'écoute exact et les autres réglages réseau fins (reverse proxy,
  redirection de port sur le routeur du domicile, DNS/nom de domaine,
  certificat TLS) restent des détails d'implémentation à fixer en phase de
  planification.
- L'exposition publique via nom de domaine est un objectif à terme, pas
  nécessairement livré dès la première itération : l'app doit d'abord
  tourner correctement en conteneur (US1/US2), l'accès public authentifié
  (FR-010 à FR-012) pouvant être une itération suivante.
- Le mécanisme d'authentification exact (compte unique partagé,
  utilisateurs nommés, SSO...) n'est pas encore choisi ; c'est un détail
  d'implémentation à trancher en planification — seule l'exigence "pas
  d'accès anonyme une fois public" est actée ici.
- L'hébergement se fait chez l'utilisateur (auto-hébergement à domicile ou
  dans ses locaux), pas chez un fournisseur cloud tiers ; la disponibilité
  de l'app dépend donc de sa connexion Internet et de son matériel.
