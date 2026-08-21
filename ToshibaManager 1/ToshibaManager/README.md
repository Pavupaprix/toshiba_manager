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

## Vérification

Voir [../../specs/001-dockerize-app/quickstart.md](../../specs/001-dockerize-app/quickstart.md)
pour le parcours de validation complet (M1 et M2).
