"""Generation du script d'installation d'un poste Windows.

Le technicien renseigne le client, coche les applications, choisit les reglages
Windows et les comptes locaux sur /poste, et recupere un ZIP a lancer sur le
poste : le toolkit PowerShell plus un config.json qui decrit exactement ce qui a
ete demande.

Deux choses sont volontairement asymetriques, et c'est ce qui rend l'ensemble
sur :

  - le ZIP contient les mots de passe en clair (acces sans surveillance, comptes
    locaux) : il n'est telechargeable que depuis /poste, derriere le Basic Auth
    du reverse proxy, et rien n'est ecrit sur le serveur ;
  - les binaires des outils ne sont pas des secrets mais pesent 150 Mo : ils
    restent sur le serveur et le poste les recupere via /poste/outils/<nom>, la
    seule route de la feature ouverte sans authentification.

Tout le code de la fonctionnalite vit ici : app.py ne fait qu'enregistrer le
blueprint, ce qui garantit que le reste de l'application n'est pas touche.
"""

import hashlib
import io
import json
import os
import re
import unicodedata
import zipfile
from datetime import datetime

from flask import (Blueprint, abort, current_app, render_template, request,
                   send_from_directory)

poste_bp = Blueprint('poste', __name__, url_prefix='/poste')

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
POSTE_DIR = os.path.join(BASE_DIR, 'poste')

# Dossier des installeurs specifiques, monte en lecture seule dans le conteneur.
# En developpement il n'y a pas de montage : on retombe sur le dossier outils/
# de la racine du depot, celui-la meme que docker-compose monte, plutot que
# d'obliger a garder deux copies de 152 Mo.
_OUTILS_RACINE_DEPOT = os.path.abspath(os.path.join(BASE_DIR, '..', '..', 'outils'))
OUTILS_DIR = (os.environ.get('OUTILS_DIR')
              or os.path.join(BASE_DIR, 'outils'))
if not os.environ.get('OUTILS_DIR') and not os.path.isdir(OUTILS_DIR) \
        and os.path.isdir(_OUTILS_RACINE_DEPOT):
    OUTILS_DIR = _OUTILS_RACINE_DEPOT

# Contenu du toolkit envoye au poste client.
TOOLKIT_FICHIERS = (
    'Installer-Poste.bat',
    'Install-Poste.ps1',
    'README.md',
)
TOOLKIT_DOSSIERS = ('lib', 'config')

# Convention OMB : le mot de passe d'un poste client se derive de son code.
GABARIT_MOT_DE_PASSE = 'OmbI@{code}'

# Marqueur pose par la page dans les champs pre-remplis a partir du code client.
# Il n'est remplace qu'ici, a la generation : le mot de passe reel ne fait donc
# jamais l'aller-retour par un champ cache du formulaire.
JETON_CODE = '{code}'

# Ces valeurs finissent dans un fichier execute en administrateur sur le poste
# d'un client : tout ce qui n'est pas explicitement autorise est refuse.
RE_COMPTE = re.compile(r'^[A-Za-z0-9._-]{1,20}$')
RE_MACHINE = re.compile(r'^[A-Za-z0-9-]{1,15}$')
RE_TRIGRAMME = re.compile(r'^[A-Z0-9]{2,6}$')
RE_CODE_CLIENT = re.compile(r'^[A-Za-z0-9-]{1,16}$')

# Noms deja pris par Windows : les creer echouerait, ou pire, toucherait a un
# compte systeme. La comparaison se fait en minuscules.
COMPTES_RESERVES = {
    'administrateur', 'administrator', 'admin', 'system', 'systeme',
    'guest', 'invite', 'defaultaccount', 'wdagutilityaccount', 'public',
}

UAC_VALEURS = ('inchange', 'sansConfirmation', 'desactive')

REGLAGES_WINDOWS = ('extensionsVisibles', 'paveNumerique', 'supprimerPubs',
                    'desactiverDemarrageRapide')

# Le seul logiciel que le script a le droit de desinstaller.
DESINSTALLATION_AUTORISEE = 'CCleaner'


class ErreurFormulaire(ValueError):
    """Saisie invalide : le message est affichable tel quel au technicien."""


# -------------------------
# Catalogue
# -------------------------

def _catalogue():
    chemin = os.path.join(POSTE_DIR, 'config', 'catalogue.json')
    with open(chemin, 'r', encoding='utf-8') as f:
        return json.load(f)


