"""Client de l'API REST GLPI, pour la section Agent GLPI de /poste.

Isole du reste de l'application : ce module ne connait pas Flask, ce qui permet
de l'essayer seul depuis un interpreteur.

Ecrit avec urllib plutot que requests : la constitution du projet demande de
justifier toute nouvelle dependance, et six appels JSON ne le justifient pas.

Conformite verifiee dans la documentation officielle et le code source de
GLPI 10, et non deduite de l'outil interne existant :

  - initSession attend l'en-tete "Authorization: user_token <jeton>" ;
  - les charges utiles de POST et PUT sont enveloppees dans une cle "input" ;
  - le champ "tag" de l'entite est natif, libelle par GLPI "Information in
    inventory tool (TAG) representing the entity" : l'ecrire est son usage
    prevu, pas un detournement.
"""

import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request

# Racine de l'arborescence GLPI. L'entite racine porte toujours l'identifiant 0.
ENTITE_RACINE = 0

# Un code client est une suite de chiffres. Six et non cinq : l'entite
# "TSEIN - 051688" existe, et l'outil interne ne sait pas la traiter.
RE_CODE = re.compile(r'^[0-9]{4,6}$')

DELAI = 20


class ErreurGlpi(Exception):
    """Echec d'un appel GLPI. Le message est affichable tel quel au technicien."""


def _config(nom, defaut=''):
    return (os.environ.get(nom) or defaut).strip()


def configuration():
    """Parametres lus a chaque appel : un redemarrage du conteneur suffit a les
    changer, sans rien recompiler."""
    return {
        'api': _config('GLPI_API_URL').rstrip('/'),
        'serveur': _config('GLPI_AGENT_SERVER'),
        'appToken': _config('GLPI_APP_TOKEN'),
        'userToken': _config('GLPI_USER_TOKEN'),
        'verifierTls': _config('GLPI_TLS_VERIFICATION', '1') != '0',
    }


def est_configure():
    c = configuration()
    return all((c['api'], c['serveur'], c['appToken'], c['userToken']))


def _contexte_ssl(verifier):
    if verifier:
        return ssl.create_default_context()
    # Echappatoire pour un GLPI a certificat auto-signe. Documentee dans
    # .env.example, desactivee par defaut.
    contexte = ssl.create_default_context()
    contexte.check_hostname = False
    contexte.verify_mode = ssl.CERT_NONE
    return contexte


def _appel(methode, chemin, entetes, corps=None, params=None):
    c = configuration()
    if not c['api']:
        raise ErreurGlpi("GLPI n'est pas configuré sur le serveur.")

    url = c['api'] + '/' + chemin.lstrip('/')
    if params:
        url += '?' + urllib.parse.urlencode(params)

    donnees = None
    if corps is not None:
        donnees = json.dumps(corps).encode('utf-8')

    requete = urllib.request.Request(url, data=donnees, method=methode)
    requete.add_header('Content-Type', 'application/json')
    requete.add_header('App-Token', c['appToken'])
    for cle, valeur in entetes.items():
        requete.add_header(cle, valeur)

    try:
        with urllib.request.urlopen(requete, timeout=DELAI,
                                    context=_contexte_ssl(c['verifierTls'])) as reponse:
            brut = reponse.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        detail = e.read().decode('utf-8', 'replace')[:300]
        raise ErreurGlpi('GLPI a refusé la requête (%s) : %s' % (e.code, detail))
    except urllib.error.URLError as e:
        raise ErreurGlpi(
            "GLPI est injoignable depuis le serveur : %s. Vérifiez que %s est "
            "accessible depuis le conteneur." % (e.reason, c['api']))

    if not brut.strip():
        return {}
    try:
        return json.loads(brut)
    except ValueError:
        raise ErreurGlpi('Réponse GLPI illisible : ' + brut[:200])


