(function () {
    const dropzone = document.getElementById('abDropzone');
    const fileInput = document.getElementById('abFile');
    const body = document.getElementById('abBody');
    const feedback = document.getElementById('abFeedback');
    const resultBox = document.getElementById('abResult');

    const selEmail = document.getElementById('mapEmail');
    const selLast = document.getElementById('mapLast');
    const selFirst = document.getElementById('mapFirst');
    const selCompany = document.getElementById('mapCompany');
    const selDept = document.getElementById('mapDept');
    const selPhone = document.getElementById('mapPhone');
    const chkCombined = document.getElementById('abCombined');
    const orderWrap = document.getElementById('abOrderWrap');
    const selOrder = document.getElementById('abOrder');

    let state = null; // { fileId, headers, detected, sample }

    const ORDER_SELECTS = [selLast, selFirst, selCompany, selDept, selPhone];

    // ---------- Dropzone ----------
    dropzone.addEventListener('click', () => fileInput.click());
    dropzone.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); }
    });
    ['dragenter', 'dragover'].forEach(ev => dropzone.addEventListener(ev, e => {
        e.preventDefault();
        dropzone.classList.add('dragover');
    }));
    ['dragleave', 'drop'].forEach(ev => dropzone.addEventListener(ev, e => {
        e.preventDefault();
        dropzone.classList.remove('dragover');
    }));
    dropzone.addEventListener('drop', e => {
        const f = e.dataTransfer.files && e.dataTransfer.files[0];
        if (f) uploadFile(f);
    });
    fileInput.addEventListener('change', () => {
        if (fileInput.files && fileInput.files[0]) uploadFile(fileInput.files[0]);
        fileInput.value = '';
    });

    // ---------- Upload / parse ----------
    function uploadFile(file) {
        resultBox.hidden = true;
        resultBox.className = 'ab-result';
        setDropzoneLoading(true);
        showFeedback('info', 'Analyse de « ' + file.name + ' »…');
        const fd = new FormData();
        fd.append('file', file);
        fetch('/api/addressbook/parse', { method: 'POST', body: fd })
            .then(r => r.json())
            .then(data => {
                setDropzoneLoading(false);
                if (!data.success) throw new Error(data.error || 'Erreur lors de l’analyse');
                state = data;
                buildMapping();
                body.hidden = false;
                showFeedback('success',
                    data.totalRows + ' ligne' + (data.totalRows > 1 ? 's' : '') + ' détectée' + (data.totalRows > 1 ? 's' : '') +
                    ' — colonnes identifiées automatiquement, vérifiez la correspondance.');
                window.scrollTo({ top: body.getBoundingClientRect().top + window.scrollY - 120, behavior: 'smooth' });
            })
            .catch(err => {
                setDropzoneLoading(false);
                body.hidden = true;
                showFeedback('error', err.message);
            });
    }

    function setDropzoneLoading(on) {
        dropzone.classList.toggle('loading', on);
        dropzone.style.pointerEvents = on ? 'none' : '';
    }

    function showFeedback(kind, msg) {
        feedback.hidden = false;
        feedback.className = 'ab-feedback ' + kind;
        feedback.textContent = msg;
    }

    // ---------- Mapping ----------
    function fillSelect(sel, headers, selected) {
        sel.innerHTML = '';
        const none = document.createElement('option');
        none.value = '';
        none.textContent = '— Non mappé —';
        sel.appendChild(none);
        headers.forEach((h, i) => {
            const opt = document.createElement('option');
            opt.value = i;
            opt.textContent = h;
            if (i === selected) opt.selected = true;
            sel.appendChild(opt);
        });
    }

    function buildMapping() {
        const d = state.detected || {};
        fillSelect(selEmail, state.headers, d.email);
        fillSelect(selLast, state.headers, d.last);
        fillSelect(selFirst, state.headers, d.first);
        fillSelect(selCompany, state.headers, d.company);
        fillSelect(selDept, state.headers, d.dept);
        fillSelect(selPhone, state.headers, d.phone);

        const combined = d.combined != null;
        chkCombined.checked = combined;
        orderWrap.hidden = !combined;
        if (combined) selLast.value = d.combined;
        syncCombined();
        renderPreview();
    }

    function syncCombined() {
        const isCombined = chkCombined.checked;
        selFirst.disabled = isCombined;
        selLast.disabled = false;
        if (isCombined && selLast.value === '') selLast.value = selLast.options[1] ? selLast.options[1].value : '';
        orderWrap.hidden = !isCombined;
        renderPreview();
    }
    chkCombined.addEventListener('change', syncCombined);
    [selEmail, selLast, selFirst, selCompany, selDept, selPhone, selOrder].forEach(s =>
        s.addEventListener('change', renderPreview)
    );

    // ---------- Aperçu ----------
    function splitName(raw, order) {
        raw = (raw || '').trim();
        if (!raw) return ['', ''];
        if (raw.indexOf(',') !== -1) {
            const parts = raw.split(',');
            return [parts[1].trim(), parts[0].trim()];
        }
        const parts = raw.split(/\s+/);
        if (parts.length === 1) return [raw, ''];
        if (order === 'last_first') return [parts.slice(1).join(' '), parts[0]];
        if (order === 'first_last') return [parts[0], parts.slice(1).join(' ')];
        const upper = parts.filter(p => p === p.toUpperCase() && /[A-ZÀ-Ü]/.test(p)).length;
        if (parts[0] === parts[0].toUpperCase() && /[A-ZÀ-Ü]/.test(parts[0])) return [parts.slice(1).join(' '), parts[0]];
        if (upper >= parts.length - 1) return [parts.slice(1).join(' '), parts[0]];
        return [parts[0], parts.slice(1).join(' ')];
    }

    function renderPreview() {
        if (!state) return;
        const order = selOrder.value;
        const combined = chkCombined.checked;
        const get = (row, idx) => (idx !== null && idx !== undefined && row[idx] !== undefined) ? String(row[idx]) : '';
        const preview = (state.sample || []).map(row => {
            let first = '', last = '';
            if (combined) {
                const s = splitName(get(row, selLast.value), order);
                first = s[0]; last = s[1];
            } else {
                first = get(row, selFirst.value);
                last = get(row, selLast.value);
            }
            return {
                first, last,
                email: get(row, selEmail.value),
                company: get(row, selCompany.value),
                phone: get(row, selPhone.value),
            };
        });

        const tbody = document.getElementById('abPreviewBody');
        tbody.innerHTML = preview.map(p => {
            const empty = p.first === '' && p.last === '' && p.email === '';
            return '<tr' + (empty ? ' class="ab-row-empty"' : '') + '>' +
                '<td>' + escapeHtml(p.first) + '</td>' +
                '<td>' + escapeHtml(p.last) + '</td>' +
                '<td>' + escapeHtml(p.email) + '</td>' +
                '<td>' + escapeHtml(p.company) + '</td>' +
                '<td>' + escapeHtml(p.phone) + '</td>' +
                '</tr>';
        }).join('');

        const n = state.totalRows || 0;
        document.getElementById('abCount').textContent = n + ' contact' + (n > 1 ? 's' : '') + ' (aperçu des 8 premiers)';
    }

    function escapeHtml(s) {
        return s.replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    // ---------- Génération ----------
    document.getElementById('abGenerate').addEventListener('click', () => {
        if (!state) return;
        if (selEmail.value === '') {
            showFeedback('error', 'Sélectionnez une colonne pour l’adresse e-mail.');
            return;
        }
        const btn = document.getElementById('abGenerate');
        btn.disabled = true;
        btn.textContent = '⏳ Génération…';
        resultBox.hidden = true;

        const mapping = {
            email: parseInt(selEmail.value, 10),
            last: selLast.value === '' ? null : parseInt(selLast.value, 10),
            first: chkCombined.checked ? null : (selFirst.value === '' ? null : parseInt(selFirst.value, 10)),
            combined: chkCombined.checked ? parseInt(selLast.value, 10) : null,
            company: selCompany.value === '' ? null : parseInt(selCompany.value, 10),
            dept: selDept.value === '' ? null : parseInt(selDept.value, 10),
            phone: selPhone.value === '' ? null : parseInt(selPhone.value, 10),
        };

        fetch('/api/addressbook/generate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ fileId: state.fileId, mapping, order: selOrder.value }),
        })
            .then(r => r.json())
            .then(data => {
                if (!data.success) throw new Error(data.error || 'Erreur lors de la génération');
                const blob = new Blob([data.csv], { type: 'text/csv;charset=utf-8' });
                const a = document.createElement('a');
                a.href = URL.createObjectURL(blob);
                a.download = data.filename;
                document.body.appendChild(a);
                a.click();
                a.remove();
                setTimeout(() => URL.revokeObjectURL(a.href), 4000);

                const s = data.stats;
                let html = '✅ <strong>' + s.valides + '</strong> contact' + (s.valides > 1 ? 's' : '') + ' valide' + (s.valides > 1 ? 's' : '') + ' exporté' + (s.valides > 1 ? 's' : '');
                if (s.sans_email) html += ' · ' + s.sans_email + ' sans e-mail ignoré' + (s.sans_email > 1 ? 's' : '');
                if (s.email_invalide) html += ' · ' + s.email_invalide + ' e-mail invalide ignoré' + (s.email_invalide > 1 ? 's' : '');
                if (s.doublons) html += ' · ' + s.doublons + ' doublon' + (s.doublons > 1 ? 's' : '') + ' ignoré' + (s.doublons > 1 ? 's' : '');
                html += '<div class="ab-result-file">📄 Téléchargé : <strong>' + data.filename + '</strong></div>';
                resultBox.innerHTML = html;
                resultBox.hidden = false;
                showFeedback('success', 'CSV généré avec succès.');
            })
            .catch(err => showFeedback('error', err.message))
            .finally(() => {
                btn.disabled = false;
                btn.textContent = '⚙️ Générer le CSV';
            });
    });
})();