def outils_disponibles():
    """Fichiers declares au catalogue et reellement presents sur le serveur.

    Sert a la fois a griser les cases sur la page et de liste blanche pour la
    route de telechargement.
    """
    presents = {}
    for app in _catalogue()['applications']:
        fichier = app.get('fichier')
        if fichier and os.path.isfile(os.path.join(OUTILS_DIR, fichier)):
            presents[app['id']] = fichier
    return presents


def _url_base():
    """URL publique du service.

    Derriere un reverse proxy, request.url_root peut annoncer http:// alors que
    le client a parle en https. PUBLIC_BASE_URL tranche quand elle existe.
    """
    configuree = os.environ.get('PUBLIC_BASE_URL')
    if configuree:
        return configuree.rstrip('/')
    return request.url_root.rstrip('/')


# -------------------------
# Lecture et validation du formulaire
# -------------------------

def _texte(nom, maximum=80):
    return (request.form.get(nom) or '').strip()[:maximum]


def _coche(nom):
    return request.form.get(nom) in ('1', 'on', 'true')


def _valider_comptes(brut, mot_de_passe_derive):
    """Les comptes arrivent en JSON : les cases decochees ne se postent pas."""
    if not brut:
        return []
    try:
        comptes = json.loads(brut)
    except ValueError:
        raise ErreurFormulaire('Liste des comptes illisible, rechargez la page.')
    if not isinstance(comptes, list):
        raise ErreurFormulaire('Liste des comptes illisible, rechargez la page.')

    valides = []
    vus = set()
    autologons = 0
    for compte in comptes[:10]:
        if not isinstance(compte, dict):
            raise ErreurFormulaire('Liste des comptes illisible, rechargez la page.')
        nom = str(compte.get('nom', '')).strip()
        if not nom:
            continue
        if not RE_COMPTE.match(nom):
            raise ErreurFormulaire(
                'Nom de compte invalide : ' + nom + '. 1 à 20 caractères, '
                'lettres, chiffres, point, tiret ou souligné.')
        if nom.lower() in COMPTES_RESERVES:
            raise ErreurFormulaire(
                nom + ' est un nom réservé par Windows, choisissez-en un autre.')
        if nom.lower() in vus:
            raise ErreurFormulaire('Le compte ' + nom + ' est saisi deux fois.')
        vus.add(nom.lower())

        mot_de_passe = str(compte.get('motDePasse', ''))
        derive = mot_de_passe == JETON_CODE
        if derive:
            mot_de_passe = mot_de_passe_derive

        autologon = bool(compte.get('autologon'))
        if autologon:
            autologons += 1
            if autologons > 1:
                raise ErreurFormulaire(
                    'Un seul compte peut être en ouverture de session automatique.')
            if not mot_de_passe:
                raise ErreurFormulaire(
                    nom + ' est en connexion automatique : Windows exige un '
                    'mot de passe pour cela.')

        valides.append({
            'nom': nom,
            'motDePasse': mot_de_passe,
            'admin': bool(compte.get('admin')),
            'motDePasseNExpireJamais': bool(compte.get('motDePasseNExpireJamais', True)),
            'autologon': autologon,
            '_derive': derive,
        })
    return valides


