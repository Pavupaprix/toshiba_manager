// ==========================================
// VARIABLES GLOBALES
// ==========================================

let xmlData = null;
let currentEditGid = null;
let currentEditTid = null;
let confirmCallback = null;

// ==========================================
// FONCTIONS UTILITAIRES
// ==========================================

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function showNotification(message, type = 'success') {
    const oldNotif = document.querySelector('.notification');
    if (oldNotif) oldNotif.remove();

    const notif = document.createElement('div');
    notif.className = `notification ${type}`;
    notif.textContent = (type === 'success' ? '✅ ' : '❌ ') + message;
    document.body.appendChild(notif);

    setTimeout(() => notif.remove(), 3000);
}

function closeModal(modalId) {
    document.getElementById(modalId).classList.remove('active');
}

function togglePasswordVisibility(inputId) {
    const input = document.getElementById(inputId);
    const icon = event.target;
    
    if (input.type === 'password') {
        input.type = 'text';
        icon.textContent = '👁️';
    } else {
        input.type = 'password';
        icon.textContent = '👁️';
    }
}

function showConfirm(title, message, callback) {
    document.getElementById('confirmTitle').textContent = title;
    document.getElementById('confirmMessage').textContent = message;
    confirmCallback = callback;
    document.getElementById('confirmModal').classList.add('active');
}

function confirmAction() {
    if (confirmCallback) {
        confirmCallback();
    }
    closeModal('confirmModal');
}

function cancelConfirm() {
    confirmCallback = null;
    closeModal('confirmModal');
}

// ==========================================
// CHARGEMENT ET PARSING XML
// ==========================================

function handleXMLUpload(event) {
    const file = event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = function(e) {
        try {
            const parser = new DOMParser();
            const xmlDoc = parser.parseFromString(e.target.result, 'text/xml');

            if (xmlDoc.getElementsByTagName('parsererror').length > 0) {
                console.error('Erreur : XML invalide');
                showNotification('Erreur : XML invalide', 'error');
                return;
            }

            xmlData = {
                xmlDoc: xmlDoc,
                groups: []
            };

            xmlDoc.querySelectorAll('Group').forEach(groupEl => {
                const group = parseGroup(groupEl);
                xmlData.groups.push(group);
            });
            console.log('XML chargé avec succès:', xmlData);
            renderGroups();
            showNotification('XML importé avec succès');
        } catch (error) {
            console.error('Erreur XML:', error);
            showNotification('Erreur lors de l\'importation XML', 'error');
        }
    };
    reader.readAsText(file);
    event.target.value = '';
}

function parseGroup(groupEl) {
    const gid = groupEl.getAttribute('gid') || '000';
    const metaData = groupEl.querySelector('MetaData');
    const groupName = metaData?.querySelector('groupName')?.textContent || 'Groupe ' + gid;

    const group = {
        gid: gid,
        name: groupName,
        xmlElement: groupEl,
        templates: []
    };

    groupEl.querySelectorAll('Template').forEach(templateEl => {
        const template = parseTemplate(templateEl, gid);
        if (template) {
            group.templates.push(template);
        }
    });

    return group;
}

function parseTemplate(templateEl, gid) {
    const tid = templateEl.getAttribute('tid') || '001';
    const metaData = templateEl.querySelector('MetaData');

    const template = {
        tid: tid,
        gid: gid,
        caption1: metaData?.querySelector('caption1')?.textContent || 'Template ' + tid,
        caption2: metaData?.querySelector('caption2')?.textContent || '',
        xmlElement: templateEl
    };

    return template;
}

// ==========================================
// EXTRACTION DES DESTINATIONS SMB
// ==========================================

function getTemplateDestinations(template) {
    const destinations = [];
    
    if (!template.xmlElement) return destinations;

    const smbStores = template.xmlElement.querySelectorAll('SMBStore');
    
    smbStores.forEach((smbStore, index) => {
        const enabled = smbStore.getAttribute('Enabled') === 'true';
        const smbParam = smbStore.querySelector('SMBStoreParameter');
        
        if (smbParam) {
            const storePath = smbParam.querySelector('StorePath')?.textContent || '';
            const userName = smbParam.querySelector('UserName')?.textContent || '';
            const password = smbParam.querySelector('Password')?.textContent || '';
            
            destinations.push({
                type: 'smb',
                index: index + 1,
                label: `SMB ${index + 1}`,
                icon: '📁',
                enabled: enabled,
                data: {
                    StorePath: storePath,
                    UserName: userName,
                    Password: password
                },
                xmlElement: smbStore
            });
        }
    });

    return destinations;
}

// ==========================================
// FORMAT FICHIER : Type + Mode Pages (Simple/Multi)
// ==========================================

