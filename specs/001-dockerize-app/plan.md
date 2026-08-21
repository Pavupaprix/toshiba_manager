# Implementation Plan: Conteneurisation (Docker) de ToshibaManager

**Branch**: `001-dockerize-app` | **Date**: 2026-08-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-dockerize-app/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Empaqueter l'application Flask ToshibaManager existante (déjà fonctionnelle
en local) dans une image de conteneur Linux, sans changer son comportement
métier : même hub, même gestion du template XML Toshiba, même générateur de
carnet d'adresses, même testeur SMTP, même fichier `.bat` téléchargeable. Le
service de fichiers actuel (template XML actif, template par défaut) doit
survivre aux redémarrages/mises à jour via un volume nommé. Le serveur de
développement Flask (`debug=True`) est remplacé par un serveur WSGI de
production. Une deuxième étape (M2, hors du chemin critique immédiat mais
conçue dès maintenant) ajoute un reverse proxy avec HTTPS automatique et une
authentification obligatoire, pour permettre l'exposition future sur
Internet via un nom de domaine, en auto-hébergement chez l'utilisateur.

## Technical Context

**Language/Version**: Python 3.12 (image `python:3.12-slim`) — le dépôt ne
fixe aucune version (caches `__pycache__` trouvés pour cpython-310 *et*
cpython-314, donc aucune contrainte stricte observée) ; 3.12 est choisi en
recherche (Phase 0) comme version stable, supportée long terme, compatible
avec Flask et openpyxl.

**Primary Dependencies**: Flask (web), openpyxl (lecture des classeurs
.xlsx/.xls du carnet d'adresses), bibliothèque standard (`smtplib`, `ssl`,
`xml.etree.ElementTree`, `csv`) ; ajout d'un serveur WSGI de production
(Waitress — voir research.md) puisqu'aucun n'est utilisé aujourd'hui
(`app.run(debug=True)` uniquement).

**Storage**: Fichiers plats, pas de base de données. `uploads/templates.xml`
(template actif) et `modele_xml/template_base.xml` (template par défaut)
doivent être conservés via un volume nommé monté dans le conteneur ; les
fichiers `uploads/addr_*.xlsx` restent éphémères (déjà nettoyés côté
application, pas de garantie de persistance requise).

**Testing**: Aucune suite automatisée n'existe (constitution — Principe V,
Vérification manuelle). Le plan ne introduit pas de suite de tests
obligatoire ; la validation se fait par un parcours manuel des scénarios
d'acceptation du spec (voir quickstart.md), à exécuter avant et après chaque
changement d'image, conformément à ce principe.

**Target Platform**: Conteneur Linux (moteur Docker), auto-hébergé chez
l'utilisateur. Accessible d'abord en local/LAN (M1), puis via nom de domaine
public à travers un reverse proxy HTTPS (M2, FR-010 à FR-012).

**Project Type**: Application web monolithique (serveur Flask
mono-processus, templates Jinja rendus côté serveur, assets statiques).

**Performance Goals**: Usage interne, faible volumétrie — quelques
utilisateurs simultanés (personnel OMB) ; aucune exigence de débit élevé.
Cible raisonnable : pages du hub et actions API répondent en moins d'une
seconde en usage normal, sans optimisation particulière requise.

**Constraints**: Aucun secret (identifiants SMTP saisis dans le testeur) ne
doit être écrit dans l'image ni dans le volume persistant (FR-004,
constitution Principe II). Le conteneur doit démarrer en mode production
(pas de `debug=True`, FR-005). Le fichier `Toshiba+Partage.bat` doit rester
embarqué dans l'image (FR-008). Une fois exposé sur Internet, tout accès non
authentifié doit être refusé et le trafic chiffré en HTTPS (FR-011, FR-012).

**Scale/Scope**: Une seule instance, un seul organisme (OMB Informatique),
une poignée d'utilisateurs internes ; pas de multi-tenant, pas d'inscription
publique — l'accès public à terme reste réservé aux mêmes utilisateurs
authentifiés, pas au grand public.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Évalué contre `.specify/memory/constitution.md` (v1.0.0) :

