---
description: "Task list for feature implementation"
---

# Tasks: Conteneurisation (Docker) de ToshibaManager

**Input**: Design documents from `/specs/001-dockerize-app/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/http-routes.md](./contracts/http-routes.md), [quickstart.md](./quickstart.md)

**Tests**: Aucune suite automatisée n'est demandée (constitution Principe V —
Vérification manuelle). Les "tests" de ce plan sont les parcours manuels de
`quickstart.md`, exécutés comme tâches explicites dans chaque phase.

**Organization**: Tâches groupées par user story (spec.md) pour une
implémentation et une validation indépendantes de chacune. La phase M2
(FR-010 à FR-012) n'a pas de user story numérotée dédiée dans spec.md — elle
est traitée comme une itération suivante explicitement documentée dans les
Assumptions du spec et dans plan.md/research.md.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Peut s'exécuter en parallèle (fichiers différents, pas de dépendance)
- **[Story]**: User story concernée (US1, US2, US3)
- Chemins de fichiers exacts inclus dans chaque description

## Path Conventions

Projet unique — code applicatif et fichiers de packaging dans
`ToshibaManager 1/ToshibaManager/` (contexte de build Docker) ; la config
du reverse proxy M2 vit dans `reverse-proxy/` à la racine du dépôt (voir
plan.md → Project Structure).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Fichiers de packaging de base, aucun encore fonctionnel

- [X] T001 [P] Créer `ToshibaManager 1/ToshibaManager/requirements.txt` avec versions figées : `Flask`, `openpyxl`, `waitress` (research.md §1–3)
- [X] T002 [P] Créer `ToshibaManager 1/ToshibaManager/.dockerignore` excluant `uploads/`, `__pycache__/`, `*.png`, `*.jpg`, `.git`, `Capture d'écran*`
- [X] T003 [P] Créer le dossier `reverse-proxy/` (placeholder pour M2, ex. `reverse-proxy/.gitkeep`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Rendre le conteneur constructible et démarrable ; bloque toutes les user stories

**⚠️ CRITICAL**: Aucune user story ne peut être validée avant la fin de cette phase

- [X] T004 [P] Écrire `ToshibaManager 1/ToshibaManager/Dockerfile` : base `python:3.12-slim`, création d'un utilisateur non-root, `WORKDIR /app`, `COPY requirements.txt` + `pip install`, `COPY` du code applicatif (app.py, addressbook.py, modele_xml/, templates/, static/, Toshiba+Partage.bat), `EXPOSE 5000` (research.md §1, §8 ; FR-001, FR-008)
- [X] T005 [P] Ajouter la route `GET /healthz` dans `ToshibaManager 1/ToshibaManager/app.py` (répond `200 {"status":"ok"}` si le template par défaut a été validé au démarrage, sinon `503`) — contracts/http-routes.md
- [X] T006 Ajouter, dans `ToshibaManager 1/ToshibaManager/app.py`, une validation au chargement du module de `modele_xml/template_base.xml` (existence + `ET.parse` valide) qui arrête le processus avec un message clair sur stderr si invalide (research.md §5 ; FR-009) — dépend de T005 (même fichier)
- [X] T007 [P] Créer `ToshibaManager 1/ToshibaManager/docker-compose.yml` : service `app` construit depuis le Dockerfile, volume nommé `toshiba_data` monté sur `/app/uploads`, variable d'environnement `PORT` (défaut `5000`), `healthcheck` basé sur `/healthz`

**Checkpoint**: `docker compose up --build` construit et démarre l'image ; `/healthz` répond.

---

## Phase 3: User Story 1 - Déployer l'application sans installation manuelle (Priority: P1) 🎯 MVP

**Goal**: Démarrer ToshibaManager sur n'importe quelle machine avec un
moteur de conteneurs, en une seule commande, sans installer Python ni
dépendances manuellement (FR-001, FR-002, FR-005, FR-006, FR-009).

**Independent Test**: Sur une machine sans Python, `docker compose up --build`, puis hub/template/carnet d'adresses/SMTP tester accessibles comme en local (quickstart.md M1 étapes 1–3).

### Implementation for User Story 1

- [X] T008 [US1] Créer `ToshibaManager 1/ToshibaManager/entrypoint.sh` (utilise `$PORT`, défaut `5000`, lance `waitress-serve --port=$PORT app:app`) ; mettre à jour le Dockerfile pour le copier, le rendre exécutable et l'utiliser comme `CMD` (research.md §2 ; FR-005) — dépend de T004
- [X] T009 [US1] Vérifier/ajuster que les échecs de démarrage (port déjà utilisé, template par défaut manquant) provoquent un arrêt du conteneur avec code de sortie non-nul et message explicite dans `docker compose logs` (Edge Cases spec.md ; FR-009 ; SC-005) — dépend de T006, T008
- [X] T010 [US1] Exécuter les étapes 1 à 3 (+ 3b–3e) de `quickstart.md` (section M1) sur un environnement propre — y compris `/addressbook` (import + génération CSV), `/parametrage`, `/api/smtp/send-test-email`, et `/download-bat` — et corriger tout écart constaté dans Dockerfile/entrypoint.sh/app.py — dépend de T008, T009

**Checkpoint**: User Story 1 fonctionnelle et testable indépendamment — c'est le MVP.

---

## Phase 4: User Story 2 - Conserver les données entre redémarrages et mises à jour (Priority: P2)

**Goal**: Le template XML actif survit aux redémarrages et aux mises à jour d'image (FR-003, FR-007 ; data-model.md).

**Independent Test**: Importer un template personnalisé, redémarrer puis reconstruire l'image, revérifier que le template importé est toujours servi (quickstart.md M1 étapes 4–7).

### Implementation for User Story 2

- [X] T011 [US2] Confirmer/ajuster dans `ToshibaManager 1/ToshibaManager/docker-compose.yml` que le volume nommé `toshiba_data` est bien monté sur `/app/uploads` et survit à `docker compose down`/`up` (research.md §4) — dépend de T007
- [X] T012 [US2] Confirmer dans le Dockerfile que `modele_xml/template_base.xml` est copié dans l'image (et non dans le volume), pour qu'une mise à jour d'image livre un nouveau template par défaut sans toucher au template actif persistant — dépend de T004
- [X] T013 [US2] Exécuter les étapes 4 à 7 de `quickstart.md` (section M1 — persistance + reconstruction d'image) et corriger toute perte de données constatée — dépend de T011, T012

**Checkpoint**: User Stories 1 ET 2 fonctionnent indépendamment.

---

## Phase 5: User Story 3 - Ne jamais faire persister d'identifiants SMTP (Priority: P3)

**Goal**: Aucun identifiant SMTP saisi dans le testeur n'est écrit sur disque ni journalisé (FR-004 ; data-model.md).

**Independent Test**: Effectuer un test SMTP, puis grep du volume et des logs du conteneur pour confirmer l'absence du mot de passe utilisé (quickstart.md M1 étapes 8–10).

### Implementation for User Story 3

- [X] T014 [US3] Auditer les routes `smtp_test_connection` et `smtp_send_test_email` dans `ToshibaManager 1/ToshibaManager/app.py` : confirmer qu'aucun message d'erreur/log ne contient le mot de passe soumis ; ajouter un commentaire documentant cette garantie
- [X] T015 [US3] Configurer un niveau de log explicite (non verbeux) pour Waitress dans `ToshibaManager 1/ToshibaManager/entrypoint.sh` (ou Dockerfile) afin qu'aucun corps de requête ne soit journalisé — dépend de T008
- [X] T016 [US3] Exécuter les étapes 8 à 10 de `quickstart.md` (section M1 — grep volume/logs pour le mot de passe de test) et confirmer l'absence de toute trace — dépend de T014, T015

**Checkpoint**: Les trois user stories fonctionnent indépendamment — périmètre M1 complet.

---

## Phase 6: Exposition publique via nom de domaine (FR-010 à FR-012 — itération M2, non bloquante pour le MVP)

**Goal**: Rendre l'application joignable depuis Internet via un nom de
domaine, auto-hébergée, avec HTTPS et authentification obligatoire
(contracts/http-routes.md § reverse proxy ; research.md §6–7).

**Independent Test**: `docker compose --profile public up --build`, puis
`quickstart.md` section M2 (HTTPS valide, 401 sans identifiants, 200 avec).

- [X] T017 [P] Créer `reverse-proxy/Caddyfile` (nom de domaine, TLS automatique, `basic_auth`) — research.md §6–7
- [X] T018 Ajouter un service Caddy sous un profil `public` dans `ToshibaManager 1/ToshibaManager/docker-compose.yml`, l'app restant joignable uniquement sur le réseau Docker interne — dépend de T017, T007
- [X] T019 [P] Créer `ToshibaManager 1/ToshibaManager/.env.example` documentant `DOMAIN`, `BASIC_AUTH_USER`, `BASIC_AUTH_PASSWORD_HASH` (aucun secret réel commité)
- [ ] T020 Exécuter les étapes 1 à 4 de `quickstart.md` (section M2) une fois un nom de domaine réel disponible, et corriger tout problème TLS/auth constaté — dépend de T018, T019

**Checkpoint**: Accès public authentifié en HTTPS opérationnel.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Finitions transverses, ne bloquent aucune user story

- [X] T021 [P] Créer `ToshibaManager 1/ToshibaManager/README.md` documentant le build/run Docker et renvoyant vers `quickstart.md`
- [X] T022 Vérifier que le Dockerfile n'embarque pas inutilement `toshiba_template.py` (prototype legacy non utilisé par `app.py`), ou documenter que sa présence est sans effet
- [X] T023 Rejouer intégralement `quickstart.md` (M1 puis M2 si déployé) de bout en bout avant de considérer la feature terminée, conformément au Principe V (Vérification manuelle) de la constitution — M1 rejoué en direct (build+run réel via WSL Docker) ; M2 non applicable (pas de domaine déployé, voir T020)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: aucune dépendance — démarre immédiatement
- **Foundational (Phase 2)**: dépend de Setup — bloque toutes les user stories
- **User Stories (Phase 3–5)**: dépendent toutes de Foundational ; peuvent ensuite avancer en parallèle ou dans l'ordre de priorité P1 → P2 → P3
- **M2 (Phase 6)**: dépend de Foundational (T007) ; indépendante des Phases 3–5 mais logiquement livrée après le MVP
- **Polish (Phase 7)**: dépend des phases livrées que l'on souhaite finaliser

### User Story Dependencies

- **US1 (P1)**: démarre après Foundational — aucune dépendance aux autres stories
- **US2 (P2)**: démarre après Foundational — s'appuie sur les mêmes fichiers Dockerfile/compose que US1 mais reste testable indépendamment (T011/T012 ajustent, ne recréent pas)
- **US3 (P3)**: démarre après Foundational — indépendante, porte sur l'audit du code SMTP existant

### Parallel Opportunities

- T001, T002, T003 (Setup) en parallèle
- T004, T005, T007 (Foundational, fichiers différents) en parallèle ; T006 doit suivre T005 (même fichier `app.py`)
- Une fois Foundational terminée : US1, US2, US3 peuvent être menées par des personnes différentes en parallèle (chacune reste indépendamment testable)
- T017, T019 (Phase 6, fichiers différents) en parallèle

---

## Parallel Example: Foundational

```bash
# Une fois Setup terminé, lancer en parallèle :
Task: "Écrire Dockerfile dans ToshibaManager 1/ToshibaManager/Dockerfile"
Task: "Ajouter GET /healthz dans ToshibaManager 1/ToshibaManager/app.py"
Task: "Créer docker-compose.yml dans ToshibaManager 1/ToshibaManager/docker-compose.yml"
```

---

## Implementation Strategy

### MVP First (User Story 1 uniquement)

1. Phase 1 (Setup) → Phase 2 (Foundational) → Phase 3 (US1)
2. **STOP et VALIDER** : `quickstart.md` M1 étapes 1–3 passent
3. C'est le MVP : l'application tourne en conteneur, sans installation manuelle

### Incremental Delivery

1. Setup + Foundational → base prête
2. US1 → valider indépendamment → MVP démontrable
3. US2 → valider indépendamment (persistance) → toujours démontrable
4. US3 → valider indépendamment (pas de fuite d'identifiants) → périmètre M1 complet
5. Phase 6 (M2) → quand un nom de domaine est prêt, exposition publique authentifiée
6. Phase 7 (Polish) → documentation et vérification finale

## Notes

- Aucune tâche de test automatisé : la vérification passe par les parcours
  manuels de `quickstart.md`, référencés explicitement dans chaque phase
  (constitution Principe V, non négociable).
- [P] = fichiers différents, pas de dépendance entre les tâches marquées.
- Chaque user story (US1/US2/US3) reste indépendamment testable — voir
  "Independent Test" de chaque phase.
- La Phase 6 (M2) n'est pas bloquante pour livrer le MVP (US1 seule) ni pour
  le périmètre complet M1 (US1+US2+US3).
