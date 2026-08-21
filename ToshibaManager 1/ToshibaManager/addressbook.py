import csv
import io
import os
import re
import unicodedata

import openpyxl

EMAIL_RE = re.compile(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$')

ADDR_HEADERS = [
    'First Name', 'Last Name', 'Email Address', 'Tel Number', '2nd Fax Number',
    'IPFax Destination', 'Facsimile Mode', 'Company', 'Department', 'Keyword',
    'Furigana', 'SUB', 'SID', 'SEP', 'PWD', 'ECM', 'Line Select',
    'Quality Transmit', 'Transmission Type', 'Attenuation', 'FavoriteFax',
    'FavoritEmail',
]

KEYWORDS = {
    'email': ('email', 'mail', 'courriel', 'e mail', 'e-mail'),
    'first': ('prenom', 'first', 'given', 'forename'),
    'combined': ('nom complet', 'nom et prenom', 'nom & prenom', 'nom et prénom',
                 'nom + prenom', 'nom + prénom', 'full name', 'identite',
                 'identité', 'nom prenom', 'nom prénom', 'contact'),
    'combined_loose': ('client', 'destinataire', 'interlocuteur'),
    'last': ('nom', 'name', 'last', 'surname', 'family'),
    'company': ('societe', 'company', 'entreprise', 'raison sociale', 'raison'),
    'dept': ('departement', 'department', 'service', 'division', 'direction'),
    'phone': ('telephone', 'portable', 'mobile', 'gsm', 'tel', 'phone'),
}


def _norm(h):
    h = unicodedata.normalize('NFD', h or '')
    h = ''.join(c for c in h if unicodedata.category(c) != 'Mn')
    return re.sub(r'[^a-z0-9]+', ' ', h.lower()).strip()


def _clean(v):
    if v is None:
        return ''
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if isinstance(v, bool):
        return 'Oui' if v else 'Non'
    return str(v).strip()


def _trim_row(row):
    while row and row[-1] == '':
        row.pop()
    return row


def read_rows(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xlsx':
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        ws = wb.active
        rows = [_trim_row([_clean(c) for c in row]) for row in ws.iter_rows(values_only=True)]
        wb.close()
    elif ext == '.xls':
        import xlrd
        wb = xlrd.open_workbook(path)
        ws = wb.sheet_by_index(0)
        rows = [_trim_row([_clean(c) for c in ws.row_values(r)]) for r in range(ws.nrows)]
    else:
        raw = open(path, 'rb').read()
        text = None
        for enc in ('utf-8-sig', 'cp1252', 'latin-1'):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        if text is None:
            text = raw.decode('utf-8', 'replace')
        dialect = csv.excel
        try:
            dialect = csv.Sniffer().sniff(text[:2048], delimiters=';,\t')
        except csv.Error:
            pass
        rows = [_trim_row([_clean(c) for c in r]) for r in csv.reader(io.StringIO(text), dialect)]
    return [r for r in rows if any(r)]


def _header_type(h):
    n = _norm(h)
    if not n:
        return None
    if any(k in n for k in KEYWORDS['email']):
        return 'email'
    if any(k in n for k in KEYWORDS['first']):
        return 'first'
    if any(k in n for k in KEYWORDS['combined']):
        return 'combined'
    has_nom = any(k in n for k in ('nom', 'name', 'last', 'surname', 'family'))
    has_prenom = any(k in n for k in ('prenom', 'first', 'given'))
    if has_nom and has_prenom:
        return 'combined'
    if has_nom:
        return 'last'
    if any(k in n for k in KEYWORDS['company']):
        return 'company'
    if any(k in n for k in KEYWORDS['dept']):
        return 'dept'
    if any(k in n for k in KEYWORDS['phone']):
        return 'phone'
    return None


def _find_header_row(rows):
    for i, row in enumerate(rows[:10]):
        types = [_header_type(c) for c in row]
        if any(t in ('email', 'first', 'last', 'combined') for t in types):
            return i
    return 0


def _email_score(rows, col_idx):
    n = 0
    for r in rows[1:21]:
        if col_idx < len(r) and EMAIL_RE.match(r[col_idx].strip()):
            n += 1
    return n


def parse_workbook(path):
    rows = read_rows(path)
    header_idx = _find_header_row(rows)
    headers = rows[header_idx] if header_idx < len(rows) else []
    data = rows[header_idx + 1:] if header_idx + 1 < len(rows) else []
    n_cols = max([len(r) for r in rows] or [0])

    detected = {}
    loose_candidates = []
    last_col = None
    for ci in range(min(n_cols, 40)):
        t = _header_type(headers[ci]) if ci < len(headers) else None
        if t == 'email' and 'email' not in detected:
            detected['email'] = ci
        elif t == 'first' and 'first' not in detected:
            detected['first'] = ci
        elif t == 'combined' and 'combined' not in detected:
            detected['combined'] = ci
        elif t == 'last' and 'last' not in detected:
            detected['last'] = ci
            last_col = ci
        elif t == 'company' and 'company' not in detected:
            detected['company'] = ci
        elif t == 'dept' and 'dept' not in detected:
            detected['dept'] = ci
        elif t == 'phone' and 'phone' not in detected:
            detected['phone'] = ci
        elif t == 'combined_loose':
            loose_candidates.append(ci)

    if 'email' not in detected:
        best, best_score = None, 0
        for ci in range(min(n_cols, 40)):
            s = _email_score(rows, ci)
            if s > best_score:
                best, best_score = ci, s
        if best is not None and best_score >= 3:
            detected['email'] = best

    def multi_word_ratio(col_idx):
        total, multi = 0, 0
        for r in data:
            v = _cell(r, col_idx).strip()
            if v:
                total += 1
                if len(v.split()) >= 2:
                    multi += 1
        return (multi / total) if total else 0

    if 'combined' not in detected:
        for ci in loose_candidates:
            if multi_word_ratio(ci) >= 0.6:
                detected['combined'] = ci
                break

    if 'combined' not in detected and 'last' in detected and 'first' not in detected:
        if multi_word_ratio(last_col) >= 0.6:
            detected['combined'] = detected.pop('last')

    headers_display = [('Colonne ' + str(i + 1)) if c == '' else c for i, c in enumerate(headers)]

    return {
        'headers': headers_display,
        'sample': data[:8],
        'totalRows': len(data),
        'detected': detected,
        'nCols': n_cols,
    }


def split_name(raw, order):
    raw = (raw or '').strip()
    if not raw:
        return '', ''
    if ',' in raw:
        last, first = raw.split(',', 1)
        return first.strip(), last.strip()
    parts = raw.split()
    if len(parts) == 1:
        return raw, ''
    if order == 'last_first':
        return ' '.join(parts[1:]), parts[0]
    if order == 'first_last':
        return parts[0], ' '.join(parts[1:])
    upper_count = sum(1 for p in parts if p.isupper())
    if parts[0].isupper() or upper_count >= len(parts) - 1:
        return ' '.join(parts[1:]), parts[0]
    return parts[0], ' '.join(parts[1:])


def _cell(row, idx):
    if idx is None or idx >= len(row):
        return ''
    return row[idx]


def generate_csv(path, mapping, order='auto'):
    rows = read_rows(path)
    header_idx = _find_header_row(rows)
    data = rows[header_idx + 1:] if header_idx + 1 < len(rows) else []

    ei = mapping.get('email')
    fi = mapping.get('first')
    li = mapping.get('last')
    ci = mapping.get('combined')
    co = mapping.get('company')
    dp = mapping.get('dept')
    ph = mapping.get('phone')

    seen, valid, no_email, bad_email, dupes = set(), 0, 0, 0, 0
    out = []
    for r in data:
        if not any(r):
            continue
        email = _cell(r, ei).strip().lower()
        if not email:
            no_email += 1
            continue
        if not EMAIL_RE.match(email):
            bad_email += 1
            continue
        if email in seen:
            dupes += 1
            continue
        seen.add(email)

        if ci is not None:
            first, last = split_name(_cell(r, ci), order)
        else:
            first = _cell(r, fi)
            last = _cell(r, li)

        out.append([
            first, last, email,
            _cell(r, ph), '', '', '',
            _cell(r, co), _cell(r, dp),
            '', '', '', '', '', '', '', '', '', '', '', '', '',
        ])
        valid += 1

    lines = [_make_line(ADDR_HEADERS)]
    lines += [_make_line(row) for row in out]
    content = '\ufeff' + '\r\n'.join(lines) + '\r\n'

    stats = {
        'total': len(data),
        'valides': valid,
        'sans_email': no_email,
        'email_invalide': bad_email,
        'doublons': dupes,
    }
    return content, stats


def _make_line(fields):
    return ','.join('"' + str(f).replace('"', '""') + '"' for f in fields)
