"""Hybrid PII detection: checksum-validated identifiers, patterns with
context words, user lists and an optional NER backend.

Overlaps are resolved by source (checksum and user lists beat patterns,
patterns beat the model), then confidence, then length.
"""

import hashlib
import re

from . import validators as v

VERSION = "1"

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
                 confidence=0.9, boosted=0.99, trim=False, flags=0):
        self.kind, self.type = kind, type
        self.regex = re.compile(pattern, flags)
        self.validator, self.context, self.required = validator, context, required
        self.confidence, self.boosted, self.trim = confidence, boosted, trim
        self.source = "checksum" if validator is not None else "pattern"


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

_RANK = {"checksum": 3, "list": 3, "pattern": 2, "ner": 1}
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

    def _candidates(self, text):
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
        if self.ner is not None:
            for f in self.ner(text):
                yield f

    def detect(self, text):
        cands = sorted(self._candidates(text),
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
