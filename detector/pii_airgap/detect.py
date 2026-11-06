"""Hybrid PII detection: checksum-validated identifiers, patterns with
context words, user lists and an optional NER backend.

Overlaps are resolved by source (checksum and user lists beat patterns,
patterns beat the model), then confidence, then length.
"""

import hashlib
import re

from . import validators as v

VERSION = "2"

# Words that must appear shortly before a weak match (lowercase regexes).
_CTX = {
    "pesel": [r"pesel"],
    "nip": [r"nip", r"vat", r"tax", r"steuer", r"ust-?id", r"nif"],
    "regon": [r"regon"],
    "idcard": [r"dow[oó]d", r"id card", r"identity card", r"personalausweis", r"ausweis"],
    "passport": [r"paszport", r"passport", r"reisepass", r"pass-?nr"],
    "ssn": [r"ssn", r"social security"],
    "detax": [r"steuer-?id", r"steuer-?identifikationsnummer", r"idnr", r"tin", r"tax id"],
    "bsn": [r"bsn", r"burgerservicenummer", r"sofinummer"],
    "phone": [r"tel", r"phone", r"telefon", r"mobile?", r"kom", r"kom[oó]rk", r"fax", r"handy", r"cell"],
    "dob": [r"ur\.", r"urodz", r"data urodzenia", r"born", r"birth", r"dob", r"d\.o\.b",
            r"geb\.", r"geboren", r"geburtsdatum"],
}
_CTX_RE = {k: re.compile(r"(?<![\w])(?:%s)" % "|".join(ws), re.I) for k, ws in _CTX.items()}

_MONTHS = (
    "stycznia|lutego|marca|kwietnia|maja|czerwca|lipca|sierpnia|wrze[sś]nia|pa[zź]dziernika|listopada|grudnia|"
    "styczeń|luty|marzec|kwiecień|maj|czerwiec|lipiec|sierpień|wrzesień|październik|listopad|grudzień|"
    "January|February|March|April|May|June|July|August|September|October|November|December|"
    "Januar|Jänner|Februar|März|Mai|Juni|Juli|Oktober|Dezember"
)
_UP = "A-ZĄĆĘŁŃÓŚŹŻÄÖÜ"
_LO = "a-ząćęłńóśźżäöüß"


class Finding(object):
    __slots__ = ("start", "end", "type", "kind", "confidence", "source", "text")

    def __init__(self, start, end, type, kind, confidence, source, text=None):
        self.start, self.end, self.type, self.kind = start, end, type, kind
        self.confidence, self.source, self.text = confidence, source, text

    def __repr__(self):
        return "Finding(%d, %d, %s, %r, %.2f)" % (self.start, self.end, self.type, self.text, self.confidence)


class Rule(object):
    def __init__(self, kind, type, pattern, validator=None, context=None, required=False,
                 confidence=0.9, boosted=0.99, trim=False, flags=0, source=None):
        self.kind, self.type = kind, type
        self.regex = re.compile(pattern, flags)
        self.validator, self.context, self.required = validator, context, required
        self.confidence, self.boosted, self.trim = confidence, boosted, trim
        self.source = source or ("checksum" if validator is not None else "pattern")


def _phone_digits_ok(s):
    n = len(re.sub(r"\D", "", s))
    return 8 <= n <= 15


def _date_ok(s):
    m = re.fullmatch(r"(\d{1,2})[./-](\d{1,2})[./-](\d{4})", s)
    if m:
        return v._valid_date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        return v._valid_date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return True


_LEGAL_WORDS = {"ag", "kg", "ohg", "ug", "gmbh", "ltd", "ltd.", "llc", "llp", "inc", "inc.", "plc", "corp", "corp.",
                "sp.", "z", "o.o.", "s.a.", "i", "und", "and", "&", "co.", "b.v.", "n.v."}


def _company_ok(s):
    """A legal form needs a name before it, not just another legal form."""
    return any(w.lower() not in _LEGAL_WORDS for w in s.split()[:-1] if w.lower() not in ("sp.", "z", "o.o."))


B, E = r"(?<![\w])", r"(?![\w])"