class Session:
    """Session GLPI. A utiliser comme gestionnaire de contexte : une session
    non fermee reste ouverte cote serveur et s'accumule."""

    def __init__(self):
        self.jeton = None

    def __enter__(self):
        c = configuration()
        reponse = _appel('GET', 'initSession',
                         {'Authorization': 'user_token ' + c['userToken']})
        self.jeton = reponse.get('session_token')
        if not self.jeton:
            raise ErreurGlpi("GLPI n'a pas renvoyé de jeton de session : "
                             "vérifiez GLPI_USER_TOKEN et GLPI_APP_TOKEN.")
        return self

    def __exit__(self, *_):
        if not self.jeton:
            return False
        try:
            _appel('GET', 'killSession', {'Session-Token': self.jeton})
        except ErreurGlpi:
            pass  # Une session non fermee expire d'elle-meme.
        self.jeton = None
        return False

    def appel(self, methode, chemin, corps=None, params=None):
        return _appel(methode, chemin, {'Session-Token': self.jeton}, corps, params)

    # -------------------------
    # Lecture
    # -------------------------

    def entites(self):
        """Toutes les entites visibles, avec leur nom complet et leur tag.

        Un seul appel plutot que getMyEntities suivi d'un GET par entite :
        l'endpoint generique renvoie deja completename, entities_id et tag.
        """
        resultat = self.appel('GET', 'Entity',
                              params={'range': '0-9999', 'is_recursive': 'true'})
        if isinstance(resultat, dict):
            resultat = resultat.get('data', [])
        return [e for e in resultat if isinstance(e, dict)]

    # -------------------------
    # Ecriture
    # -------------------------

    def creer(self, nom, parent):
        reponse = self.appel('POST', 'Entity',
                             corps={'input': {'name': nom, 'entities_id': parent}})
        if isinstance(reponse, list) and reponse:
            reponse = reponse[0]
        identifiant = (reponse or {}).get('id')
        if not identifiant:
            raise ErreurGlpi("GLPI n'a pas renvoyé l'identifiant de « %s »." % nom)
        return int(identifiant)

    def ecrire_tag(self, entite_id, tag):
        """Renseigne le champ tag de l'entite.

        C'est le correctif du defaut de l'outil interne : sans cette ecriture,
        une generation ulterieure pour le meme client ne retrouve aucun tag.
        """
        self.appel('PUT', 'Entity/%d' % int(entite_id),
                   corps={'input': {'tag': tag}})

    def activer_entites(self, entite_id):
        """Necessaire avant de creer une sous-entite, sinon GLPI refuse."""
        self.appel('POST', 'changeActiveEntities',
                   corps={'entities_id': int(entite_id), 'is_recursive': True})


# -------------------------
# Convention de nommage OMB
# -------------------------

def decouper_nom_client(nom):
    """« AFIDD - 51816 » -> ('AFIDD', '51816').

    Le code est en dernier, apres le dernier tiret : un nom de client peut lui
    meme contenir un tiret (« SAINT-MARTIN - 52000 »), d'ou le decoupage par la
    droite. Renvoie (nom, '') si aucun code n'est reconnaissable.
    """
    if '-' not in nom:
        return nom.strip(), ''
    gauche, droite = nom.rsplit('-', 1)
    code = droite.strip()
    if RE_CODE.match(code):
        return gauche.strip(), code
    return nom.strip(), ''


def nom_entite(nom_client, code):
    """Compose le nom d'entite selon la convention du parc."""
    return '%s - %s' % (nom_client.strip(), code.strip())


def tag_propose(nom_client, sous_entite):
    """« AFIDD » + « Ordinateurs » -> « AFIDDOrdinateurs ».

    Concatenation sans separateur : c'est ce que produit l'outil interne, et
    les agents deja deployes portent ce format. En changer creerait deux
    conventions en parallele dans le parc.
    """
    return (nom_client or '').strip() + (sous_entite or '').strip()


def _dernier_segment(completename):
    return (completename or '').split('>')[-1].strip()


def trouver_client(entites, code):
    """Entite cliente dont le nom porte ce code, ou None."""
    code = (code or '').strip()
    for e in entites:
        _, trouve = decouper_nom_client(_dernier_segment(e.get('completename') or e.get('name')))
        if trouve and trouve == code:
            return e
    return None


def sous_entites(entites, client):
    """Enfants directs du client, tries par nom."""
    parent = int(client['id'])
    enfants = [e for e in entites if int(e.get('entities_id', -1)) == parent]
    return sorted(enfants, key=lambda e: (e.get('name') or '').lower())


def resume_entite(e):
    """Forme renvoyee au navigateur : rien d'autre que l'utile."""
    nom_complet = e.get('completename') or e.get('name') or ''
    nom, code = decouper_nom_client(_dernier_segment(nom_complet))
    return {
        'id': int(e['id']),
        'nom': e.get('name') or '',
        'nomComplet': nom_complet,
        'nomClient': nom,
        'code': code,
        'tag': (e.get('tag') or '').strip(),
    }
