# ToshibaManager — déploiement Docker

Application interne OMB Informatique (gestion du template XML de
numérisation Toshiba, carnet d'adresses, testeur SMTP). Voir
[../../specs/001-dockerize-app/](../../specs/001-dockerize-app/) pour la
spécification complète, le plan et les décisions de conception.

## Démarrer en local (M1)

```bash
docker compose up --build
```

- Hub : http://localhost:5000/hub
- Contrôle de santé : http://localhost:5000/healthz

Le template XML actif (`uploads/templates.xml`) est conservé entre
redémarrages et mises à jour via le volume nommé `toshiba_data`.

## Exposer publiquement via un nom de domaine (M2)

1. Copier `.env.example` vers `.env` et renseigner `DOMAIN`,
   `BASIC_AUTH_USER`, `BASIC_AUTH_PASSWORD_HASH`.
2. `docker compose --profile public up --build`

Le reverse proxy (Caddy, voir `../../reverse-proxy/Caddyfile`) gère le
certificat HTTPS automatique et exige une authentification avant tout accès.
L'application elle-même reste jointe uniquement en local (`127.0.0.1`) et
via le réseau Docker interne — jamais directement exposée.

## Installation des copieurs sur les postes clients

La page `/installer` (1ʳᵉ tuile du hub) génère un `.bat` déjà paramétré avec
l'adresse IP du copieur. Sur le poste de l'utilisateur, ce fichier s'élève en
UAC, télécharge le toolkit PowerShell, détecte le modèle en SNMP, en déduit le
pilote, télécharge l'archive correspondante depuis ce serveur et installe le
copieur : pilote, port TCP/IP, file nommée `TOSHIBA <MODELE>`, A4 et impression
intelligente.

Le formulaire propose deux réglages, appliqués aux deux jeux (préférences de
l'utilisateur et paramètres par défaut de la machine) : couleur ou noir & blanc,
recto ou recto/verso. Les valeurs par défaut sont noir & blanc et recto.

Le champ modèle est facultatif : renseigné, il sert de repli quand le SNMP du
copieur est coupé, ce qui évite toute saisie sur le poste client.

Tout le code est dans `installer_routes.py` (blueprint Flask) et `installer/`
(le toolkit PowerShell distribué). Voir `installer/README.md` pour le
fonctionnement du script lui-même.

### Archives de pilotes

Les ZIP des pilotes Toshiba (~215 Mo) ne sont pas versionnés. Ils se déposent
dans `drivers/` à la racine du dépôt, monté en lecture seule dans le
conteneur :

```bash
mkdir -p drivers
# y copier les 3 archives listées dans installer/config/sources.json
```

Sans elles, `/installer` affiche un bandeau d'avertissement et le `.bat`
généré échouerait sur le poste client. Après ajout ou mise à jour d'une
archive, recalculer son empreinte et la reporter dans
`installer/config/sources.json` :

```powershell
Get-FileHash '.\drivers\<archive>.zip' -Algorithm SHA256
```

### Mise en cache

`/installer/toolkit.zip` et le `.bat` généré sont servis en `Cache-Control:
no-store`. Cloudflare met les `.zip` en cache quatre heures par défaut, et un
toolkit périmé installe des réglages qui ne sont plus ceux demandés — le cas
s'est produit. L'URL du toolkit dans le `.bat` porte en plus une empreinte du
contenu (`?v=<sha256 tronqué>`), donc un cache qui ignorerait les en-têtes
sert quand même la bonne version.

L'archive est construite de façon déterministe (dates figées dans le ZIP), si
bien qu'une reconstruction de l'image sans changement de contenu produit la
même empreinte et n'oblige aucun poste à retélécharger.

Les archives de pilotes, elles, restent cachables : leur nom porte la version
du pilote, et le script contrôle le SHA256 après téléchargement.

### Reverse proxy

Les chemins `/installer` et `/installer/*` doivent rester accessibles **sans
authentification** : le `.bat` tourne sur le poste client, sans session ni
identifiants. L'exemption est déjà faite dans le `Caddyfile`. Si une Access
List est active sur le Proxy Host côté Nginx Proxy Manager, y ajouter la même
exception.

Renseigner aussi `PUBLIC_BASE_URL` dans `.env` : sans elle, l'URL inscrite
dans le `.bat` est déduite de la requête et peut annoncer `http://` derrière
un reverse proxy.

## Vérification

Voir [../../specs/001-dockerize-app/quickstart.md](../../specs/001-dockerize-app/quickstart.md)
pour le parcours de validation complet (M1 et M2).