// Formats qui supportent le mode "Multi" (multi-pages en 1 seul fichier).
// JPEG n'a pas de variante Multi côté copieur : toujours 1 fichier par page.
const MULTI_CAPABLE_FORMATS = ['PDF', 'PDFA', 'SlimPDF', 'TIFF', 'XPS', 'DOCX', 'XLSX'];

const FILE_FORMAT_LABELS = {
    PDF: 'PDF', PDFA: 'PDF/A', SlimPDF: 'Slim PDF', TIFF: 'TIFF', JPEG: 'JPEG',
    XPS: 'XPS', DOCX: 'Word (DOCX)', XLSX: 'Excel (XLSX)'
};

// "PDFMulti" -> { type: 'PDF', mode: 'multi' } / "SlimPDFSingle" -> { type: 'SlimPDF', mode: 'single' }
function splitFileFormat(value) {
    if (!value) return { type: '', mode: 'single' };
    if (value.endsWith('Multi')) {
        return { type: value.slice(0, -'Multi'.length), mode: 'multi' };
    }
    if (value.endsWith('Single')) {
        return { type: value.slice(0, -'Single'.length), mode: 'single' };
    }
    // Valeur nue (JPEG, ou une ancienne sauvegarde buguée type "PDF" sans suffixe) : Simple par défaut.
    return { type: value, mode: 'single' };
}

// { type: 'PDF', mode: 'multi' } -> "PDFMulti" / { type: 'PDF', mode: 'single' } -> "PDFSingle"
// Important : le scanner Toshiba exige le suffixe explicite Single/Multi. Une valeur nue
// comme "PDF" n'est pas reconnue par le copieur, qui retombe alors silencieusement sur son
// format par défaut (TIFF Multi) sans remonter d'erreur — d'où ce suffixe systématique.
function buildFileFormat(type, mode) {
    if (!type) return '';
    if (type === 'JPEG') return 'JPEG';
    return mode === 'multi' ? `${type}Multi` : `${type}Single`;
}

function formatFileFormatLabel(value) {
    if (!value) return 'N/A';
    const { type, mode } = splitFileFormat(value);
    const typeLabel = FILE_FORMAT_LABELS[type] || type;
    return mode === 'multi' ? `${typeLabel} (Multi)` : `${typeLabel} (Simple)`;
}

// Appelé quand on change le type de fichier dans le modal d'édition :
// désactive/force le mode "Simple" pour les formats qui n'ont pas de variante Multi (ex: JPEG).
function onFileFormatTypeChange() {
    const type = document.getElementById('editFileFormatType').value;
    const modeSelect = document.getElementById('editFileFormatMode');
    if (!modeSelect) return;
    if (type && !MULTI_CAPABLE_FORMATS.includes(type)) {
        modeSelect.value = 'single';
        modeSelect.disabled = true;
    } else {
        modeSelect.disabled = false;
    }
}

// ==========================================
// EXTRACTION DES DÉTAILS DE SCAN - CORRIGÉ !
// ==========================================

function getScanDetails(template) {
    if (!template.xmlElement) return {};

    // Chercher dans Params/Queues/Scan/WorkflowExecutionParameter
    const workflow = template.xmlElement.querySelector('Params > Queues > Scan > WorkflowExecutionParameter');
    if (!workflow) return {};

    // Chercher dans ColorParameter
    const colorParam = workflow.querySelector('ColorParameter');
    const colorMode = colorParam?.querySelector('ColorMode')?.textContent || '';

    // Chercher dans ImageAdjustmentParameter
    const imageAdj = workflow.querySelector('ImageAdjustmentParameter');
    const imageMode = imageAdj?.querySelector('ImageMode')?.textContent || '';
    const imageRotate = imageAdj?.querySelector('ImageRotate')?.textContent || '';

    // Chercher dans Scan > ScanParameter
    const scanParam = workflow.querySelector('Scan > ScanParameter');
    const duplexMode = scanParam?.querySelector('DuplexMode')?.textContent || '';
    const resolution = scanParam?.querySelector('Resolution')?.textContent || '';
    const omitBlankPage = scanParam?.querySelector('OmitBlankPage > Enabled')?.textContent || '';

    // Chercher dans Output pour le format fichier
    const output = workflow.querySelector('Scan > Output');
    let fileFormat = '';

    if (output) {
        // Utiliser la destination réellement activée (ex: SMBStore Enabled="true"),
        // car c'est elle qui écrit le fichier. La première trouvée dans le XML est
        // toujours EmailSend, qui est désactivée par défaut et n'a aucun effet.
        const enabledDest = Array.from(output.children).find(child => child.getAttribute('Enabled') === 'true');
        const fileFormatEl = (enabledDest || output).querySelector('FileFormatInformation > FileFormat');
        fileFormat = fileFormatEl?.textContent || '';
    }

    return {
        FileFormat: fileFormat,
        ColorMode: colorMode,
        ImageRotate: imageRotate,
        ImageMode: imageMode,
        DuplexMode: duplexMode,
        Resolution: resolution,
        OmitBlankPage: omitBlankPage,
        OriginalSizeDetection: scanParam?.querySelector('AutoOriginalDetectionMode')?.textContent || ''
    };
}