RULES = [
    Rule("email", "EMAIL", r"(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}" + E,
         confidence=0.95),
    Rule("iban", "IBAN", B + r"[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?" + E,
         v.iban_valid, trim=True, confidence=0.99),
    Rule("card", "CARD", B + r"\d(?:[ -]?\d){12,18}" + E, v.card_valid, trim=True, confidence=0.97),
    Rule("pl_pesel", "PESEL", B + r"\d{11}" + E, v.pesel_valid, "pesel", confidence=0.95),
    Rule("pl_nip", "NIP", B + r"(?:PL ?)?(?:\d{3}-\d{3}-\d{2}-\d{2}|\d{3}-\d{2}-\d{2}-\d{3}|\d{10})" + E,
         v.nip_valid, "nip", required=True),
    Rule("pl_regon", "REGON", B + r"(?:\d{9}|\d{14})" + E, v.regon_valid, "regon", required=True),
    Rule("pl_id_card", "IDCARD", B + r"[A-Z]{3} ?\d{6}" + E, v.pl_idcard_valid, "idcard", required=True),
    Rule("pl_passport", "PASSPORT", B + r"[A-Z]{2} ?\d{7}" + E, v.pl_passport_valid, "passport", required=True),
    Rule("us_ssn", "SSN", r"(?<![\w-])\d{3}-\d{2}-\d{4}(?![\w-])", v.us_ssn_valid, "ssn", confidence=0.85),
    Rule("us_ssn", "SSN", B + r"\d{3} \d{2} \d{4}" + E, v.us_ssn_valid, "ssn", required=True),
    Rule("de_tax_id", "TAXID", B + r"\d{2} ?\d{3} ?\d{3} ?\d{3}" + E, v.de_taxid_valid, "detax", required=True),
    Rule("es_dni", "NATIONALID", B + r"(?:[XYZ]\d{7}|\d{8})-?[A-Z]" + E, v.es_dni_valid, confidence=0.9),
    Rule("it_codice_fiscale", "TAXID", B + r"[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z]" + E,
         v.it_cf_valid, confidence=0.97),
    Rule("fr_nir", "NATIONALID", B + r"[12] ?\d{2} ?\d{2} ?(?:\d{2}|2A|2B) ?\d{3} ?\d{3} ?\d{2}" + E,
         v.fr_nir_valid, confidence=0.95),
    Rule("nl_bsn", "NATIONALID", B + r"\d{9}" + E, v.nl_bsn_valid, "bsn", required=True),
    Rule("se_personnummer", "NATIONALID", B + r"(?:\d{2})?\d{6}[-+]\d{4}" + E, v.se_pnr_valid, confidence=0.93),
    Rule("fi_hetu", "NATIONALID", B + r"\d{6}[-+A-FU-Y]\d{3}[0-9A-Y]" + E, v.fi_hetu_valid, confidence=0.97),
    Rule("be_national_number", "NATIONALID", B + r"\d{2}\.\d{2}\.\d{2}-\d{3}\.\d{2}" + E, v.be_nrn_valid,
         confidence=0.97),
    Rule("phone_intl", "PHONE", r"(?<![\w+])\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?){2,6}" + E, _phone_digits_ok,
         "phone", confidence=0.85, boosted=0.95, trim=True),
    Rule("phone_local", "PHONE", B + r"(?:\d{3}[ -]\d{3}[ -]\d{3}|\d{2}[ -]\d{3}[ -]\d{2}[ -]\d{2})" + E,
         None, "phone", required=True, confidence=0.8, boosted=0.85),
    Rule("date_of_birth", "DOB",
         B + r"(?:\d{1,2}[./-]\d{1,2}[./-](?:19|20)\d{2}|(?:19|20)\d{2}-\d{2}-\d{2}"
         r"|\d{1,2}\.? (?:%s) (?:19|20)\d{2}|(?:%s) \d{1,2}, (?:19|20)\d{2})" % (_MONTHS, _MONTHS) + E,
         _date_ok, "dob", required=True, confidence=0.9, boosted=0.9),
    # A run of capitalised words (with "&", "i", "und", "and" between them)
    # followed by a company's legal form: the whole name is the organisation.
    Rule("company_legal_form", "ORG",
         r"(?<![\w&])(?:[%s0-9][\w.'&-]*)(?: (?:[%s0-9][\w.'&-]*|&|i|und|and)){0,5}"
         r" (?:[Ss]p\. ?z ?o\.o\.|[Ss]p\. ?[jkp]\.|[Ss]p\. ?z\.? ?o\.? ?o\.?|S\.A\.|S\.K\.A\.|[Ss]\.c\.|"
         r"GmbH(?: & Co\. KG)?|AG|KG|OHG|UG|e\.V\.|Ltd\.?|LLC|LLP|Inc\.?|PLC|Corp\.?|S\.A\.S\.|S\.r\.l\.|B\.V\.|N\.V\.)"
         r"(?![\w])" % (_UP, _UP), _company_ok, confidence=0.9, source="pattern"),
    Rule("pl_street", "ADDRESS",
         r"(?<![\w])(?:ul\.|al\.|pl\.|os\.|ulica|aleja) ?[%s0-9][\w-]*(?: [%s][\w-]*)* \d+[A-Za-z]?(?:/\d+[A-Za-z]?)?" % (_UP, _UP)
         + E, confidence=0.85),
    Rule("pl_postcode_city", "ADDRESS",
         r"(?<![\w-])\d{2}-\d{3} [%s][%s]+(?:[ -][%s][%s]+)?" % (_UP, _LO, _UP, _LO) + E, confidence=0.85),
    Rule("de_street", "ADDRESS",
         B + r"[%s][%s]+(?:-[%s][%s]+)*(?:straße|strasse|str\.|weg|gasse|platz|allee|ring|damm) \d+[a-z]?" % (_UP, _LO, _UP, _LO)
         + E, confidence=0.8),
    Rule("en_street", "ADDRESS",
         B + r"\d{1,5} (?:[A-Z][a-z]+ ){1,3}(?:Street|St\.|Road|Rd\.|Avenue|Ave\.|Lane|Ln\.|Drive|Dr\.|Boulevard|Blvd\.|"
         r"Court|Ct\.|Way|Place|Square|Terrace)(?![\w])", confidence=0.85),
]

