# Data Model: Conteneurisation de ToshibaManager

Pas de base de données — le "modèle de données" ici décrit les entités
fichiers/config manipulées par le packaging conteneur (dérivées des Key
Entities du [spec.md](./spec.md)).

## Template de numérisation actif

- **Représentation**: fichier XML unique, `templates.xml`.
- **Emplacement runtime**: volume nommé `toshiba_data`, monté dans le
  conteneur sur le dossier `uploads/` de l'application.
- **Origine**: soit copié depuis le template par défaut au premier
  démarrage (volume vide), soit remplacé par un import utilisateur via
  `/api/upload`.
- **Règles de validation**: doit être un XML bien formé (`ET.parse` ne lève
  pas d'exception) — déjà appliqué par l'application à l'upload ; réappliqué
  au démarrage du conteneur (research.md §5).
- **Cycle de vie**: persiste indéfiniment à travers redémarrages et mises à
  jour d'image (FR-003). Écrasé uniquement par un nouvel upload ou une
  suppression de groupe (`DELETE /api/groups/<gid>`), comportement inchangé
  par cette feature.

## Template par défaut

- **Représentation**: fichier XML `modele_xml/template_base.xml`.
- **Emplacement runtime**: copié dans l'image au build (`COPY` dans le
  Dockerfile) — fait partie du code livré, pas du volume.
- **Cycle de vie**: change uniquement via une nouvelle version de l'image
  (mise à jour du code), jamais modifié à l'exécution.

## Fichier source du carnet d'adresses (éphémère)

- **Représentation**: classeur `.xlsx`/`.xls`/`.csv` uploadé, nommé
  `addr_<uuid>.<ext>`.
- **Emplacement runtime**: même volume `toshiba_data` (dossier `uploads/`),
  par cohérence avec le comportement actuel — mais sans garantie de
  persistance requise (nettoyage automatique après usage/1h, comportement
  applicatif inchangé).

## CSV du carnet d'adresses généré

- **Représentation**: contenu CSV renvoyé directement dans la réponse HTTP
  (`/api/addressbook/generate`), jamais écrit sur disque côté serveur au-delà
  du traitement de la requête — inchangé par cette feature.

## Identifiants SMTP de test

- **Représentation**: `email` + `password` reçus dans le corps JSON d'une
  requête (`/api/smtp/test-connection`, `/api/smtp/send-test-email`).
- **Contrainte forte**: ne doit jamais être écrit sur disque, journalisé, ni
  présent dans une image ou un volume (FR-004). Le packaging conteneur ne
  doit introduire aucun logging qui capturerait le corps de ces requêtes.

## Script de partage hôte

- **Représentation**: fichier binaire `Toshiba+Partage.bat`, inchangé.
- **Emplacement runtime**: copié dans l'image (`COPY`), servi tel quel par
  la route `/download-bat` existante — aucune modification de son contenu.
- **Distinction clé**: le *fichier* vit dans le conteneur (pour rester
  téléchargeable, FR-008) ; son *exécution* (création d'utilisateur Windows,
  partage SMB) se fait uniquement sur la machine hôte Windows de
  l'administrateur, jamais dans le conteneur.

## Configuration de déploiement (nouvelle, introduite par cette feature)

- **Variables d'environnement** (aucune n'existe aujourd'hui) :
  - `PORT` (optionnel, défaut `5000`) — port d'écoute interne du conteneur.
  - M2 uniquement, côté reverse proxy : `DOMAIN` (nom de domaine public),
    `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD_HASH` (identifiants
    d'authentification, jamais en clair dans un fichier versionné).
- **Cycle de vie**: fournies au démarrage du conteneur (fichier `.env` local
  à la machine de déploiement, non versionné) ; aucune n'est un secret
  applicatif Flask — l'app elle-même ne gère aucun compte utilisateur
  (FR-011 est porté par le reverse proxy, research.md §7).
