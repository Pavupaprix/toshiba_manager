# Phase 0 Research: Conteneurisation de ToshibaManager

## 1. Version de Python et image de base

**Decision**: `python:3.12-slim` comme image de base.

**Rationale**: Le dépôt ne fixe aucune version (bytecode caché trouvé pour
cpython-310 *et* cpython-314 dans `__pycache__/`, signe que l'app a tourné
sous plusieurs versions sans code spécifique à l'une d'elles). 3.12 est une
version stable, activement maintenue, pleinement compatible avec Flask et
openpyxl. La variante `slim` réduit la taille de l'image (pas besoin d'outils
de compilation : aucune dépendance native lourde).

**Alternatives considered**:
- `python:3.12-alpine` — image plus petite mais `musl libc` complique parfois
  l'installation de roues (`wheels`) précompilées pour des libs comme
  openpyxl/lxml ; rejeté pour éviter une dépendance de build supplémentaire
  sur un projet simple (Principe I — Simplicity First).
- Épingler 3.10 (version la plus ancienne observée) — pas de raison
  technique de rester sur une version plus ancienne ; 3.12 apporte des
  correctifs de sécurité actifs.

## 2. Serveur d'application en production

**Decision**: Waitress comme serveur WSGI de production.

**Rationale**: `app.run(debug=True, port=5000)` est explicitement un serveur
de développement (rechargement automatique, débogueur interactif exposé) —
inadapté à un déploiement réel (FR-005). Waitress est pur-Python (aucune
dépendance système à compiler, contrairement à Gunicorn qui repose sur des
primitives POSIX absentes/instables historiquement sous certains contextes
Windows), ce qui garde le Dockerfile simple et le comportement identique
que l'image soit construite/testée depuis un poste Windows ou Linux.

**Alternatives considered**:
- Gunicorn — standard côté Linux, mais ajoute une dépendance native et un
  modèle multi-worker que ce projet à faible charge ne nécessite pas
  (Principe I) ; Waitress suffit pour "quelques utilisateurs simultanés".
- Garder `app.run()` avec `debug=False` — viable mais reste un serveur de
  développement non conçu pour tenir la charge ni pour la robustesse réseau
  en continu ; rejeté au profit d'un serveur pensé pour tourner en service.

## 3. Fichier de dépendances

**Decision**: `requirements.txt` avec versions figées :
`Flask`, `openpyxl`, `waitress` (+ leurs dépendances transitives résolues au
build).

