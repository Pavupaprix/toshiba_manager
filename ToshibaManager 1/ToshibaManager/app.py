from flask import Flask, render_template, request, jsonify, send_file
import xml.etree.ElementTree as ET
import os
import smtplib
import ssl
import sys
import time
import uuid
from datetime import datetime
from email.mime.text import MIMEText

import addressbook

app = Flask(__name__)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
os.chdir(BASE_DIR)
app.config['UPLOAD_FOLDER'] = 'uploads'
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

XML_FILE = os.path.join(app.config['UPLOAD_FOLDER'], 'templates.xml')

# -------------------------
# Validation du template par défaut au démarrage (FR-009, constitution
# Principe IV — Toshiba XML Template Integrity). Un template par défaut
# manquant ou invalide arrête immédiatement le processus avec un message
# clair sur stderr, plutôt que d'échouer silencieusement au premier clic
# utilisateur sur la page Template.
# -------------------------
DEFAULT_TEMPLATE_PATH = os.path.join('modele_xml', 'template_base.xml')
DEFAULT_TEMPLATE_OK = False

def _validate_default_template():
    if not os.path.exists(DEFAULT_TEMPLATE_PATH):
        print(f"❌ Erreur fatale: template par défaut introuvable ({DEFAULT_TEMPLATE_PATH})", file=sys.stderr)
        return False
    try:
        ET.parse(DEFAULT_TEMPLATE_PATH)
    except ET.ParseError as e:
        print(f"❌ Erreur fatale: template par défaut invalide ({DEFAULT_TEMPLATE_PATH}): {e}", file=sys.stderr)
        return False
    return True

DEFAULT_TEMPLATE_OK = _validate_default_template()
if not DEFAULT_TEMPLATE_OK:
    sys.exit(1)

@app.route('/healthz')
def healthz():
    if DEFAULT_TEMPLATE_OK:
        return jsonify({'status': 'ok'}), 200
    return jsonify({'status': 'error', 'error': 'template par défaut invalide ou manquant'}), 503

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/hub')
def hub():
    return render_template('hub.html')

@app.route('/parametrage')
def parametrage():
    return render_template('parametrage.html')

@app.route('/addressbook')
def addressbook_page():
    return render_template('addressbook.html')

