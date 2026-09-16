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
import unicodedata
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


def _entier(valeur, defaut=-1):
    """GLPI renvoie null, pas -1, pour le parent de l'entite racine : un int()
    direct sur cette valeur echoue. Releve sur le parc reel, ou la lecture des
    sous-entites plantait des le premier client verifie."""
    try:
        return int(valeur)
    except (TypeError, ValueError):
        return defaut


def _dernier_segment(completename):
    return (completename or '').split('>')[-1].strip()


def entite_du_tag(entites, tag):
    """Entite portant ce TAG, ou None.

    Sert a refuser la generation d'un ZIP dont le TAG ne correspond a rien :
    un agent qui annonce un tag inconnu de GLPI remonte dans l'entite racine,
    et personne ne s'en apercoit avant de chercher le poste dans le parc.
    """
    tag = (tag or '').strip()
    if not tag:
        return None
    for e in entites:
        if (e.get('tag') or '').strip() == tag:
            return e
    return None


def normaliser_code(code):
    """« 051688 » et « 51688 » designent le meme client.

    Le parc melange les deux graphies : l'entite « TSEIN - 051688 » porte un
    zero de tete que personne ne tape. Comparer les codes debarrasses de leurs
    zeros de tete evite le pire des cas -- ne pas reconnaitre un client qui
    existe, et lui creer un doublon a cote.
    """
    chiffres = ''.join(c for c in (code or '') if c.isdigit())
    return chiffres.lstrip('0') or chiffres


def normaliser_texte(texte):
    """Minuscules, sans accents, ponctuation ramenee a des espaces.

    Pour comparer un nom saisi a la main a ceux du parc, ou ni la casse ni les
    accents ne sont homogenes. Sert aussi de cle de tri des resultats.
    """
    decompose = unicodedata.normalize('NFD', (texte or '').strip())
    lisible = ''.join(c if (c.isalnum() or c.isspace()) else ' '
                      for c in decompose
                      if unicodedata.category(c) != 'Mn')
    return ' '.join(lisible.lower().split())


def comparable(texte):
    """Forme compactee, sans separateur, pour la recherche « contient ».

    « SAINT-MARTIN » et « saint martin » designent le meme client : sans cette
    reduction, le trait d'union suffit a ce que la recherche ne trouve rien.
    """
    return normaliser_texte(texte).replace(' ', '')


def est_client(e):
    """Entite cliente : un enfant direct de la racine.

    Se fonde sur la place dans l'arborescence et non sur le nom : un client
    dont le nom ne suivrait pas la convention reste un client.
    """
    return (_entier(e.get('entities_id')) == ENTITE_RACINE
            and _entier(e.get('id')) != ENTITE_RACINE)


def trouver_client(entites, code):
    """Entite cliente portant ce code, ou None.

    Deux passes. La correspondance exacte d'abord. Puis, a defaut, la
    comparaison des codes normalises, qui rattrape les zeros de tete.

    Cette seconde passe ne tranche que si elle ne ramene qu'un seul client :
    deux entites dont les codes ne different que par un zero de tete sont une
    ambiguite reelle du parc, et c'est au technicien de la lever -- la liste
    de suggestions les lui montrera toutes les deux.
    """
    code = (code or '').strip()
    if not code:
        return None

    approchants = []
    for e in entites:
        _, trouve = decouper_nom_client(_dernier_segment(e.get('completename') or e.get('name')))
        if not trouve:
            continue
        if trouve == code:
            return e
        if normaliser_code(trouve) == normaliser_code(code):
            approchants.append(e)
    return approchants[0] if len(approchants) == 1 else None


def chercher_clients(entites, code='', nom='', limite=12):
    """Clients dont le code ou le nom *contient* ce qui a ete saisi.

    Repli quand aucune correspondance exacte ne sort. Annoncer « client
    absent » et proposer d'en creer un est trompeur quand le client existe
    sous une graphie voisine : mieux vaut montrer ce qui ressemble et laisser
    choisir.

    Les deux champs remplis se croisent (et), parce que deux criteres servent
    a restreindre. Si le croisement ne donne rien, on elargit a l'un ou
    l'autre (ou) : un nom mal orthographie ne doit pas masquer un code juste.
    """
    code_cherche = normaliser_code(code)
    # Chaque mot saisi doit se retrouver, et non la suite entiere d'un bloc :
    # « creche lilas » doit sortir « CRECHE DES LILAS », que l'on ne va pas
    # taper en entier.
    mots_cherches = normaliser_texte(nom).split()
    if not code_cherche and not mots_cherches:
        return []

    def criteres(e):
        segment = _dernier_segment(e.get('completename') or e.get('name'))
        nom_e, code_e = decouper_nom_client(segment)
        cible = comparable(nom_e or segment)
        par_code = bool(code_cherche) and code_cherche in normaliser_code(code_e)
        par_nom = bool(mots_cherches) and all(m in cible for m in mots_cherches)
        return par_code, par_nom

    clients = [e for e in entites if est_client(e)]

    resultats = []
    if code_cherche and mots_cherches:
        resultats = [e for e in clients if all(criteres(e))]
    if not resultats:
        resultats = [e for e in clients if any(criteres(e))]

    resultats.sort(key=lambda e: normaliser_texte(
        _dernier_segment(e.get('completename') or e.get('name'))))
    return resultats[:limite]


def sous_entites(entites, client):
    """Enfants directs du client, tries par nom."""
    parent = _entier(client.get('id'))
    enfants = [e for e in entites if _entier(e.get('entities_id')) == parent]
    return sorted(enfants, key=lambda e: (e.get('name') or '').lower())


def resume_entite(e):
    """Forme renvoyee au navigateur : rien d'autre que l'utile."""
    nom_complet = e.get('completename') or e.get('name') or ''
    nom, code = decouper_nom_client(_dernier_segment(nom_complet))
    return {
        'id': _entier(e.get('id')),
        'nom': e.get('name') or '',
        'nomComplet': nom_complet,
        'nomClient': nom,
        'code': code,
        'tag': (e.get('tag') or '').strip(),
    }