_RANK = {"checksum": 3, "list": 3, "table": 3, "pattern": 2, "ner": 1}

# --------------------------------------------------------------------------
# Tables: a column whose header names a person makes every cell a person.
# --------------------------------------------------------------------------

_PERSON_HEADERS = {
    "name", "full name", "fullname", "first name", "firstname", "last name", "lastname", "surname",
    "given name", "family name", "middle name", "maiden name", "person", "contact", "contact person",
    "employee", "employee name", "customer name", "client name", "patient", "patient name", "owner name",
    "imie", "imię", "nazwisko", "imie nazwisko", "imię nazwisko", "imie i nazwisko", "imię i nazwisko",
    "nazwisko i imie", "nazwisko i imię", "nazwisko imie", "nazwisko imię", "osoba", "osoba kontaktowa",
    "pracownik", "klient imie nazwisko", "pacjent", "vorname", "nachname", "familienname",
    "vollständiger name", "ansprechpartner", "mitarbeiter", "mitarbeiterin", "patientin",
}
_PLACE_HEADERS = {"miasto", "miejscowosc", "miejscowość", "city", "town", "place", "location", "lokalizacja",
                  "ort", "stadt", "wohnort", "place of birth", "miejsce urodzenia", "geburtsort"}
_ADDRESS_HEADERS = {"adres", "address", "street", "street address", "address line 1", "address line 2",
                    "ulica", "adres zamieszkania", "adres korespondencyjny", "straße", "strasse", "anschrift",
                    "home address", "postal address"}
_HEADER_SEP = re.compile(r"[\s_.\-/]+")


def _column_type(cell):
    """PERSON, LOCATION or ADDRESS for a header cell naming such a column."""
    h = _HEADER_SEP.sub(" ", cell.strip().lower()).strip()
    if h in _PERSON_HEADERS:
        return "PERSON"
    if h in _PLACE_HEADERS:
        return "LOCATION"
    if h in _ADDRESS_HEADERS:
        return "ADDRESS"
    return None


def sniff_delimiter(text):
    """The delimiter of a delimited table, from its first non-empty line."""
    for line in text.splitlines():
        if line.strip():
            counts = [(line.count(d), d) for d in ("\t", ";", ",", "|")]
            n, d = max(counts)
            return d if n else None
    return None