@app.route('/api/load-default')
def load_default():
    try:
        template_path = os.path.join('modele_xml', 'template_base.xml')
        
        if not os.path.exists(template_path):
            return jsonify({'error': 'Fichier template_base.xml non trouvé'}), 404
        
        with open(template_path, 'r', encoding='utf-8') as f:
            xml_content = f.read()
        
        return jsonify({'xml': xml_content}), 200
    
    except Exception as e:
        print(f"❌ Erreur: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/load-default-xml')
def load_default_xml():
    try:
        with open('modele_xml/template_base.xml', 'r', encoding='utf-8') as f:
            xml_content = f.read()
        return jsonify({'success': True, 'xmlContent': xml_content})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/upload', methods=['POST'])
def upload_xml():
    if 'file' not in request.files:
        return jsonify({'error': 'Aucun fichier'}), 400
    
    file = request.files['file']
    
    if file.filename == '':
        return jsonify({'error': 'Fichier vide'}), 400
    
    if not file.filename.endswith('.xml'):
        return jsonify({'error': 'Doit être un fichier XML'}), 400
    
    try:
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], 'templates.xml')
        file.save(filepath)
        
        # Valide le XML
        ET.parse(filepath)
        
        print(f"✅ XML uploadé: {filepath}")
        return jsonify({'success': True, 'message': 'XML uploadé avec succès'}), 200
    
    except ET.ParseError as e:
        return jsonify({'error': f'XML invalide: {e}'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/download', methods=['GET'])
def download_xml():
    if os.path.exists(XML_FILE):
        return send_file(XML_FILE, as_attachment=True, download_name='templates.xml')
    return jsonify({'error': 'Fichier non trouvé'}), 404

@app.route('/download-bat')
def download_bat():
    bat_path = os.path.join(BASE_DIR, 'Toshiba+Partage.bat')
    if os.path.exists(bat_path):
        return send_file(bat_path, as_attachment=True, download_name='Toshiba+Partage.bat')
    return jsonify({'error': 'Fichier .bat non trouvé'}), 404


# -------------------------
# Carnet d'adresses — CSV pour le copieur
# -------------------------
ALLOWED_EXT = ('.xlsx', '.xls', '.csv')

def _save_upload(file):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT:
        raise ValueError('Format non supporté. Utilisez .xlsx, .xls ou .csv')
    path = os.path.join(app.config['UPLOAD_FOLDER'], 'addr_' + uuid.uuid4().hex + ext)
    file.save(path)
    return path

@app.route('/api/addressbook/parse', methods=['POST'])
def addressbook_parse():
    if 'file' not in request.files:
        return jsonify({'error': 'Aucun fichier'}), 400
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'Fichier vide'}), 400
    try:
        _cleanup_stale_uploads()
        path = _save_upload(file)
        result = addressbook.parse_workbook(path)
        result['fileId'] = os.path.basename(path)
        return jsonify({'success': True, **result}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 400

def _cleanup_stale_uploads():
    try:
        for name in os.listdir(app.config['UPLOAD_FOLDER']):
            if not name.startswith('addr_'):
                continue
            p = os.path.join(app.config['UPLOAD_FOLDER'], name)
            if time.time() - os.path.getmtime(p) > 3600:
                os.remove(p)
    except Exception:
        pass

@app.route('/api/addressbook/generate', methods=['POST'])
def addressbook_generate():
    data = request.get_json(silent=True) or {}
    file_id = str(data.get('fileId', ''))
    if not file_id:
        return jsonify({'error': 'Fichier non trouvé, réimportez-le'}), 400
    path = os.path.join(app.config['UPLOAD_FOLDER'], os.path.basename(file_id))
    if not os.path.exists(path):
        return jsonify({'error': 'Fichier non trouvé, réimportez-le'}), 400
    try:
        mapping = data.get('mapping') or {}
        order = data.get('order', 'auto')
        csv_content, stats = addressbook.generate_csv(path, mapping, order)
        fname = 'ADDR_' + datetime.now().strftime('%d%m%y') + '.csv'
        return jsonify({'success': True, 'csv': csv_content, 'stats': stats, 'filename': fname}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 400
    finally:
        if os.path.exists(path):
            os.remove(path)

@app.route('/api/groups/<gid>', methods=['DELETE'])
def delete_group(gid):
    if not os.path.exists(XML_FILE):
        return jsonify({'error': 'Fichier XML non trouvé'}), 404
    
    try:
        tree = ET.parse(XML_FILE)
        root = tree.getroot()
        
        group_list = root.find('.//GroupList')
        if group_list is not None:
            for group_elem in group_list.findall('Group'):
                if group_elem.get('gid') == gid:
                    group_list.remove(group_elem)
                    tree.write(XML_FILE, encoding='UTF-8', xml_declaration=True)
                    return jsonify({'success': True}), 200
        
        return jsonify({'error': 'Groupe non trouvé'}), 404
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# -------------------------
# SMTP logic (adapted from TEST_Smtp_Final 1.py; connection behavior preserved)
# -------------------------
def get_smtp_settings(provider):
    """Retourne (host, port, ssl_enabled, starttls_enabled) selon provider."""
    if provider == "Gmail":
        return ("smtp.gmail.com", 587, False, True)
    elif provider == "Office365":
        return ("smtp.office365.com", 587, False, True)
    else:
        return ("smtp.example.com", 587, False, True)

def get_custom_settings(data):
    host = str(data.get("host") or "smtp.example.com").strip()
    try:
        port = int(str(data.get("port", 587)).strip())
    except Exception:
        port = 587
    ssl_enabled = bool(data.get("ssl_enabled", False))
    starttls_enabled = bool(data.get("starttls_enabled", True))
    if ssl_enabled and starttls_enabled:
        starttls_enabled = False
    return (host, port, ssl_enabled, starttls_enabled)

# FR-004 / T014 (audit) : ni cette fonction ni les routes /api/smtp/* ne
# journalisent ou n'écrivent jamais `password` sur disque. Les réponses
# d'erreur renvoyées au client (`{e!r}`) exposent uniquement le message
# retourné par le serveur SMTP distant (ex. "535 Authentication failed"),
# jamais les identifiants soumis par l'utilisateur.
def smtp_connect_and_login(host, port, user, password, ssl_enabled, starttls_enabled, timeout=10):
    if ssl_enabled and starttls_enabled:
        raise ValueError("ssl_enabled et starttls_enabled ne peuvent pas être tous les deux True.")
    if ssl_enabled:
        context = ssl.create_default_context()
        server = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
        server.ehlo()
    else:
        server = smtplib.SMTP(host, port, timeout=timeout)
        server.ehlo()
        if starttls_enabled:
            context = ssl.create_default_context()
            server.starttls(context=context)
            server.ehlo()
    server.login(user, password)
    return server

def resolve_smtp_params(data):
    provider = data.get("provider", "Gmail")
    if provider == "Custom":
        return get_custom_settings(data)
    if provider not in ("Gmail", "Office365"):
        raise ValueError("Provider SMTP invalide.")
    return get_smtp_settings(provider)

def _smtp_payload():
    data = request.get_json(silent=True) or {}
    required = ("email", "password")
    missing = [key for key in required if not str(data.get(key, "")).strip()]
    if missing:
        raise ValueError("Remplissez email et mot de passe.")
    return data

def _smtp_details(host, port, ssl_enabled, starttls_enabled):
    return f"Paramètres: {host}:{port} (ssl={ssl_enabled}, starttls={starttls_enabled})"

@app.route('/smtp-test')
def smtp_test():
    return render_template('smtp_test.html')

@app.route('/api/smtp/test-connection', methods=['POST'])
def smtp_test_connection():
    server = None
    try:
        data = _smtp_payload()
        host, port, ssl_enabled, starttls_enabled = resolve_smtp_params(data)
        server = smtp_connect_and_login(host, port, data['email'].strip(), data['password'], ssl_enabled, starttls_enabled)
        server.quit()
        return jsonify({'success': True, 'message': 'Connexion réussie ✅',
                        'details': 'Connexion test: ' + _smtp_details(host, port, ssl_enabled, starttls_enabled)})
    except Exception as e:
        if server:
            try: server.quit()
            except Exception: pass
        return jsonify({'success': False, 'message': 'Échec de la connexion ❌',
                        'details': f'smtp_connect_and_login error: {e!r}'}), 400

@app.route('/api/smtp/send-test-email', methods=['POST'])
def smtp_send_test_email():
    server = None
    try:
        data = _smtp_payload()
        to_addr = str(data.get('destination', '')).strip()
        if not to_addr:
            raise ValueError("Remplissez email, mot de passe et destinataire.")
        host, port, ssl_enabled, starttls_enabled = resolve_smtp_params(data)
        user = data['email'].strip()
        server = smtp_connect_and_login(host, port, user, data['password'], ssl_enabled, starttls_enabled)
        msg = MIMEText("Ceci est un email de test envoyé depuis SMTP Tester.")
        msg['From'] = user
        msg['To'] = to_addr
        msg['Subject'] = 'Test SMTP - SMTP Tester'
        server.sendmail(user, [to_addr], msg.as_string())
        server.quit()
        return jsonify({'success': True, 'message': f'Email envoyé ✅ à {to_addr}',
                        'details': f'Email envoyé depuis {user} via {_smtp_details(host, port, ssl_enabled, starttls_enabled)}'})
    except Exception as e:
        if server:
            try: server.quit()
            except Exception: pass
        return jsonify({'success': False, 'message': "Échec de l'envoi ❌",
                        'details': f'send_test_email error: {e!r}'}), 400

if __name__ == '__main__':
    app.run(debug=True, port=5000)