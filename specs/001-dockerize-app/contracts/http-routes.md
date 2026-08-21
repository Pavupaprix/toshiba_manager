# Contract: Surface HTTP exposée par le conteneur

Cette feature ne change pas les routes métier existantes de `app.py`
(inchangées, listées ici pour référence — voir le code pour le détail des
schémas de requête/réponse). Elle introduit une seule nouvelle interface :
un endpoint de santé, plus un point d'entrée réseau supplémentaire au niveau
du reverse proxy (M2).

## Routes existantes (inchangées)

| Méthode | Route | Rôle |
|---------|-------|------|
| GET | `/` | Page Template (accueil) |
| GET | `/hub` | Hub de navigation |
| GET | `/parametrage` | Page de paramétrage |
| GET | `/addressbook` | Page carnet d'adresses |
| GET | `/api/load-default` | Charge le template XML par défaut |
| GET | `/load-default-xml` | Variante legacy du chargement par défaut |
| POST | `/api/upload` | Importe un template XML (remplace le template actif) |
| GET | `/api/download` | Télécharge le template XML actif |
| GET | `/download-bat` | Télécharge `Toshiba+Partage.bat` |
| POST | `/api/addressbook/parse` | Analyse un classeur importé |
| POST | `/api/addressbook/generate` | Génère le CSV du carnet d'adresses |
| DELETE | `/api/groups/<gid>` | Supprime un groupe du template XML actif |
| GET | `/smtp-test` | Page testeur SMTP |
| POST | `/api/smtp/test-connection` | Teste une connexion SMTP |
| POST | `/api/smtp/send-test-email` | Envoie un e-mail de test SMTP |

## Nouvelle route : contrôle de santé

| Méthode | Route | Rôle |
|---------|-------|------|
| GET | `/healthz` | Répond `200 {"status":"ok"}` si l'application a démarré et que le template par défaut a été validé avec succès (research.md §5) ; répond `503` sinon. |

**Pourquoi**: nécessaire pour que l'orchestrateur de conteneur (Docker
Compose `healthcheck`, ou tout supervision future) détecte un démarrage
défaillant automatiquement, en complément du log d'erreur explicite (FR-009).
N'expose aucune donnée sensible ni détail d'implémentation.

## Point d'entrée réseau du reverse proxy (M2)

| Élément | Contrat |
|---------|---------|
| Domaine public (`https://<DOMAIN>`) | Toute requête doit présenter une authentification HTTP Basic valide avant d'être transmise à l'application ; sinon réponse `401` avec en-tête `WWW-Authenticate`, aucune donnée applicative renvoyée (FR-011, SC-006). |
| TLS | Certificat valide géré automatiquement par le reverse proxy (research.md §6) ; toute requête HTTP en clair est redirigée vers HTTPS. |
| Transmission interne | Reverse proxy → conteneur applicatif en HTTP simple sur le réseau Docker interne (non exposé à l'extérieur du host). |