// ==========================================
// RENDU DES GROUPES
// ==========================================

function renderGroups() {
    if (!xmlData || !xmlData.groups) return;

    const container = document.getElementById('groupsContainer');
    container.innerHTML = xmlData.groups.map(group => `
        <div class="group" data-gid="${escapeHtml(group.gid)}">
            <div class="group-header" onclick="toggleGroup('${group.gid}')">
                <div class="group-info">
                    <span class="toggle-icon collapsed" id="toggle-${group.gid}">▼</span>
                    <span class="group-icon">📁</span>
                    <div class="group-text">
                        <h2>${escapeHtml(group.name)}</h2>
                        <p>${group.templates.length} template(s)</p>
                    </div>
                </div>
                <div class="group-actions" onclick="event.stopPropagation()">
                    <button class="btn btn-new-template" onclick="createTemplate('${group.gid}')">➕ Nouveau</button>
                    <button class="btn btn-edit-group" onclick="editGroup('${group.gid}')">✏️ Éditer</button>
                    <button class="btn btn-duplicate-group" onclick="duplicateGroup('${group.gid}')">📋 Dupliquer</button>
                    <button class="btn btn-delete-group" onclick="deleteGroup('${group.gid}')">🗑️ Supprimer</button>
                </div>
            </div>
            <div class="group-content" id="content-${group.gid}">
                <div class="templates-grid">
                    ${group.templates.length > 0 
                        ? group.templates.map(template => renderTemplate(template, group.gid)).join('') 
                        : '<div class="empty-message">Aucun template dans ce groupe<br><button class="btn btn-new-template" onclick="createTemplate(\'' + group.gid + '\')">➕ Créer un template</button></div>'
                    }
                </div>
            </div>
        </div>
    `).join('');
}

function renderTemplate(template, gid) {
    const destinations = getTemplateDestinations(template);
    const enabledDests = destinations.filter(d => d.enabled);

    return `
        <div class="template-card">
            <div class="template-name">${escapeHtml(template.caption1)}</div>
            ${template.caption2 ? `<div class="template-caption">${escapeHtml(template.caption2)}</div>` : ''}
            <div class="template-meta">TID: ${template.tid}</div>
            
            ${enabledDests.length > 0 ? `
                <div class="destinations-list">
                    ${enabledDests.map(d => `<span class="destination-badge">${d.icon} ${d.label}</span>`).join('')}
                </div>
            ` : ''}
            
            <div class="template-actions">
                <button class="btn btn-view" onclick="viewTemplate('${gid}', '${template.tid}')">👁️ Voir</button>
                <button class="btn btn-edit" onclick="editTemplate('${gid}', '${template.tid}')">✏️ Éditer</button>
                <button class="btn btn-delete" onclick="deleteTemplate('${gid}', '${template.tid}')">🗑️ Suppr</button>
            </div>
        </div>
    `;
}

function toggleGroup(gid) {
    const content = document.getElementById(`content-${gid}`);
    const toggle = document.getElementById(`toggle-${gid}`);
    content.classList.toggle('visible');
    toggle.classList.toggle('collapsed');
}

// ==========================================
// GESTION DES GROUPES
// ==========================================

function editGroup(gid) {
    const group = xmlData.groups.find(g => g.gid === gid);
    if (!group) return;

    document.getElementById('editGroupNameInput').value = group.name;
    document.getElementById('currentEditGid').value = gid;
    
    const firstTemplate = group.templates[0];
    let smbPath = '';
    let smbUser = '';
    let smbPass = '';
    
    if (firstTemplate) {
        const destinations = getTemplateDestinations(firstTemplate);
        if (destinations.length > 0) {
            smbPath = destinations[0].data.StorePath;
            smbUser = destinations[0].data.UserName;
            smbPass = destinations[0].data.Password;
        }
    }
    
    const bulkHtml = `
        <div style="margin-top: 20px;">
            <h3 style="color: #4f6bed; margin-bottom: 15px; font-weight: 700;">Édition en masse — Données SMB :</h3>
            <div class="form-group">
                <label>Chemin SMB :</label>
                <input type="text" id="bulk-smb-path" placeholder="\\\\CHEMIN\\SCAN" value="${escapeHtml(smbPath)}">
            </div>
            <div class="form-group">
                <label>Identifiant :</label>
                <input type="text" id="bulk-smb-user" placeholder="utilisateur" value="${escapeHtml(smbUser)}">
            </div>
            <div class="form-group">
                <label>Mot de passe :</label>
                <div class="password-wrapper">
                    <input type="password" id="bulk-smb-pass" placeholder="mot de passe" value="${escapeHtml(smbPass)}">
                    <button type="button" class="eye-icon" onclick="togglePasswordVisibility('bulk-smb-pass')">👁</button>
                </div>
            </div>
        </div>
    `;

    document.getElementById('bulkEditContent').innerHTML = bulkHtml;
    document.getElementById('editGroupModal').classList.add('active');
}