def _split_cells(text, start, end, delim):
    """(cell_start, cell_end) of each cell of one line, without padding or
    quotes. Quoted cells may contain the delimiter."""
    cells, i = [], start
    if delim == "|":
        line = text[start:end]
        if line.strip().startswith("|"):
            i = start + line.index("|") + 1
        stop = end
        stripped = line.rstrip()
        if stripped.endswith("|"):
            stop = start + len(stripped) - 1
        end = stop
    while i <= end:
        if i < end and text[i] == '"' and delim != "|":
            j = i + 1
            while j < end:
                if text[j] == '"' and j + 1 < end and text[j + 1] == '"':
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            cells.append((i + 1, j))
            k = text.find(delim, j, end)
            i = (k if k >= 0 else end) + 1
            continue
        k = text.find(delim, i, end)
        k = end if k < 0 else k
        a, b = i, k
        while a < b and text[a] in " \t" and delim != "\t" or a < b and text[a] == " ":
            a += 1
        while b > a and text[b - 1] in " \t\r" and delim != "\t" or b > a and text[b - 1] in " \r":
            b -= 1
        cells.append((a, b))
        i = k + 1
    return cells


def _table_blocks(text, delim):
    """Lines of each table: consecutive non-empty lines; for Markdown tables
    ("|"), consecutive lines that start with "|"."""
    block, pos = [], 0
    for line in text.splitlines(True):
        start, pos = pos, pos + len(line)
        end = start + len(line.rstrip("\r\n"))
        content = text[start:end]
        if delim == "|":
            inside = content.lstrip().startswith("|")
        else:
            inside = bool(content.strip())
        if inside:
            block.append((start, end))
        elif block:
            yield block
            block = []
    if block:
        yield block


def table_headers(text, delim):
    """(start, end) of the header line of each table."""
    return [block[0] for block in _table_blocks(text, delim)]


def table_findings(text, delim):
    out = []
    for block in _table_blocks(text, delim):
        header = _split_cells(text, block[0][0], block[0][1], delim)
        cols = {}
        for n, (a, b) in enumerate(header):
            t = _column_type(text[a:b])
            if t:
                cols[n] = t
        if not cols:
            continue
        for start, end in block[1:]:
            if delim == "|" and re.fullmatch(r"[\s|:\-]+", text[start:end]):
                continue  # Markdown separator row
            cells = _split_cells(text, start, end, delim)
            for n, t in cols.items():
                if n < len(cells):
                    a, b = cells[n]
                    if b > a and re.search(r"[^\W\d_]", text[a:b]):
                        out.append(Finding(a, b, t, "table:%s-column" % t.lower(), 0.97, "table"))
    return out


# --------------------------------------------------------------------------
# Corrections to a model's findings
# --------------------------------------------------------------------------

_NAME_WORD = r"[%s][%s]+(?:['’-][%s]?[%s]+)?" % (_UP, _LO, _UP, _LO)
_TITLES = {"pan", "pani", "panem", "panią", "panu", "pana", "panie", "państwo", "herr", "herrn", "frau",
           "mr", "mrs", "ms", "miss", "mx", "dr", "prof", "mgr", "inż", "sir", "dame", "mr.", "mrs.", "ms.",
           "dr.", "prof.", "mgr.", "inż."}
_LEFT_NAME = re.compile(r"(?:^|(?<=[\s(\[\"'„]))(%s) $" % _NAME_WORD)
_RIGHT_NAME = re.compile(r"^ (%s)(?![\w])" % _NAME_WORD)
_SENTENCE_START = re.compile(r"(?:^|[.!?:;]\s+|\n[ \t]*|\|[ \t]*)$")


def _widen_person(text, f):
    """Grow a model's PERSON match over adjacent capitalised words on the
    same line, so a first name is not left next to the token; titles stay
    outside."""
    start, end = f.start, f.end
    for _ in range(2):
        m = _LEFT_NAME.search(text[max(0, start - 40):start])
        if not m or m.group(1).lower() in _TITLES:
            break
        start -= len(m.group(0))
    for _ in range(2):
        m = _RIGHT_NAME.match(text[end:end + 41])
        if not m or m.group(1).lower() in _TITLES:
            break
        end += len(m.group(0))
    return Finding(start, end, f.type, f.kind, f.confidence, f.source)

_TYPE_RE = re.compile(r"^[A-Z]+$")


