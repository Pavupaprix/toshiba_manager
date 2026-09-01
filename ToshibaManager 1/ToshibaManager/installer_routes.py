"""Distribution du script d'installation des copieurs Toshiba.

Le technicien saisit l'adresse IP sur /installer et récupère un .bat déjà
paramétré. Sur le poste client, ce .bat s'élève en UAC, télécharge le toolkit
PowerShell, détecte le modèle du copieur en SNMP, en déduit le pilote, puis
télécharge l'archive correspondante et installe.

Le modèle est facultatif dans le formulaire : renseigné, il sert de valeur de
repli quand le SNMP ne répond pas, ce qui évite toute saisie sur le poste.

Tout le code de cette fonctionnalité vit ici : app.py ne fait qu'enregistrer
le blueprint, ce qui garantit que le reste de l'application n'est pas touché.
"""

import hashlib
import io
import ipaddress
import json
import os
import re
import zipfile

from flask import (Blueprint, abort, current_app, jsonify, render_template,
                   request, send_from_directory)

installer_bp = Blueprint('installer', __name__, url_prefix='/installer')

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INSTALLER_DIR = os.path.join(BASE_DIR, 'installer')

# Dossier des archives de pilotes, monté en lecture seule dans le conteneur.
DRIVERS_DIR = os.environ.get('DRIVERS_DIR') or os.path.join(BASE_DIR, 'drivers')

# Un modèle Toshiba est purement alphanumérique : 2010AC, 3525AC, 305CP, 409S.
MODELE_RE = re.compile(r'^[A-Za-z0-9]{3,10}$')

# Contenu du toolkit envoyé au poste client.
TOOLKIT_FICHIERS = (
    'Install-CopieurToshiba.ps1',
    'Export-ReglagesToshiba.ps1',
    'Diagnostic-Reglages.ps1',
    'Installer-Copieur.bat',
    'Exporter-Reglages.bat',
    'Diagnostiquer-Reglages.bat',
    'README.md',
)
TOOLKIT_DOSSIERS = ('lib', 'config', 'devmode')


# -------------------------
# Configuration partagée avec le script PowerShell
# -------------------------

def _lire_config(nom):
    chemin = os.path.join(INSTALLER_DIR, 'config', nom)
    with open(chemin, 'r', encoding='utf-8') as f:
        return json.load(f)


def _pilotes():
    return _lire_config('sources.json').get('pilotes', {})


def resoudre_pilote(modele):
    """Applique les règles de modeles.json, la première qui correspond gagne.

    Même logique que Resolve-Pilote dans Install-CopieurToshiba.ps1, pour que
    la page web et le poste client aboutissent au même pilote.
    """
    config = _lire_config('modeles.json')
    for regle in config.get('regles', []):
        if re.match(regle['motif'], modele, re.IGNORECASE):
            return regle['pilote']
    return config.get('piloteParDefaut', 'Universal')


def archives_disponibles():
    """Noms d'archives déclarés en configuration et réellement présents."""
    presents = {}
    for cle, definition in _pilotes().items():
        archive = definition.get('archive')
        if archive and os.path.isfile(os.path.join(DRIVERS_DIR, archive)):
            presents[cle] = archive
    return presents


# -------------------------
# Génération du .bat
# -------------------------

def _url_base():
    """URL publique du service.

    Derrière Nginx Proxy Manager, request.url_root peut annoncer http:// alors
    que le client a parlé en https. PUBLIC_BASE_URL tranche quand elle existe.
    """
    configuree = os.environ.get('PUBLIC_BASE_URL')
    if configuree:
        return configuree.rstrip('/')
    return request.url_root.rstrip('/')