function saveGroupEdit() {
    const gid = document.getElementById('currentEditGid').value;
    const group = xmlData.groups.find(g => g.gid === gid);
    if (!group) return;

    const newName = document.getElementById('editGroupNameInput').value.trim();
    group.name = newName;

    const metaData = group.xmlElement.querySelector('MetaData');
    if (metaData) {
        let groupNameEl = metaData.querySelector('groupName');
        if (!groupNameEl) {
            groupNameEl = xmlData.xmlDoc.createElement('groupName');
            metaData.appendChild(groupNameEl);
        }
        groupNameEl.textContent = newName;
    }

    // Édition en masse des destinations SMB
    const bulkSmbPath = document.getElementById('bulk-smb-path')?.value.trim();
    const bulkSmbUser = document.getElementById('bulk-smb-user')?.value.trim();
    const bulkSmbPass = document.getElementById('bulk-smb-pass')?.value.trim();

    if (bulkSmbPath || bulkSmbUser || bulkSmbPass) {
        group.templates.forEach(template => {
            const smbStores = template.xmlElement.querySelectorAll('SMBStore');
            smbStores.forEach((smbStore) => {
                const smbParam = smbStore.querySelector('SMBStoreParameter');
                if (smbParam) {
                    const storePath = smbParam.querySelector('StorePath');
                    const userName = smbParam.querySelector('UserName');
                    const password = smbParam.querySelector('Password');

                    if (storePath) storePath.textContent = bulkSmbPath;
                    if (userName) userName.textContent = bulkSmbUser;
                    if (password) password.textContent = bulkSmbPass;
                }
            });
        });
    }

    closeModal('editGroupModal');
    renderGroups();
    showNotification('Groupe modifié avec succès');
}

function duplicateGroup(gid) {
    const group = xmlData.groups.find(g => g.gid === gid);
    if (!group) return;

    const newGid = String(Math.max(...xmlData.groups.map(g => parseInt(g.gid) || 0)) + 1).padStart(3, '0');
    
    const clonedGroupEl = group.xmlElement.cloneNode(true);
    clonedGroupEl.setAttribute('gid', newGid);

    const metaData = clonedGroupEl.querySelector('MetaData');
    if (metaData) {
        let groupNameEl = metaData.querySelector('groupName');
        if (groupNameEl) {
            groupNameEl.textContent = groupNameEl.textContent + ' (Copie)';
        }
    }

    clonedGroupEl.querySelectorAll('Template').forEach((templateEl, index) => {
        const newTid = String(index + 1).padStart(3, '0');
        templateEl.setAttribute('tid', newTid);
        templateEl.setAttribute('gid', newGid);
        
        const gidEl = templateEl.querySelector('gid');
        if (gidEl) {
            gidEl.textContent = newGid;
        }
    });

    const groupIndex = xmlData.groups.findIndex(g => g.gid === gid);
    group.xmlElement.parentNode.insertBefore(clonedGroupEl, group.xmlElement.nextSibling);

    const newGroup = {
        gid: newGid,
        name: group.name + ' (Copie)',
        xmlElement: clonedGroupEl,
        templates: []
    };

    clonedGroupEl.querySelectorAll('Template').forEach(templateEl => {
        const template = parseTemplate(templateEl, newGid);
        if (template) {
            newGroup.templates.push(template);
        }
    });

    updateTemplateCount(newGroup);
    xmlData.groups.splice(groupIndex + 1, 0, newGroup);

    renderGroups();
    showNotification('Groupe dupliqué avec succès');
}

function deleteGroup(gid) {
    showConfirm(
        'Supprimer le groupe ?',
        'Êtes-vous sûr de vouloir supprimer ce groupe et tous ses templates ?',
        function() {
            const group = xmlData.groups.find(g => g.gid === gid);
            if (group) {
                group.xmlElement.remove();
            }

            xmlData.groups = xmlData.groups.filter(g => g.gid !== gid);
            renumberAllGroups();
            renderGroups();
            showNotification('Groupe supprimé');
        }
    );
}