def parse_list_file(content):
    """Return ([(TYPE, term)], [error lines]). Lines: 'term' or 'TYPE: term'."""
    entries, errors = [], []
    for n, line in enumerate(content.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            t, term = line.split(":", 1)
            t, term = t.strip(), term.strip()
            if not _TYPE_RE.match(t) or not term:
                errors.append("line %d: expected 'TYPE: term' with TYPE in A-Z only" % n)
                continue
            entries.append((t, term))
        else:
            entries.append(("CUSTOM", line))
    return entries, errors


class Detector(object):
    def __init__(self, lists=(), ner=None, rules=None):
        self.rules = RULES if rules is None else rules
        self.lists = []
        for t, term in lists:
            if not _TYPE_RE.match(t):
                raise ValueError("list type %r must be A-Z only" % t)
            pat = r"(?<![\w])%s(?![\w])" % r"\s+".join(re.escape(w) for w in term.split())
            self.lists.append((t, term, re.compile(pat, re.I)))
        self.ner = ner

    def fingerprint(self):
        h = hashlib.sha256()
        h.update(("detector:%s\n" % VERSION).encode())
        for t, term, _ in sorted(self.lists, key=lambda x: (x[0], x[1])):
            h.update(("list:%s:%s\n" % (t, term)).encode())
        if self.ner is not None:
            h.update(("ner:%s\n" % getattr(self.ner, "fingerprint", getattr(self.ner, "__name__", "ner"))).encode())
        return h.hexdigest()

    def _context(self, rule, text, start):
        if rule.context is None:
            return False
        window = text[max(0, start - 40):start]
        return bool(_CTX_RE[rule.context].search(window))

    def _validate(self, rule, s):
        return rule.validator is None or rule.validator(s)

    def _candidates(self, text, table=None):
        for rule in self.rules:
            for m in rule.regex.finditer(text):
                start, end = m.start(), m.end()
                s = m.group(0)
                ok = self._validate(rule, s)
                if not ok and rule.trim:
                    # Shorter prefixes ending before a separator, longest first.
                    cuts = [i for i, c in enumerate(s) if c in " .-" and i > 0]
                    for i in reversed(cuts):
                        sub = s[:i]
                        if self._validate(rule, sub):
                            end, s, ok = start + i, sub, True
                            break
                if not ok:
                    continue
                ctx = self._context(rule, text, start)
                if rule.required and not ctx:
                    continue
                conf = rule.boosted if ctx else rule.confidence
                yield Finding(start, end, rule.type, rule.kind, conf, rule.source)
        for t, term, rx in self.lists:
            for m in rx.finditer(text):
                yield Finding(m.start(), m.end(), t, "list", 1.0, "list")
        tables = table if table is not None else ("|" if "|" in text else None)
        headers = table_headers(text, tables) if tables else []
        if self.ner is not None:
            for f in self._model_findings(text, headers):
                if f.type == "PERSON":
                    f = _widen_person(text, f)
                elif f.type == "LOCATION" and self._only_capitalised(text, f):
                    continue
                yield f
        if tables:
            for f in table_findings(text, tables):
                yield f

    def _model_findings(self, text, headers):
        """The model's findings, cut at line breaks (a name or place does not
        span lines; a model joining a table's last column to the next row
        would otherwise lose both), without anything in a table header."""
        for f in self.ner(text):
            start = f.start
            for piece in text[f.start:f.end].split("\n"):
                a = start + len(piece) - len(piece.lstrip())
                b = start + len(piece.rstrip())
                start += len(piece) + 1
                if b <= a or any(a < he and hs < b for hs, he in headers):
                    continue
                yield Finding(a, b, f.type, f.kind, f.confidence, f.source)

    def _only_capitalised(self, text, f):
        """A one-word place at the start of a sentence, line or table cell
        that the model no longer finds when the word is written in lower
        case: the capital letter, not the word, made it a place."""
        word = text[f.start:f.end]
        if " " in word or not word[:1].isupper() or not _SENTENCE_START.search(text[max(0, f.start - 20):f.start]):
            return False
        stop = len(text)
        for ch in ".!?\n|":
            k = text.find(ch, f.end)
            if 0 <= k < stop:
                stop = k
        lowered = word[0].lower() + text[f.start + 1:stop]
        return not any(g.type == "LOCATION" and g.start < len(word) for g in self.ner(lowered))

    def detect(self, text, table=None):
        """Findings in TEXT. TABLE is the delimiter when the whole text is a
        delimited table (CSV, TSV); Markdown tables are found in any text."""
        cands = sorted(self._candidates(text, table),
                       key=lambda f: (-_RANK.get(f.source, 0), -f.confidence, -(f.end - f.start), f.start))
        taken = []
        for f in cands:
            if f.end <= f.start:
                continue
            if any(f.start < g.end and g.start < f.end for g in taken):
                continue
            taken.append(f)
        taken.sort(key=lambda f: f.start)
        for f in taken:
            f.text = text[f.start:f.end]
        return taken