**Rationale**: Aucun fichier de dépendances n'existe aujourd'hui — les
imports observés dans `app.py`/`addressbook.py` sont Flask, openpyxl, et la
bibliothèque standard (`smtplib`, `ssl`, `xml.etree.ElementTree`, `csv`,
`uuid`, `time`, `datetime`, `email.mime.text`). Fixer des versions garantit
une image reproductible (aligné avec FR-001/SC-001 : "ça marche pareil
partout").

**Alternatives considered**: Ne pas figer de versions (`flask`, `openpyxl`
sans contrainte) — rejeté : casse la reproductibilité, un correctif amont
pourrait changer le comportement entre deux builds de l'image sans que rien
n'ait changé côté projet.

## 4. Persistance des données

**Decision**: Un volume Docker nommé monté sur le dossier `uploads/` de
l'application (qui contient `templates.xml`, le template actif). Le
template par défaut (`modele_xml/template_base.xml`) est copié dans l'image
elle-même (contenu versionné avec le code, pas dans le volume).

**Rationale**: FR-003 exige que le template actif survive aux redémarrages
*et* aux mises à jour d'image ; un volume nommé (plutôt qu'un volume anonyme
ou un simple dossier dans le conteneur) survit explicitement à
`docker rm`/recréation du conteneur, ce qui correspond au scénario
"remplacer par une nouvelle version de l'image" de US2. Le template par
défaut, lui, fait partie du code livré (comme aujourd'hui dans le dépôt) et
n'a pas besoin d'être modifiable en dehors d'un nouveau build.

**Alternatives considered**:
- Bind mount vers un dossier de l'hôte — plus visible/inspectable
  manuellement, mais lie le déploiement à un chemin hôte précis ; un volume
  nommé reste portable entre machines (cohérent avec FR-001 : déployer sur
  "n'importe quel poste ou serveur"). Le bind mount reste une option
  documentée dans quickstart.md pour qui préfère inspecter les fichiers
  directement.
- Aucune persistance (tout dans l'image) — rejeté : viole FR-003/US2
  directement (perte de données à chaque mise à jour).

## 5. Validation du template par défaut au démarrage

**Decision**: Au démarrage du conteneur, l'application valide que
`modele_xml/template_base.xml` existe et est un XML bien formé (réutilise
`xml.etree.ElementTree.parse`, déjà utilisé ailleurs dans `app.py`) ; en cas
d'échec, le processus s'arrête avec un message d'erreur explicite sur la
sortie standard (visible via `docker logs`).

**Rationale**: Couvre l'edge case du spec ("fichier par défaut manquant ⇒
erreur explicite", SC-005/FR-009) sans attendre qu'un utilisateur clique sur
la page Template pour découvrir le problème — un échec de build d'image mal
formé est détecté immédiatement au lancement plutôt que silencieusement.

**Alternatives considered**: Ne valider qu'à la demande (comportement actuel
de la route `/api/load-default`) — laissé tel quel *en complément*, mais
insuffisant seul : un opérateur qui déploie une image cassée ne le
découvrirait qu'au premier clic d'un utilisateur, ce qui retarde le
diagnostic (contraire à SC-005 : "moins d'une minute").

## 6. Exposition publique et HTTPS (M2)

**Decision**: Un reverse proxy Caddy en frontal, responsable du nom de
domaine, du certificat TLS (renouvellement automatique via Let's Encrypt),
et du routage HTTP → conteneur applicatif interne. L'application Flask elle
-même continue de parler HTTP simple à l'intérieur du réseau Docker interne.

**Rationale**: FR-010/FR-012 demandent un nom de domaine public et du HTTPS
sans imposer d'implémentation précise. Déléguer TLS au reverse proxy évite
d'ajouter de la gestion de certificats dans le code applicatif (Principe I —
Simplicity First) et est le patron standard pour exposer une app interne sur
Internet depuis un réseau auto-hébergé (redirection de port sur le routeur
du domicile vers le seul reverse proxy, pas vers l'app directement).

**Alternatives considered**:
- Nginx + Certbot manuel — plus répandu mais demande une gestion explicite
  du renouvellement de certificat ; rejeté au profit de la simplicité du
  renouvellement automatique intégré à Caddy pour ce projet à faible
  effectif de maintenance.
- Terminer TLS directement dans Flask (`ssl_context=...`) — mélange
  responsabilité réseau/sécurité et code métier, plus difficile à faire
  évoluer (changement de domaine, ajout d'un deuxième service) ; rejeté.

## 7. Authentification pour l'accès public (M2)

**Decision**: Authentification HTTP Basic au niveau du reverse proxy
(Caddy), avec un identifiant/mot de passe partagé stocké en variable
d'environnement (jamais dans l'image ni dans le dépôt), avant que toute
requête n'atteigne l'application.

**Rationale**: FR-011 exige qu'aucune fonctionnalité ne soit accessible
anonymement une fois l'app publique, sans imposer de mécanisme précis. Faire
porter l'authentification par le reverse proxy évite d'ajouter du code de
gestion de sessions/mots de passe dans l'application Flask elle-même
(Principe I), et protège FR-011 *avant même* que la requête n'atteigne le
code applicatif (défense en profondeur minimale). Cohérent avec le scope de
la feature : quelques utilisateurs internes, pas un système multi-comptes.

**Alternatives considered**:
- Authentification applicative (login Flask avec sessions) — plus flexible
  (comptes nommés, révocation individuelle) mais ajoute une surface de code
  et une gestion de mots de passe à maintenir ; hors scope pour ce niveau
  d'usage (une poignée d'utilisateurs internes). Peut être reconsidéré si le
  nombre d'utilisateurs distincts augmente — noté comme évolution possible,
  pas comme décision actuelle.
- OAuth/SSO tiers — sur-dimensionné (Principe I) pour un outil interne à
  effectif réduit.

## 8. Utilisateur du conteneur et durcissement basique

**Decision**: Le conteneur applicatif tourne avec un utilisateur non-root
dédié (créé dans le Dockerfile), et le dossier `uploads/` (volume) lui
appartient.

**Rationale**: Bonne pratique standard de sécurité conteneur, cohérente avec
le Principe II (Data Safety) de la constitution — limite l'impact d'une
éventuelle faille applicative à un utilisateur sans privilège sur l'hôte.

**Alternatives considered**: Rester en root (image par défaut) — plus
simple à écrire mais dégrade l'isolement en cas de compromission ; rejeté,
le surcoût d'ajouter un utilisateur dans le Dockerfile est minime.

## Résumé des inconnues résolues

Toutes les entrées `NEEDS CLARIFICATION` du Technical Context ont été
tranchées ci-dessus (version Python, dépendances, serveur de production,
stratégie de persistance, validation au démarrage, TLS/auth pour M2). Aucune
inconnue restante avant Phase 1.