def construire_config():
    """Traduit le formulaire en config.json. Leve ErreurFormulaire si invalide."""
    catalogue = _catalogue()
    par_id = {a['id']: a for a in catalogue['applications']}

    client = _texte('client')
    code_client = _texte('codeClient', 16)
    trigramme = _texte('trigramme', 6).upper()

    if code_client and not RE_CODE_CLIENT.match(code_client):
        raise ErreurFormulaire(
            'Code client invalide : lettres, chiffres et tirets uniquement.')
    if trigramme and not RE_TRIGRAMME.match(trigramme):
        raise ErreurFormulaire(
            'Trigramme invalide : 2 à 6 lettres ou chiffres, sans accent.')

    mot_de_passe_derive = (GABARIT_MOT_DE_PASSE.format(code=code_client)
                           if code_client else '')

    # Applications cochees, parcourues dans l'ordre du catalogue : c'est lui qui
    # porte les dependances (VCRedist avant LibreOffice).
    choisies = set(request.form.getlist('app'))
    inconnues = choisies - set(par_id)
    if inconnues:
        raise ErreurFormulaire('Application inconnue : ' + ', '.join(sorted(inconnues)))

    disponibles = outils_disponibles()
    applications = []
    prerequis = []
    for app in catalogue['applications']:
        if app['id'] not in choisies:
            continue
        if app['source'] == 'outil' and app['id'] not in disponibles:
            raise ErreurFormulaire(
                "L'installeur de " + app['nom'] + " est absent du serveur : "
                'déposez-le dans outils/ puis rechargez la page.')
        for cle in app.get('prerequis', []):
            if cle not in prerequis:
                prerequis.append(cle)
        applications.append(app)

    implicites = catalogue.get('implicites', {})
    entete = [dict(implicites[c], id=c, source='winget', categorie='implicite')
              for c in prerequis if c in implicites]

    # AnyDesk sans mot de passe : l'acces sans surveillance ne servirait a rien.
    anydesk = None
    anydesk_derive = False
    if 'anydesk' in choisies:
        mot_de_passe = request.form.get('anydeskMotDePasse') or ''
        anydesk_derive = mot_de_passe == JETON_CODE
        if anydesk_derive:
            mot_de_passe = mot_de_passe_derive
        if not mot_de_passe:
            raise ErreurFormulaire(
                'AnyDesk est coché : renseignez le code client, ou saisissez '
                "directement le mot de passe d'accès sans surveillance.")
        anydesk = {'motDePasse': mot_de_passe}

    renommer = _coche('renommerPoste')
    # Volontairement pas tronque a 15 : un nom trop long doit etre refuse, pas
    # raccourci en silence. Le poste porterait sinon un autre nom que celui lu
    # a l'ecran, et deux postes pourraient se retrouver avec le meme.
    nom_poste = _texte('nomPoste', 64).upper()
    if renommer:
        if not nom_poste:
            raise ErreurFormulaire('Renommage demandé mais nom du poste vide.')
        if not RE_MACHINE.match(nom_poste):
            raise ErreurFormulaire(
                'Nom de poste invalide : ' + nom_poste + '. 15 caractères '
                'maximum, lettres, chiffres et tirets.')
        if nom_poste.strip('-') != nom_poste:
            raise ErreurFormulaire(
                'Le nom du poste ne peut ni commencer ni finir par un tiret.')
        if nom_poste.isdigit():
            raise ErreurFormulaire(
                'Le nom du poste ne peut pas être uniquement numérique.')

    uac = _texte('uac', 20) or 'inchange'
    if uac not in UAC_VALEURS:
        raise ErreurFormulaire('Réglage UAC inconnu.')

    comptes = _valider_comptes(request.form.get('comptes'), mot_de_passe_derive)

    # Le code client n'est exige que s'il sert vraiment a quelque chose : c'est
    # lui qui fournit le mot de passe partout ou le technicien n'en a pas saisi.
    if not code_client:
        besoin = []
        if anydesk_derive:
            besoin.append('le mot de passe AnyDesk')
        if any(c['_derive'] for c in comptes):
            besoin.append('le mot de passe des comptes locaux')
        if besoin:
            raise ErreurFormulaire(
                'Le code client est obligatoire : il fournit '
                + ' et '.join(besoin) + '.')

    for compte in comptes:
        compte.pop('_derive', None)

    navigateur = None
    if 'chrome' in choisies and _coche('navigateurParDefaut'):
        navigateur = 'chrome'

    windows = {'uac': uac}
    for cle in REGLAGES_WINDOWS:
        windows[cle] = _coche(cle)
    windows['desinstaller'] = ([DESINSTALLATION_AUTORISEE]
                               if _coche('desinstallerCcleaner') else [])

    return {
        'genereLe': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'client': client,
        'codeClient': code_client,
        'trigramme': trigramme,
        'baseUrl': _url_base(),
        'poste': {'renommer': renommer, 'nom': nom_poste},
        'applications': entete + applications,
        'anydesk': anydesk,
        'navigateurParDefaut': navigateur,
        'windows': windows,
        'comptes': comptes,
    }


# -------------------------
# Toolkit
# -------------------------

def _fichiers_toolkit():
    """Chemins a embarquer, en couples (chemin disque, nom dans l'archive)."""
    for nom in TOOLKIT_FICHIERS:
        chemin = os.path.join(POSTE_DIR, nom)
        if os.path.isfile(chemin):
            yield chemin, nom
    for dossier in TOOLKIT_DOSSIERS:
        racine = os.path.join(POSTE_DIR, dossier)
        if not os.path.isdir(racine):
            continue
        for fichier in sorted(os.listdir(racine)):
            chemin = os.path.join(racine, fichier)
            if os.path.isfile(chemin):
                yield chemin, dossier + '/' + fichier