GABARIT_BAT = r"""@echo off
setlocal
title Installation copieur TOSHIBA ({ip})

rem Genere par ToshibaManager. Ne pas modifier a la main :
rem regenerer depuis {base_url}/installer

set "IP={ip}"
set "OPTIONS={options}"
set "BASE={base_url}/installer"
rem Empreinte du toolkit : sans elle, un cache intermediaire peut renvoyer une
rem version anterieure du script, avec d'autres reglages par defaut.
set "VERSION={version}"
set "TRAVAIL=%TEMP%\InstallCopieurToshiba\%RANDOM%%RANDOM%"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation des privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo   Installation du copieur TOSHIBA sur %IP%
echo   ---------------------------------------------------
echo.

mkdir "%TRAVAIL%" 2>nul

echo   Telechargement des outils d'installation...
rem Une seule ligne par commande : dans cmd, un ^ place a l'interieur de
rem guillemets est un caractere litteral, pas une continuation de ligne.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%BASE%/toolkit.zip?v=%VERSION%' -OutFile '%TRAVAIL%\toolkit.zip' -UseBasicParsing -TimeoutSec 120"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%TRAVAIL%\toolkit.zip' -DestinationPath '%TRAVAIL%' -Force"

if not exist "%TRAVAIL%\Install-CopieurToshiba.ps1" (
    echo.
    echo   ECHEC : impossible de recuperer les outils depuis %BASE%
    echo   Verifier l'acces reseau au serveur, puis relancer.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%TRAVAIL%\Install-CopieurToshiba.ps1" ^
  -IP "%IP%" %OPTIONS% -SourceRacine "%BASE%/drivers"

set "CODE=%errorlevel%"
rd /s /q "%TRAVAIL%" 2>nul
exit /b %CODE%
"""


def generer_bat(ip, options):
    _, version = construire_toolkit()
    return GABARIT_BAT.format(ip=ip, options=options, version=version,
                              base_url=_url_base()).replace('\n', '\r\n')


# -------------------------
# Routes
# -------------------------

@installer_bp.route('/', strict_slashes=False)
def page():
    disponibles = archives_disponibles()
    pilotes = {cle: {'nomPilote': d.get('nomPilote'), 'libelle': d.get('libelle'),
                     'disponible': cle in disponibles}
               for cle, d in _pilotes().items()}
    return render_template('installer.html', pilotes=pilotes,
                           aucun_pilote=not disponibles)


@installer_bp.route('/bat', methods=['POST'])
def telecharger_bat():
    ip_brute = (request.form.get('ip') or '').strip()
    modele_brut = (request.form.get('modele') or '').strip().upper().replace(' ', '')

    # Ces valeurs finissent dans un fichier executable : rien d'autre qu'une IP
    # valide et un modele alphanumerique ne doit passer.
    try:
        ipaddress.ip_address(ip_brute)
    except ValueError:
        return jsonify({'error': f"Adresse IP invalide : {ip_brute or '(vide)'}"}), 400

    # Le modele est facultatif : laisse vide, il est detecte en SNMP sur place.
    if modele_brut and not MODELE_RE.match(modele_brut):
        return jsonify({'error': "Modèle invalide : 3 à 10 caractères alphanumériques attendus (ex. 3525AC)"}), 400

    pilote = (request.form.get('pilote') or '').strip()
    if pilote and pilote not in _pilotes():
        return jsonify({'error': f'Pilote inconnu : {pilote}'}), 400
    # Sans modele saisi, le pilote se deduit sur le poste, apres detection.
    if modele_brut and not pilote:
        pilote = resoudre_pilote(modele_brut)

    options = []
    if modele_brut:
        options.append(f'-Modele "{modele_brut}"')
    if pilote:
        options.append(f'-Pilote "{pilote}"')
    if request.form.get('couleur') == 'couleur':
        options.append('-Couleur')
    if request.form.get('rectoverso') == 'rectoverso':
        options.append('-RectoVerso')

    contenu = generer_bat(ip_brute, ' '.join(options))
    nom = f'Installer copieur ({ip_brute}).bat'

    return current_app.response_class(
        contenu.encode('ascii', 'replace'),
        mimetype='application/octet-stream',
        headers=dict(SANS_CACHE,
                     **{'Content-Disposition': f'attachment; filename="{nom}"'}))


