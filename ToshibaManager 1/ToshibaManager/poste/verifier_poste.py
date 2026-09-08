"""Verification bout en bout de la feature /poste, via le client de test Flask."""
import io
import json
import os
import sys
import zipfile

os.environ.setdefault('PUBLIC_BASE_URL', 'https://scan.potatodomain.win')
sys.path.insert(0, os.path.abspath('.'))

from app import app  # noqa: E402

client = app.test_client()
echecs = []


def verifier(libelle, condition, detail=''):
    etat = 'OK  ' if condition else 'ECHEC'
    print(f'  [{etat}] {libelle}' + (f'  -> {detail}' if detail and not condition else ''))
    if not condition:
        echecs.append(libelle)


print('\n--- Pages ---')
r = client.get('/hub')
verifier('/hub repond 200', r.status_code == 200, r.status_code)
verifier('/hub contient la carte "Installer un poste"',
         b'Installer un poste' in r.data and b'hub-choice--pc' in r.data)

r = client.get('/poste')
verifier('/poste repond 200 (avec redirection)', r.status_code in (200, 308), r.status_code)
r = client.get('/poste/')
verifier('/poste/ repond 200', r.status_code == 200, r.status_code)
page = r.data.decode('utf-8')
for attendu in ['Informations générales', 'Applications à installer',
                'Configuration Windows', 'CrystalDiskInfo', 'Kudu',
                'adminomb' if False else 'Comptes locaux']:
    verifier(f'la page contient « {attendu} »', attendu in page)
verifier('aucune application marquée indisponible',
         'installeur absent du serveur' not in page)

print('\n--- Route des outils (liste blanche) ---')
r = client.get('/poste/outils/Kudu-Setup-2.6.0.exe')
verifier('binaire déclaré -> 200', r.status_code == 200, r.status_code)
for chemin in ['/poste/outils/../app.py', '/poste/outils/app.py',
               '/poste/outils/inconnu.exe', '/poste/outils/..%2Fapp.py']:
    r = client.get(chemin)
    verifier(f'{chemin} -> 404', r.status_code == 404, r.status_code)

print('\n--- Refus de génération ---')
cas = [
    ('code client vide + AnyDesk coché',
     {'app': ['anydesk'], 'anydeskMotDePasse': '{code}'}, 'code client'),
    ('nom de compte réservé',
     {'comptes': json.dumps([{'nom': 'Administrateur', 'admin': True}])}, 'réservé'),
    ('nom de compte invalide',
     {'comptes': json.dumps([{'nom': 'jean dupont'}])}, 'invalide'),
    ('deux comptes en autologon',
     {'codeClient': '51940',
      'comptes': json.dumps([{'nom': 'a', 'motDePasse': 'x1234', 'autologon': True},
                             {'nom': 'b', 'motDePasse': 'y1234', 'autologon': True}])},
     'session automatique'),
    ('autologon sans mot de passe',
     {'comptes': json.dumps([{'nom': 'kiosque', 'motDePasse': '', 'autologon': True}])},
     'mot de passe'),
    ('application inconnue', {'app': ['minecraft']}, 'inconnue'),
    ('UAC hors liste', {'uac': 'nimportequoi'}, 'UAC'),
    ('renommage sans nom', {'renommerPoste': '1', 'nomPoste': ''}, 'vide'),
    ('nom de poste trop long',
     {'renommerPoste': '1', 'nomPoste': '2026-09-DUPONT-01'}, 'invalide'),
    ('nom de poste tout numérique',
     {'renommerPoste': '1', 'nomPoste': '12345'}, 'numérique'),
    ('doublon de compte',
     {'comptes': json.dumps([{'nom': 'eleve'}, {'nom': 'ELEVE'}])}, 'deux fois'),
]
for libelle, donnees, extrait in cas:
    r = client.post('/poste/zip', data=donnees)
    message = r.data.decode('utf-8')
    verifier(f'{libelle} -> 400', r.status_code == 400, f'{r.status_code} {message[:80]}')
    verifier(f'  message explicite ({extrait})', extrait.lower() in message.lower(), message[:120])

print('\n--- Génération complète ---')
formulaire = {
    'client': 'Dupont & Fils',
    'trigramme': 'dup',
    'codeClient': '51940',
    'renommerPoste': '1',
    'nomPoste': '26-09-DUP-01',
    'app': ['libreoffice', 'chrome', 'anydesk', 'crystaldiskinfo', 'office365'],
    'navigateurParDefaut': '1',
    'anydeskMotDePasse': '{code}',
    'uac': 'desactive',
    'extensionsVisibles': '1',
    'paveNumerique': '1',
    'desinstallerCcleaner': '1',
    'comptes': json.dumps([
        {'nom': 'adminomb', 'motDePasse': '{code}', 'admin': True,
         'motDePasseNExpireJamais': True, 'autologon': False},
        {'nom': 'Eleves', 'motDePasse': '', 'admin': False,
         'motDePasseNExpireJamais': True, 'autologon': False},
    ]),
}
r = client.post('/poste/zip', data=formulaire)
verifier('génération -> 200', r.status_code == 200,
         f'{r.status_code} {r.data[:200]}')