// ==========================================
// RENUMÉROTATION DES IDENTIFIANTS
// ==========================================

function updateTemplateCount(group) {
    const metaData = group.xmlElement.querySelector('MetaData');
    if (!metaData) return;
    let countEl = metaData.querySelector('TemplateCount');
    if (!countEl) {
        countEl = xmlData.xmlDoc.createElement('TemplateCount');
        metaData.appendChild(countEl);
    }
    countEl.textContent = String(group.templates.length);
}

function renumberTids(group) {
    group.templates.forEach((t, i) => {
        const newTid = String(i + 1).padStart(3, '0');
        t.tid = newTid;
        t.xmlElement.setAttribute('tid', newTid);
        t.xmlElement.setAttribute('gid', group.gid);

        const tidEl = t.xmlElement.querySelector('tid');
        if (tidEl) tidEl.textContent = newTid;
        const gidEl = t.xmlElement.querySelector('gid');
        if (gidEl) gidEl.textContent = group.gid;
    });
    updateTemplateCount(group);
}

function renumberAllGroups() {
    xmlData.groups.forEach((g, i) => {
        const newGid = String(i + 1).padStart(3, '0');
        g.gid = newGid;
        g.xmlElement.setAttribute('gid', newGid);
        g.templates.forEach(t => {
            t.gid = newGid;
            t.xmlElement.setAttribute('gid', newGid);
            const gidEl = t.xmlElement.querySelector('gid');
            if (gidEl) gidEl.textContent = newGid;
        });
        renumberTids(g);
    });
}

// ==========================================
// GESTION DES TEMPLATES
// ==========================================

function viewTemplate(gid, tid) {
    const group = xmlData.groups.find(g => g.gid === gid);
    const template = group?.templates.find(t => t.tid === tid);
    if (!template) return;

    const destinations = getTemplateDestinations(template);
    const scanDetails = getScanDetails(template);

    let html = `
        <div class="template-details">
            <h3>${escapeHtml(template.caption1)}</h3>
            ${template.caption2 ? `<p><strong>Sous-titre:</strong> ${escapeHtml(template.caption2)}</p>` : ''}
            <p><strong>TID:</strong> ${template.tid}</p>
            <p><strong>GID:</strong> ${template.gid}</p>
    `;

    if (destinations.length > 0) {
        html += `<h4 style="margin: 18px 0 10px; color: #4f6bed;">📁 Destination SMB</h4>`;
        const dest = destinations[0];
        const passwordId = `view-password-${gid}-${tid}`;
        html += `
            <div class="destination-item">
                <h3>Destination 1 <span class="status ${dest.enabled ? 'status-enabled' : 'status-disabled'}">${dest.enabled ? 'Activée' : 'Désactivée'}</span></h3>
                <div class="info-row"><span class="info-label">Chemin</span><span class="info-value">${escapeHtml(dest.data.StorePath)}</span></div>
                <div class="info-row"><span class="info-label">Utilisateur</span><span class="info-value">${escapeHtml(dest.data.UserName)}</span></div>
                <div class="info-row"><span class="info-label">Mot de passe</span><span class="info-value" style="display:flex;align-items:center;gap:10px;"><span id="${passwordId}" style="font-family: monospace;">••••••••</span><span style="cursor: pointer; font-size: 18px;" onclick="toggleViewPassword('${passwordId}', '${escapeHtml(dest.data.Password)}')">👁️</span></span></div>
            </div>
        `;
    } else {
        html += `<p><em>Aucune destination SMB</em></p>`;
    }

    // DÉTAILS DE SCAN
    html += `<h4 style="margin: 22px 0 10px; color: #4f6bed;">🎯 Détails de Scan</h4>`;
    html += `
        <div class="destination-item">
            <div class="info-row"><span class="info-label">📎 Format Fichier</span><span class="info-value">${escapeHtml(formatFileFormatLabel(scanDetails.FileFormat))}</span></div>
            <div class="info-row"><span class="info-label">🎨 Mode Couleur</span><span class="info-value">${escapeHtml(scanDetails.ColorMode || 'N/A')}</span></div>
            <div class="info-row"><span class="info-label">🔄 Rotation</span><span class="info-value">${escapeHtml(scanDetails.ImageRotate || 'N/A')}°</span></div>
            <div class="info-row"><span class="info-label">📄 Mode Image</span><span class="info-value">${escapeHtml(scanDetails.ImageMode || 'N/A')}</span></div>
            <div class="info-row"><span class="info-label">📑 Recto/Verso</span><span class="info-value">${escapeHtml(scanDetails.DuplexMode || 'N/A')}</span></div>
            <div class="info-row"><span class="info-label">📏 Résolution</span><span class="info-value">${escapeHtml(scanDetails.Resolution || 'N/A')} DPI</span></div>
            <div class="info-row"><span class="info-label">📐 Détection Auto Taille</span><span class="info-value">${escapeHtml(scanDetails.OriginalSizeDetection || 'N/A')}</span></div>
            <div class="info-row"><span class="info-label">⬜ Ignorer Pages Blanches</span><span class="info-value">${escapeHtml(scanDetails.OmitBlankPage || 'N/A')}</span></div>
        </div>
    `;

    html += `</div>`;

    document.getElementById('viewContent').innerHTML = html;
    document.getElementById('viewModal').classList.add('active');
}