_toolkit_cache = {}


def construire_toolkit():
    """Fichiers du toolkit, lus une fois et retenus. Renvoie (liste, empreinte).

    Meme motif que installer_routes.construire_toolkit : l'empreinte ne bouge
    que si un fichier bouge, ce qui rend le ZIP genere reproductible a saisie
    identique.
    """
    signature = tuple((nom, os.path.getmtime(c), os.path.getsize(c))
                      for c, nom in _fichiers_toolkit())
    if _toolkit_cache.get('signature') == signature:
        return _toolkit_cache['fichiers'], _toolkit_cache['empreinte']

    fichiers = []
    for chemin, nom in _fichiers_toolkit():
        with open(chemin, 'rb') as f:
            fichiers.append((nom, f.read()))

    condense = hashlib.sha256()
    for nom, donnees in fichiers:
        condense.update(nom.encode('utf-8'))
        condense.update(donnees)
    empreinte = condense.hexdigest()[:12]

    _toolkit_cache.update(signature=signature, fichiers=fichiers, empreinte=empreinte)
    return fichiers, empreinte


def construire_zip(config):
    """Toolkit + config.json, zippes en memoire.

    Dates figees : sans elles l'archive change a chaque generation, et deux ZIP
    produits avec la meme saisie ne seraient plus comparables.
    """
    fichiers, empreinte = construire_toolkit()
    config = dict(config, toolkit=empreinte)

    memoire = io.BytesIO()
    with zipfile.ZipFile(memoire, 'w', zipfile.ZIP_DEFLATED) as archive:
        contenu = list(fichiers)
        contenu.append(('config.json',
                        json.dumps(config, indent=2, ensure_ascii=False).encode('utf-8')))
        for nom, donnees in contenu:
            entree = zipfile.ZipInfo(nom, date_time=(1980, 1, 1, 0, 0, 0))
            entree.compress_type = zipfile.ZIP_DEFLATED
            entree.external_attr = 0o644 << 16
            archive.writestr(entree, donnees)
    return memoire.getvalue()


def _nom_fichier(config):
    """Nom du ZIP : lisible par le technicien, sans caractere interdit."""
    base = config['client'] or config['poste']['nom'] or 'poste'
    base = unicodedata.normalize('NFKD', base).encode('ascii', 'ignore').decode()
    base = re.sub(r'[^A-Za-z0-9 ._-]', '', base).strip() or 'poste'
    return 'Installation PC (' + base + ').zip'


# Interdit la mise en cache par les intermediaires : le ZIP contient des mots de
# passe, il n'a rien a faire dans le cache d'un proxy.
SANS_CACHE = {
    'Cache-Control': 'no-store, no-cache, must-revalidate, private, max-age=0',
    'Pragma': 'no-cache',
    'Expires': '0',
}


# -------------------------
# Routes
# -------------------------

@poste_bp.route('/', strict_slashes=False)
def page():
    catalogue = _catalogue()
    disponibles = outils_disponibles()
    applications = [dict(a, disponible=(a['source'] != 'outil' or a['id'] in disponibles))
                    for a in catalogue['applications']]
    return render_template('poste.html',
                           categories=catalogue['categories'],
                           applications=applications,
                           annee_mois=datetime.now().strftime('%y-%m'))


@poste_bp.route('/zip', methods=['POST'])
def telecharger_zip():
    try:
        config = construire_config()
    except ErreurFormulaire as e:
        return current_app.response_class(str(e), status=400,
                                          mimetype='text/plain; charset=utf-8')

    nom = _nom_fichier(config)
    return current_app.response_class(
        construire_zip(config),
        mimetype='application/zip',
        headers=dict(SANS_CACHE,
                     **{'Content-Disposition': 'attachment; filename="' + nom + '"'}))


@poste_bp.route('/outils/<path:nom>')
def outil(nom):
    """Sert un installeur specifique.

    Le nom recu n'est jamais utilise pour construire un chemin : il doit
    correspondre exactement a un fichier declare au catalogue et present sur le
    serveur, sinon c'est un 404. C'est ce qui interdit la traversee de
    repertoire. Route volontairement ouverte sans authentification : le poste
    client la sollicite sans session, et ces binaires ne sont pas des secrets.
    """
    if nom not in outils_disponibles().values():
        abort(404)
    return send_from_directory(OUTILS_DIR, nom, as_attachment=True)