def _fichiers_toolkit():
    """Chemins à embarquer, en couples (chemin disque, nom dans l'archive)."""
    for nom in TOOLKIT_FICHIERS:
        chemin = os.path.join(INSTALLER_DIR, nom)
        if os.path.isfile(chemin):
            yield chemin, nom
    for dossier in TOOLKIT_DOSSIERS:
        racine = os.path.join(INSTALLER_DIR, dossier)
        if not os.path.isdir(racine):
            continue
        for fichier in sorted(os.listdir(racine)):
            chemin = os.path.join(racine, fichier)
            # Les sauvegardes horodatées des DEVMODE n'ont rien à faire ici.
            if os.path.isfile(chemin) and not fichier.endswith('.bak'):
                yield chemin, f'{dossier}/{fichier}'


_toolkit_cache = {}


def construire_toolkit():
    """Archive du dossier installer/, construite en mémoire et retenue.

    Renvoie (octets, empreinte). L'empreinte va dans l'URL du .bat généré :
    Cloudflare met les .zip en cache pendant quatre heures, et une version
    figée du toolkit installerait des réglages qui ne sont plus ceux demandés.
    Un nom de fichier inchangé mais une requête différente suffit à forcer la
    récupération de la bonne version.
    """
    signature = tuple((nom, os.path.getmtime(c), os.path.getsize(c))
                      for c, nom in _fichiers_toolkit())
    if _toolkit_cache.get('signature') == signature:
        return _toolkit_cache['donnees'], _toolkit_cache['empreinte']

    memoire = io.BytesIO()
    with zipfile.ZipFile(memoire, 'w', zipfile.ZIP_DEFLATED) as archive:
        for chemin, nom in _fichiers_toolkit():
            # Date figée : sans elle l'archive change à chaque reconstruction de
            # l'image, et l'empreinte avec, obligeant tous les postes à
            # retélécharger un toolkit pourtant identique.
            entree = zipfile.ZipInfo(nom, date_time=(1980, 1, 1, 0, 0, 0))
            entree.compress_type = zipfile.ZIP_DEFLATED
            entree.external_attr = 0o644 << 16
            with open(chemin, 'rb') as f:
                archive.writestr(entree, f.read())

    donnees = memoire.getvalue()
    empreinte = hashlib.sha256(donnees).hexdigest()[:12]
    _toolkit_cache.update(signature=signature, donnees=donnees, empreinte=empreinte)
    return donnees, empreinte


# Interdit la mise en cache par les intermédiaires : Cloudflare met les .zip en
# cache par défaut, ce qui a déjà servi un toolkit périmé à un poste client.
SANS_CACHE = {
    'Cache-Control': 'no-store, no-cache, must-revalidate, private, max-age=0',
    'Pragma': 'no-cache',
    'Expires': '0',
}


@installer_bp.route('/toolkit.zip')
def toolkit():
    donnees, empreinte = construire_toolkit()
    entetes = dict(SANS_CACHE)
    entetes['Content-Disposition'] = 'attachment; filename="toolkit.zip"'
    entetes['X-Toolkit-Version'] = empreinte
    return current_app.response_class(donnees, mimetype='application/zip',
                                      headers=entetes)


@installer_bp.route('/drivers/<path:nom>')
def driver(nom):
    """Sert une archive de pilote.

    Le nom reçu n'est jamais utilisé pour construire un chemin : il doit
    correspondre exactement à une archive déclarée dans sources.json, sinon
    c'est un 404. C'est ce qui interdit la traversée de répertoire.
    """
    if nom not in archives_disponibles().values():
        abort(404)
    return send_from_directory(DRIVERS_DIR, nom, as_attachment=True)