function toggleViewPassword(passwordId, actualPassword) {
    const display = document.getElementById(passwordId);
    if (display.textContent === '••••••••') {
        display.textContent = actualPassword;
    } else {
        display.textContent = '••••••••';
    }
}

function editTemplate(gid, tid) {
    currentEditGid = gid;
    currentEditTid = tid;
    
    const group = xmlData.groups.find(g => g.gid === gid);
    const template = group?.templates.find(t => t.tid === tid);
    if (!template) return;

    document.getElementById('editTemplateName').value = template.caption1;
    document.getElementById('editTemplateCaption2').value = template.caption2;

    const destinations = getTemplateDestinations(template);
    let destHtml = '';

    destinations.forEach((dest, idx) => {
        if (idx === 0) {
            destHtml += `
                <div class="form-group">
                    <label>Destination SMB ${idx + 1}</label>
                    <input type="text" id="dest_smb_path_${idx}" placeholder="Chemin SMB" value="${escapeHtml(dest.data.StorePath)}" style="margin-bottom: 10px;">
                    <input type="text" id="dest_smb_login_${idx}" placeholder="Identifiant" value="${escapeHtml(dest.data.UserName)}" style="margin-bottom: 10px;">
                    <div class="password-wrapper">
                        <input type="password" id="dest_smb_password_${idx}" placeholder="Mot de passe" value="${escapeHtml(dest.data.Password)}">
                        <button type="button" class="eye-icon" onclick="togglePasswordVisibility('dest_smb_password_${idx}')">👁</button>
                    </div>
                </div>
            `;
        }
    });

    document.getElementById('editDestinations').innerHTML = destHtml || '<p class="empty-message">Aucune destination SMB</p>';

    // Remplir les détails de scan
    const scanDetails = getScanDetails(template);
    const { type: ffType, mode: ffMode } = splitFileFormat(scanDetails.FileFormat);
    document.getElementById('editFileFormatType').value = ffType;
    document.getElementById('editFileFormatMode').value = ffMode;
    onFileFormatTypeChange();
    document.getElementById('editColorMode').value = scanDetails.ColorMode || '';
    document.getElementById('editImageRotate').value = scanDetails.ImageRotate || '';
    document.getElementById('editImageMode').value = scanDetails.ImageMode || '';
    document.getElementById('editDuplexMode').value = scanDetails.DuplexMode || '';
    document.getElementById('editResolution').value = scanDetails.Resolution || '';
    document.getElementById('editOriginalSizeDetection').value = scanDetails.OriginalSizeDetection || '';
    document.getElementById('editOmitBlankPage').value = scanDetails.OmitBlankPage || '';

    document.getElementById('editTemplateModal').classList.add('active');
}

