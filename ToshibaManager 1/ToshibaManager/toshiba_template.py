from flask import Flask, render_template, request, jsonify, send_file
import xml.etree.ElementTree as ET
import os

app = Flask(__name__)
app.config['UPLOAD_FOLDER'] = 'uploads'
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

XML_FILE = os.path.join(app.config['UPLOAD_FOLDER'], 'templates.xml')

@app.route('/')
def index():
    return render_template('index.html')

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

if __name__ == '__main__':
    app.run(debug=True, port=5000)