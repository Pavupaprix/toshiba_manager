# Quickstart: Valider la conteneurisation de ToshibaManager

Ce guide prouve que les scénarios d'acceptation du [spec.md](./spec.md)
fonctionnent une fois l'image construite. Pas de code d'implémentation ici
— voir [plan.md](./plan.md), [research.md](./research.md) et
[data-model.md](./data-model.md) pour les décisions détaillées, et
`tasks.md` (généré par `/speckit-tasks`) pour le détail des étapes de build.

## Prérequis

- Docker (et Docker Compose) installés sur la machine de test.
- Être dans `ToshibaManager 1/ToshibaManager/` (contexte de build, voir
  `plan.md` → Project Structure).

## M1 — Conteneur seul, en local/LAN

```bash
docker compose up --build
```

**Vérifie US1 (P1) — déploiement sans installation manuelle** :
1. Ouvrir `http://localhost:5000/hub` dans un navigateur → le hub s'affiche
   sans erreur (Acceptance Scenario 1).
2. Ouvrir `http://localhost:5000/` (page Template) → le template XML par
   défaut se charge (Acceptance Scenario 2).
3. Ouvrir `http://localhost:5000/healthz` → répond `200 {"status":"ok"}`.
3b. Ouvrir `/addressbook`, importer un classeur test, générer le CSV → téléchargement réussi, identique au local (FR-002).
3c. Ouvrir `/parametrage` → les deux cartes (Template / Carnet d'adresses) s'affichent et redirigent correctement.
3d. Sur `/smtp-test`, envoyer un e-mail de test (`/api/smtp/send-test-email`) avec des identifiants valides → succès identique au local.
3e. Cliquer le logo (téléchargement de `Toshiba+Partage.bat` via `/download-bat`) → fichier téléchargé, identique à l'original (FR-008).

**Vérifie US2 (P2) — persistance** :
4. Sur la page Template, importer un fichier XML personnalisé.
5. `docker compose down && docker compose up -d` (redémarrage complet).
6. Retélécharger le template (`/api/download`) → doit être le fichier
   importé à l'étape 4, pas le template par défaut (Acceptance Scenario 1).
7. Reconstruire l'image (`docker compose up --build -d`) après un
   changement de code trivial → revérifier l'étape 6 (Acceptance Scenario 2 :
   une mise à jour ne perd pas les données).

**Vérifie US3 (P3) — pas de persistance des identifiants SMTP** :
8. Sur `/smtp-test`, effectuer un test de connexion avec un email et un mot
   de passe quelconques.
9. Inspecter le volume : `docker compose exec app sh -c "grep -R 'MOT_DE_PASSE_UTILISE' /app/uploads || echo 'absent, OK'"`
   → doit afficher "absent, OK".
10. `docker compose logs app | grep 'MOT_DE_PASSE_UTILISE'` → aucune sortie
    (les identifiants ne doivent apparaître dans aucun log).

**Vérifie les Edge Cases** :
11. Arrêter le conteneur, démarrer un second conteneur sur le même port déjà
    occupé → le démarrage échoue avec un message clair dans les logs (pas un
    crash silencieux).
12. Construire une image sans `modele_xml/template_base.xml` (retiré
    temporairement) → `docker compose up` doit s'arrêter avec un message
    d'erreur explicite (voir research.md §5), et `/healthz` renvoie `503`
    tant que ce n'est pas corrigé.

## M2 — Exposition publique via nom de domaine (à terme)

Prérequis additionnels : un nom de domaine pointant vers l'IP publique de
l'hébergement, redirection de port du routeur du domicile vers le reverse
proxy uniquement (pas directement vers le conteneur applicatif).

```bash
docker compose --profile public up --build
```

**Vérifie FR-010/FR-012 — accès public en HTTPS** :
1. Depuis un réseau externe, ouvrir `https://<DOMAIN>` → certificat TLS
   valide, pas d'avertissement navigateur.
2. Ouvrir `http://<DOMAIN>` → redirection automatique vers `https://`.

**Vérifie FR-011/SC-006 — authentification obligatoire** :
3. Ouvrir `https://<DOMAIN>/hub` sans identifiants → réponse `401`, aucune
   donnée du hub visible.
4. Fournir les identifiants configurés (`BASIC_AUTH_USER` /
   `BASIC_AUTH_PASSWORD_HASH`) → accès au hub identique au comportement
   local (SC-007).

## Nettoyage

```bash
docker compose down -v   # supprime aussi le volume toshiba_data — à ne faire que sur un environnement de test
```
