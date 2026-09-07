import csv
import io
import os
import re
import unicodedata

import openpyxl

EMAIL_RE = re.compile(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$')

TOSHIBA_SAFE_RE = re.compile(r'^[a-zA-Z0-9\s\.\,\-\_\@\:\/\(\)\+]+$')

UNSAFE_CHARS = set('*!#%&=+{}<>[]|\\~^`"\'?;:$_')


def strip_accents(text):
    if not text:
        return text
    return unicodedata.normalize('NFKD', text).encode('ascii', 'ignore').decode('ascii')


def clean_cell(text, do_strip_accents=True):
    if not text:
        return text
    if do_strip_accents:
        text = strip_accents(text)
    text = ''.join(c for c in text if c not in UNSAFE_CHARS)
    return text


SPECIAL_CHARS_MAP = {
    'e': ['\u00e9', '\u00e8', '\u00ea', '\u00eb', '\u00c9', '\u00c8', '\u00ca', '\u00cb'],
    'a': ['\u00e0', '\u00e2', '\u00e4', '\u00c0', '\u00c2', '\u00c4'],
    'u': ['\u00f9', '\u00fb', '\u00fc', '\u00d9', '\u00db', '\u00dc'],
    'i': ['\u00ec', '\u00ee', '\u00ef', '\u00cc', '\u00ce', '\u00cf'],
    'o': ['\u00f2', '\u00f4', '\u00f6', '\u00d2', '\u00d4', '\u00d6'],
    'c': ['\u00e7', '\u00c7'],
    'y': ['\u00ff', '\u0178'],
    'n': ['\u00f1', '\u00d1'],
    's': ['\u00df', '\u0160', '\u0161'],
    'ss': ['\u00df'],
    'ae': ['\u00e6', '\u00c6'],
    'oe': ['\u0153', '\u0152'],
}

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


def _find_special_chars(text):
    issues = []
    for char in text:
        if char in UNSAFE_CHARS:
            issues.append({'char': char, 'code': f'U+{ord(char):04X}', 'replace': ''})
        elif ord(char) > 127:
            for base, variants in SPECIAL_CHARS_MAP.items():
                if char in variants:
                    issues.append({'char': char, 'code': f'U+{ord(char):04X}', 'replace': base})
                    break
            else:
                issues.append({'char': char, 'code': f'U+{ord(char):04X}', 'replace': ''})
    return issues


def detect_issues(data, email_col, name_col=None, company_col=None, phone_col=None, all_cols=None, first_col=None):
    seen_emails = {}
    seen_names = {}
    issues_by_row = []
    stats = {'doublons': 0, 'chars_speciaux': 0, 'emails_invalides': 0, 'lignes_total': len(data)}

    if all_cols is None:
        all_cols = [c for c in [email_col, name_col, company_col, phone_col] if c is not None]

    text_cols = [c for c in all_cols if c is not None and c != email_col]

    for row_idx, row in enumerate(data):
        row_issues = {'row': row_idx, 'email_issue': None, 'char_issues': [], 'is_duplicate': False, 'duplicate_of': None}

        if email_col is not None and email_col < len(row):
            email = row[email_col].strip().lower()
            if email:
                if not EMAIL_RE.match(email):
                    row_issues['email_issue'] = 'invalide'
                    stats['emails_invalides'] += 1
                elif email in seen_emails:
                    row_issues['is_duplicate'] = True
                    row_issues['email_issue'] = 'doublon'
                    row_issues['duplicate_of'] = seen_emails[email]
                    stats['doublons'] += 1
                else:
                    seen_emails[email] = row_idx

        if name_col is not None and name_col < len(row):
            last_name = row[name_col].strip().lower()
            first_name = ''
            if first_col is not None and first_col < len(row):
                first_name = row[first_col].strip().lower()
            full_name = (first_name + ' ' + last_name).strip()
            if full_name and len(full_name) >= 3:
                if full_name in seen_names and not row_issues['is_duplicate']:
                    row_issues['is_duplicate'] = True
                    row_issues['duplicate_of'] = seen_names[full_name]
                    if not row_issues['email_issue']:
                        row_issues['email_issue'] = 'doublon'
                    stats['doublons'] += 1
                else:
                    seen_names[full_name] = row_idx
        elif not row_issues['is_duplicate']:
            parts = []
            for c in text_cols:
                if c < len(row) and row[c].strip():
                    val = row[c].strip().lower()
                    if '@' in val:
                        continue
                    parts.append(val)
            key = '|'.join(parts) if parts else ''
            if key and key in seen_names:
                row_issues['is_duplicate'] = True
                row_issues['duplicate_of'] = seen_names[key]
                if not row_issues['email_issue']:
                    row_issues['email_issue'] = 'doublon'
                stats['doublons'] += 1
            elif key:
                seen_names[key] = row_idx

        for col_idx in all_cols:
            if col_idx is not None and col_idx != email_col and col_idx < len(row):
                cell_text = row[col_idx]
                char_issues = _find_special_chars(cell_text)
                if char_issues:
                    row_issues['char_issues'].append({'col': col_idx, 'issues': char_issues})
                    stats['chars_speciaux'] += len(char_issues)
                    print(f"  row {row_idx}: chars speciaux dans col {col_idx}: {[i['char'] for i in char_issues]}")

        if row_issues['email_issue'] or row_issues['is_duplicate'] or row_issues['char_issues']:
            issues_by_row.append(row_issues)

    return {'stats': stats, 'issues': issues_by_row}


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

    email_col = detected.get('email')
    name_col = detected.get('combined') or detected.get('last')
    company_col = detected.get('company')
    phone_col = detected.get('phone')

    scan_cols = set()
    for c in [email_col, name_col, company_col, phone_col]:
        if c is not None:
            scan_cols.add(c)

    for ci in range(min(n_cols, 40)):
        if ci not in scan_cols:
            scan_cols.add(ci)

    all_col_list = sorted(scan_cols)

    issues_result = detect_issues(data, email_col, name_col, company_col, phone_col, all_col_list, first_col=detected.get('first'))

    return {
        'headers': headers_display,
        'sample': data,
        'totalRows': len(data),
        'detected': detected,
        'nCols': n_cols,
        'issues': issues_result['stats'],
        'issues_detail': issues_result['issues'][:50],
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


def generate_csv(path, mapping, order='auto', excluded_rows=None, strip_accents_flag=True):
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

    excluded = set(excluded_rows) if excluded_rows else set()
    seen_emails, seen_names = set(), set()
    valid, no_email, bad_email, dupes_email, dupes_name, manual_excl = 0, 0, 0, 0, 0, 0
    out = []
    for row_idx, r in enumerate(data):
        if not any(r):
            continue
        if row_idx in excluded:
            manual_excl += 1
            continue
        email = _cell(r, ei).strip().lower()
        if not email:
            no_email += 1
            continue
        if not EMAIL_RE.match(email):
            bad_email += 1
            continue
        if email in seen_emails:
            dupes_email += 1
            continue
        seen_emails.add(email)

        if ci is not None:
            first, last = split_name(_cell(r, ci), order)
        else:
            first = _cell(r, fi)
            last = _cell(r, li)

        name_key = (first.strip().lower() + ' ' + last.strip().lower()).strip()
        if name_key and name_key in seen_names:
            dupes_name += 1
            continue
        if name_key:
            seen_names.add(name_key)

        first = clean_cell(first, strip_accents_flag)
        last = clean_cell(last, strip_accents_flag)
        company = clean_cell(_cell(r, co), strip_accents_flag)
        dept = clean_cell(_cell(r, dp), strip_accents_flag)
        phone = clean_cell(_cell(r, ph), strip_accents_flag)

        out.append([
            first, last, email,
            phone, '', '', '',
            company, dept,
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
        'doublons': dupes_email + dupes_name,
        'exclus_manuellement': manual_excl,
    }
    return content, stats


def _make_line(fields):
    return ','.join('"' + str(f).replace('"', '""') + '"' for f in fields)