| Principe | Statut | Justification |
|----------|--------|----------------|
| I. Simplicity First (YAGNI) | PASS | Un seul conteneur applicatif + un reverse proxy pour TLS/auth (M2) ; pas de base de données, pas de microservices, pas de nouvelle dépendance non justifiée (seul ajout : un serveur WSGI de production, requis par FR-005). |
| II. Data Safety & Confidentiality | PASS (sous conditions du plan) | Aucun identifiant SMTP persistant (FR-004) ; `.dockerignore` exclut `uploads/`, `__pycache__/`, captures d'écran des sources buildées dans l'image ; futurs identifiants d'authentification (M2) fournis par variable d'environnement, jamais codés en dur. |
| III. French-First UX Consistency | PASS (non impacté) | La conteneurisation ne modifie ni templates, ni textes, ni style — aucun changement UI. |
| IV. Toshiba XML Template Integrity | PASS (sous conditions du plan) | `modele_xml/template_base.xml` copié dans l'image et validé (parse XML) au démarrage, réutilisant la validation déjà présente dans `app.py` (`ET.parse`) ; le volume persistant garantit que le template actif reste un XML valide entre redémarrages. |
| V. Manual Verification (NON-NEGOTIABLE) | PASS | Pas de suite de tests automatisés ajoutée ni requise ; `quickstart.md` documente le parcours de vérification manuelle à exécuter à chaque changement d'image. |

Aucune violation → **Complexity Tracking** non nécessaire (section laissée vide plus bas).

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
ToshibaManager 1/ToshibaManager/     # Application existante (inchangée) — code métier ici
├── app.py                          # Flask app (routes hub/template/addressbook/smtp)
├── addressbook.py
├── toshiba_template.py             # ancien prototype standalone — non utilisé par app.py, non touché
├── modele_xml/
│   └── template_base.xml           # copié dans l'image, validé au démarrage
├── templates/                      # Jinja templates (FR/UI, non modifiés)
├── static/                         # CSS/JS/logos (non modifiés)
├── uploads/                        # → remplacé par un volume nommé au runtime (non versionné)
├── Toshiba+Partage.bat             # embarqué dans l'image (FR-008), exécuté hors conteneur
│
│ # --- Nouveaux fichiers de packaging (cette feature) ---
├── requirements.txt                # Flask, openpyxl, waitress (voir research.md)
├── Dockerfile                      # build de l'image, utilisateur non-root, CMD via entrypoint.sh
├── entrypoint.sh                   # lance waitress-serve sur $PORT (T008, research.md §2)
├── .dockerignore                   # exclut uploads/, __pycache__/, captures d'écran, .git
├── docker-compose.yml              # service app + volume nommé ; profil M2 ajoute un reverse proxy
└── .env.example                    # documente DOMAIN, BASIC_AUTH_USER, BASIC_AUTH_PASSWORD_HASH (M2, T019)

reverse-proxy/                      # M2 seulement — config du reverse proxy (HTTPS + auth)
└── Caddyfile                       # nom de domaine, TLS automatique, Basic Auth (voir research.md)
```

**Structure Decision**: Projet unique (Option 1 simplifiée, pas de séparation
frontend/backend : l'app existante sert déjà son propre HTML). Les fichiers
de packaging Docker vivent à côté du code applicatif existant, dans
`ToshibaManager 1/ToshibaManager/`, pour que l'image se construise avec ce
dossier comme contexte de build sans réorganiser le code métier. La
configuration du reverse proxy (M2) est isolée dans un dossier séparé
`reverse-proxy/` car elle ne fait pas partie de l'application elle-même et
pourra évoluer indépendamment (changement de domaine, de certificat, etc.).
`toshiba_template.py` (prototype antérieur à `app.py`, non importé par
celui-ci) n'est pas supprimé par cette feature — hors périmètre — mais n'est
pas non plus exécuté dans le conteneur.

## Constitution Check — re-vérification post-Phase 1

Après conception (research.md + data-model.md + contracts/) :

- **II. Data Safety** : confirmé — `.dockerignore` documenté, identifiants
  SMTP jamais journalisés/écrits (data-model.md), identifiants Basic Auth
  M2 en variable d'environnement uniquement (research.md §7).
- **IV. Toshiba XML Template Integrity** : confirmé — validation au
  démarrage + endpoint `/healthz` (contracts/http-routes.md) permettent de
  détecter un template par défaut manquant/invalide avant qu'un utilisateur
  ne le rencontre.
- Aucun principe régressé par la conception détaillée. **PASS** maintenu.

## Complexity Tracking

> Aucune violation de la Constitution Check ci-dessus — section non applicable.