if r.status_code == 200:
    verifier('nom de fichier assaini',
             'filename="Installation PC (Dupont  Fils).zip"' in r.headers['Content-Disposition'],
             r.headers['Content-Disposition'])
    verifier('pas de mise en cache', 'no-store' in r.headers['Cache-Control'])

    archive = zipfile.ZipFile(io.BytesIO(r.data))
    noms = archive.namelist()
    for attendu in ['config.json', 'Installer-Poste.bat', 'Install-Poste.ps1',
                    'lib/Journal.ps1', 'lib/Winget.ps1', 'lib/Outils.ps1',
                    'lib/Comptes.ps1', 'lib/AnyDesk.ps1', 'lib/Navigateur.ps1',
                    'lib/Windows.ps1', 'README.md', 'config/catalogue.json']:
        verifier(f'le ZIP contient {attendu}', attendu in noms, noms)

    cfg = json.loads(archive.read('config.json').decode('utf-8'))
    verifier('client repris', cfg['client'] == 'Dupont & Fils', cfg['client'])
    verifier('trigramme en majuscules', cfg['trigramme'] == 'DUP', cfg['trigramme'])
    verifier('baseUrl = PUBLIC_BASE_URL',
             cfg['baseUrl'] == 'https://scan.potatodomain.win', cfg['baseUrl'])
    verifier('mot de passe AnyDesk dérivé du code',
             cfg['anydesk']['motDePasse'] == 'OmbI@51940', cfg['anydesk'])
    verifier('mot de passe adminomb dérivé du code',
             cfg['comptes'][0]['motDePasse'] == 'OmbI@51940', cfg['comptes'][0])
    verifier('compte sans mot de passe conservé vide',
             cfg['comptes'][1]['motDePasse'] == '', cfg['comptes'][1])
    verifier('aucun jeton {code} résiduel',
             '{code}' not in json.dumps(cfg), json.dumps(cfg))
    verifier('drapeau interne _derive retiré',
             all('_derive' not in c for c in cfg['comptes']), cfg['comptes'])
    verifier('UAC transmis', cfg['windows']['uac'] == 'desactive', cfg['windows'])
    verifier('réglage non coché à false',
             cfg['windows']['supprimerPubs'] is False, cfg['windows'])
    verifier('CCleaner dans la liste de désinstallation',
             cfg['windows']['desinstaller'] == ['CCleaner'], cfg['windows'])
    verifier('navigateur par défaut', cfg['navigateurParDefaut'] == 'chrome')
    verifier('poste à renommer',
             cfg['poste'] == {'renommer': True, 'nom': '26-09-DUP-01'}, cfg['poste'])

    ids = [a['id'] for a in cfg['applications']]
    verifier('VCRedist ajouté implicitement pour LibreOffice',
             'vcredist' in ids, ids)
    verifier('VCRedist placé avant LibreOffice',
             ids.index('vcredist') < ids.index('libreoffice'), ids)
    verifier('ordre du catalogue respecté',
             ids == ['vcredist', 'libreoffice', 'office365', 'chrome',
                     'anydesk', 'crystaldiskinfo'], ids)
    verifier('SHA-256 embarqué pour les outils',
             all(a.get('sha256') for a in cfg['applications'] if a['source'] == 'outil'))
    verifier('empreinte du toolkit présente', bool(cfg.get('toolkit')), cfg.get('toolkit'))

    r2 = client.post('/poste/zip', data=formulaire)
    memes = r2.data == r.data
    if not memes:
        c2 = json.loads(zipfile.ZipFile(io.BytesIO(r2.data)).read('config.json'))
        memes = {k: v for k, v in c2.items() if k != 'genereLe'} == \
                {k: v for k, v in cfg.items() if k != 'genereLe'}
        verifier('ZIP reproductible (hors horodatage)', memes)
    else:
        verifier('ZIP reproductible au bit près', True)

print('\n--- Outil manquant sur le serveur ---')
import poste_routes  # noqa: E402
vrai = poste_routes.OUTILS_DIR
poste_routes.OUTILS_DIR = os.path.join(vrai, '__vide__')
try:
    r = client.post('/poste/zip', data={'app': ['kudu']})
    verifier('installeur absent -> 400', r.status_code == 400, r.status_code)
    verifier('  message explicite', 'absent du serveur' in r.data.decode('utf-8'),
             r.data.decode('utf-8')[:120])
    r = client.get('/poste/outils/Kudu-Setup-2.6.0.exe')
    verifier('téléchargement d\'un absent -> 404', r.status_code == 404, r.status_code)
    r = client.get('/poste/')
    verifier('la page grise les outils absents',
            'installeur absent du serveur' in r.data.decode('utf-8'))
finally:
    poste_routes.OUTILS_DIR = vrai

print()
if echecs:
    print(f'{len(echecs)} verification(s) en echec :')
    for e in echecs:
        print('  -', e)
    sys.exit(1)
print('Toutes les verifications passent.')
