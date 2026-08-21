#!/bin/sh
# Lance le serveur WSGI de production (Waitress) sur le port configuré.
# FR-005 : remplace le serveur de développement Flask (debug=True, rechargement
# automatique) par un serveur pensé pour tourner en service.
# Waitress ne journalise que la ligne de service au démarrage (pas de log
# par requête, donc pas de corps de requête ni d'identifiant SMTP journalisé
# — voir T014 pour l'audit des messages d'erreur applicatifs).
set -eu

PORT="${PORT:-5000}"

exec waitress-serve --port="$PORT" app:app