function saveTemplateEdit() {
    const group = xmlData.groups.find(g => g.gid === currentEditGid);
    const template = group?.templates.find(t => t.tid === currentEditTid);
    if (!template) return;

    const newName = document.getElementById('editTemplateName').value.trim();
    const newCaption2 = document.getElementById('editTemplateCaption2').value.trim();
    
    template.caption1 = newName;
    template.caption2 = newCaption2;

    // Mettre à jour SMB
    const smbStores = template.xmlElement.querySelectorAll('SMBStore');
    smbStores.forEach((smbStore, idx) => {
        if (idx === 0) {
            const smbPath = document.getElementById(`dest_smb_path_${idx}`)?.value.trim();
            const smbLogin = document.getElementById(`dest_smb_login_${idx}`)?.value.trim();
            const smbPassword = document.getElementById(`dest_smb_password_${idx}`)?.value.trim();

            const smbParam = smbStore.querySelector('SMBStoreParameter');
            if (smbParam) {
                const storePath = smbParam.querySelector('StorePath');
                const userName = smbParam.querySelector('UserName');
                const password = smbParam.querySelector('Password');

                if (storePath) storePath.textContent = smbPath;
                if (userName) userName.textContent = smbLogin;
                if (password) password.textContent = smbPassword;
            }
        }
    });

    // Mettre à jour MetaData
    const metaData = template.xmlElement.querySelector('MetaData');
    if (metaData) {
        let caption1El = metaData.querySelector('caption1');
        if (!caption1El) {
            caption1El = xmlData.xmlDoc.createElement('caption1');
            metaData.appendChild(caption1El);
        }
        caption1El.textContent = newName;

        let caption2El = metaData.querySelector('caption2');
        if (!caption2El) {
            caption2El = xmlData.xmlDoc.createElement('caption2');
            metaData.appendChild(caption2El);
        }
        caption2El.textContent = newCaption2;
    }

    // Mettre à jour les paramètres de scan dans le XML
    const workflow = template.xmlElement.querySelector('Params > Queues > Scan > WorkflowExecutionParameter');
    if (workflow) {
        // ColorMode
        const colorParam = workflow.querySelector('ColorParameter');
        if (colorParam) {
            let colorModeEl = colorParam.querySelector('ColorMode');
            if (!colorModeEl) {
                colorModeEl = xmlData.xmlDoc.createElement('ColorMode');
                colorParam.appendChild(colorModeEl);
            }
            colorModeEl.textContent = document.getElementById('editColorMode').value;
        }

        // ImageAdjustmentParameter
        const imageAdj = workflow.querySelector('ImageAdjustmentParameter');
        if (imageAdj) {
            let imageModeEl = imageAdj.querySelector('ImageMode');
            if (!imageModeEl) {
                imageModeEl = xmlData.xmlDoc.createElement('ImageMode');
                imageAdj.appendChild(imageModeEl);
            }
            imageModeEl.textContent = document.getElementById('editImageMode').value;

            let imageRotateEl = imageAdj.querySelector('ImageRotate');
            if (!imageRotateEl) {
                imageRotateEl = xmlData.xmlDoc.createElement('ImageRotate');
                imageAdj.appendChild(imageRotateEl);
            }
            imageRotateEl.textContent = document.getElementById('editImageRotate').value;
        }

        // ScanParameter
        const scanParam = workflow.querySelector('Scan > ScanParameter');
        if (scanParam) {
            let duplexEl = scanParam.querySelector('DuplexMode');
            if (!duplexEl) {
                duplexEl = xmlData.xmlDoc.createElement('DuplexMode');
                scanParam.appendChild(duplexEl);
            }
            duplexEl.textContent = document.getElementById('editDuplexMode').value;

            let resolutionEl = scanParam.querySelector('Resolution');
            if (!resolutionEl) {
                resolutionEl = xmlData.xmlDoc.createElement('Resolution');
                scanParam.appendChild(resolutionEl);
            }
            resolutionEl.textContent = document.getElementById('editResolution').value;

            let autoDetectEl = scanParam.querySelector('AutoOriginalDetectionMode');
            if (!autoDetectEl) {
                autoDetectEl = xmlData.xmlDoc.createElement('AutoOriginalDetectionMode');
                scanParam.appendChild(autoDetectEl);
            }
            autoDetectEl.textContent = document.getElementById('editOriginalSizeDetection').value;

            let omitEl = scanParam.querySelector('OmitBlankPage > Enabled');
            if (!omitEl) {
                let omitParent = scanParam.querySelector('OmitBlankPage');
                if (!omitParent) {
                    omitParent = xmlData.xmlDoc.createElement('OmitBlankPage');
                    scanParam.appendChild(omitParent);
                }
                omitEl = xmlData.xmlDoc.createElement('Enabled');
                omitParent.appendChild(omitEl);
            }
            omitEl.textContent = document.getElementById('editOmitBlankPage').value;
        }

        // FileFormat : appliqué à TOUTES les destinations (EmailSend, SMBStore, USBStore, ...)
        // pour rester cohérent quelle que soit celle réellement activée sur le scanner.
        const output = workflow.querySelector('Scan > Output');
        if (output) {
            const newType = document.getElementById('editFileFormatType').value;
            const newMode = document.getElementById('editFileFormatMode').value;
            const newFileFormat = buildFileFormat(newType, newMode);

            if (newFileFormat) {
                output.querySelectorAll('FileFormatInformation').forEach(fileFormatInfo => {
                    let fileFormatEl = fileFormatInfo.querySelector('FileFormat');
                    if (!fileFormatEl) {
                        fileFormatEl = xmlData.xmlDoc.createElement('FileFormat');
                        fileFormatInfo.insertBefore(fileFormatEl, fileFormatInfo.firstChild);
                    }
                    fileFormatEl.textContent = newFileFormat;
                });
            }
        }
    }

    closeModal('editTemplateModal');
    renderGroups();
    showNotification('Template modifié avec succès');
}

// ==========================================
// CRÉATION D'UN NOUVEAU TEMPLATE
// ==========================================

function createTemplate(gid) {
    const group = xmlData.groups.find(g => g.gid === gid);
    if (!group) return;

    // Modèle : premier template du groupe (structure SMB + params de scan complets)
    let sourceEl = group.templates[0]?.xmlElement;
    if (!sourceEl) {
        const otherGroup = xmlData.groups.find(g => g.templates.length > 0);
        sourceEl = otherGroup?.templates[0]?.xmlElement;
    }
    if (!sourceEl) {
        showNotification('Aucun template modèle disponible pour la création', 'error');
        return;
    }

    const clonedEl = sourceEl.cloneNode(true);
    const newTid = String(group.templates.length + 1).padStart(3, '0');
    clonedEl.setAttribute('tid', newTid);
    clonedEl.setAttribute('gid', group.gid);

    // MetaData : nom par défaut + TemplateCount
    const metaData = clonedEl.querySelector('MetaData');
    if (metaData) {
        let caption1El = metaData.querySelector('caption1');
        if (!caption1El) {
            caption1El = xmlData.xmlDoc.createElement('caption1');
            metaData.appendChild(caption1El);
        }
        caption1El.textContent = 'Nouveau Template';

        let caption2El = metaData.querySelector('caption2');
        if (!caption2El) {
            caption2El = xmlData.xmlDoc.createElement('caption2');
            metaData.appendChild(caption2El);
        }
        caption2El.textContent = '';
    }

    // Insérer dans la TemplateList du groupe
    const templateList = group.xmlElement.querySelector('TemplateList');
    if (templateList) {
        templateList.appendChild(clonedEl);
    } else {
        group.xmlElement.appendChild(clonedEl);
    }

    const newTemplate = parseTemplate(clonedEl, group.gid);
    group.templates.push(newTemplate);
    updateTemplateCount(group);

    renderGroups();
    editTemplate(group.gid, newTemplate.tid);
    showNotification('Template créé — personnalisez-le');
}

function deleteTemplate(gid, tid) {
    showConfirm(
        'Supprimer le template ?',
        'Êtes-vous sûr de vouloir supprimer ce template ?',
        function() {
            const group = xmlData.groups.find(g => g.gid === gid);
            const template = group?.templates.find(t => t.tid === tid);

            if (template) {
                template.xmlElement.remove();
                group.templates = group.templates.filter(t => t.tid !== tid);
            }

            renumberTids(group);
            renderGroups();
            showNotification('Template supprimé — TIDs renumérotés');
        }
    );
}

// ==========================================
// EXPORT XML
// ==========================================

function downloadXML() {
    if (!xmlData || !xmlData.xmlDoc) {
        showNotification('Aucun fichier XML chargé', 'error');
        return;
    }

    const serializer = new XMLSerializer();
    const xmlString = serializer.serializeToString(xmlData.xmlDoc);
    const blob = new Blob([xmlString], { type: 'text/xml' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'toshiba_scan_templates.xml';
    a.click();
    window.URL.revokeObjectURL(url);

    showNotification('XML exporté avec succès');
}

// ==========================================
// CHARGEMENT AUTOMATIQUE DU XML PAR DÉFAUT
// ==========================================

function loadDefaultXML() {
    fetch('/load-default-xml')
        .then(response => response.json())
        .then(data => {
            if (data.success && data.xmlContent) {
                try {
                    const parser = new DOMParser();
                    const xmlDoc = parser.parseFromString(data.xmlContent, 'text/xml');

                    if (xmlDoc.getElementsByTagName('parsererror').length > 0) {
                        console.error('Erreur : XML invalide');
                        return;
                    }

                    xmlData = {
                        xmlDoc: xmlDoc,
                        groups: []
                    };

                    xmlDoc.querySelectorAll('Group').forEach(groupEl => {
                        const group = parseGroup(groupEl);
                        xmlData.groups.push(group);
                    });

                    console.log('XML chargé avec succès:', xmlData);
                    renderGroups();
                } catch (error) {
                    console.error('Erreur lors du chargement du XML:', error);
                }
            }
        })
        .catch(error => console.error('Erreur fetch:', error));
}

// ==========================================
// INITIALISATION
// ==========================================

document.addEventListener('DOMContentLoaded', function() {
    loadDefaultXML();
});

document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
        document.querySelectorAll('.modal.active').forEach(modal => {
            modal.classList.remove('active');
        });
    }
});