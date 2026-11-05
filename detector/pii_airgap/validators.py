"""Checksum and format validators for identifiers.

Each function takes the matched text (separators allowed) and returns True
only when the format and, where one exists, the check digit are valid.
"""

import datetime
import re

_SEP = re.compile(r"[\s.\-/]")

# Total IBAN length per country (ISO 13616 registry), for the countries most
# likely to appear; other countries fall back to the 15-34 range.
IBAN_LENGTHS = {
    "AD": 24, "AT": 20, "BE": 16, "BG": 22, "CH": 21, "CY": 28, "CZ": 24, "DE": 22,
    "DK": 18, "EE": 20, "ES": 24, "FI": 18, "FR": 27, "GB": 22, "GR": 27, "HR": 21,
    "HU": 28, "IE": 22, "IS": 26, "IT": 27, "LI": 21, "LT": 20, "LU": 20, "LV": 21,
    "MC": 27, "MT": 31, "NL": 18, "NO": 15, "PL": 28, "PT": 25, "RO": 24, "SE": 24,
    "SI": 19, "SK": 24, "SM": 27, "UA": 29,
}


def _compact(s):
    return _SEP.sub("", s)


def _digits(s, n=None):
    s = _compact(s)
    if not s.isdigit() or (n is not None and len(s) != n):
        return None
    return [int(c) for c in s]


def _letter_value(c):
    return ord(c) - 55 if c.isalpha() else int(c)


def _valid_date(y, m, d):
    try:
        datetime.date(y, m, d)
        return True
    except ValueError:
        return False


def iban_valid(s):
    s = _compact(s).upper()
    if not re.fullmatch(r"[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}", s):
        return False
    want = IBAN_LENGTHS.get(s[:2])
    if want is not None and len(s) != want:
        return False
    num = "".join(str(_letter_value(c)) for c in s[4:] + s[:4])
    return int(num) % 97 == 1


def luhn_valid(digits):
    total = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


_CARD_PREFIX = re.compile(r"^(4|5[1-5]|2(2[2-9]|[3-6][0-9]|7[01]|720)|3[47]|3(0[0-5]|[68])|6011|65|64[4-9]|35|62)")


def card_valid(s):
    d = _digits(s)
    if d is None or not 13 <= len(d) <= 19 or len(set(d)) == 1:
        return False
    return bool(_CARD_PREFIX.match("".join(map(str, d)))) and luhn_valid(d)


def pesel_valid(s):
    d = _digits(s, 11)
    if d is None or len(set(d)) == 1:
        return False
    w = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
    if (10 - sum(a * b for a, b in zip(d, w)) % 10) % 10 != d[10]:
        return False
    yy, mm, dd = d[0] * 10 + d[1], d[2] * 10 + d[3], d[4] * 10 + d[5]
    century = {0: 1900, 2: 2000, 4: 2100, 6: 2200, 8: 1800}[(mm // 20) * 2]
    return _valid_date(century + yy, mm % 20, dd)


def nip_valid(s):
    s = _compact(s).upper()
    if s.startswith("PL"):
        s = s[2:]
    d = _digits(s, 10)
    if d is None or len(set(d)) == 1:
        return False
    w = [6, 5, 7, 2, 3, 4, 5, 6, 7]
    c = sum(a * b for a, b in zip(d, w)) % 11
    return c != 10 and c == d[9]


def regon_valid(s):
    d = _digits(s)
    if d is None or len(set(d)) == 1:
        return False
    if len(d) == 9:
        w = [8, 9, 2, 3, 4, 5, 6, 7]
    elif len(d) == 14:
        if not regon_valid("".join(map(str, d[:9]))):
            return False
        w = [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8]
    else:
        return False
    c = sum(a * b for a, b in zip(d, w)) % 11 % 10
    return c == d[-1]


def pl_idcard_valid(s):
    s = _compact(s).upper()
    if not re.fullmatch(r"[A-Z]{3}[0-9]{6}", s):
        return False
    v = [_letter_value(c) for c in s]
    w = [7, 3, 1, 0, 7, 3, 1, 7, 3]
    return sum(a * b for a, b in zip(v, w)) % 10 == v[3]


def pl_passport_valid(s):
    s = _compact(s).upper()
    if not re.fullmatch(r"[A-Z]{2}[0-9]{7}", s):
        return False
    v = [_letter_value(c) for c in s]
    w = [7, 3, 0, 1, 7, 3, 1, 7, 3]
    return sum(a * b for a, b in zip(v, w)) % 10 == v[2]


def us_ssn_valid(s):
    m = re.fullmatch(r"(\d{3})[ -](\d{2})[ -](\d{4})", s.strip())
    if not m:
        return False
    area, group, serial = m.groups()
    return not (area in ("000", "666") or area[0] == "9" or group == "00" or serial == "0000")


def de_taxid_valid(s):
    """Steuerliche Identifikationsnummer: ISO 7064 MOD 11,10."""
    d = _digits(s, 11)
    if d is None or d[0] == 0:
        return False
    product = 10
    for x in d[:10]:
        total = (x + product) % 10 or 10
        product = (total * 2) % 11
    check = (11 - product) % 10
    return check == d[10]


def es_dni_valid(s):
    s = _compact(s).upper()
    m = re.fullmatch(r"([XYZ]?)(\d{7,8})([A-Z])", s)
    if not m:
        return False
    prefix, num, letter = m.groups()
    if prefix:
        if len(num) != 7:
            return False
        num = str("XYZ".index(prefix)) + num
    elif len(num) != 8:
        return False
    return "TRWAGMYFPDXBNJZSQVHLCKE"[int(num) % 23] == letter


_CF_ODD = dict(zip("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                   [1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 1, 0, 5, 7, 9, 13, 15, 17, 19, 21,
                    2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25, 24, 23]))


def it_cf_valid(s):
    s = _compact(s).upper()
    if not re.fullmatch(r"[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z]", s):
        return False
    total = 0
    for i, c in enumerate(s[:15]):
        if i % 2 == 0:
            total += _CF_ODD[c]
        else:
            total += int(c) if c.isdigit() else ord(c) - 65
    return chr(total % 26 + 65) == s[15]


def fr_nir_valid(s):
    s = _compact(s).upper()
    if not re.fullmatch(r"[12]\d{4}(\d{2}|2A|2B)\d{8}", s):
        return False
    body = s[:13].replace("2A", "19").replace("2B", "18")
    return 97 - int(body) % 97 == int(s[13:])


def nl_bsn_valid(s):
    d = _digits(s, 9)
    if d is None or len(set(d)) == 1:
        return False
    total = sum(x * w for x, w in zip(d[:8], range(9, 1, -1))) - d[8]
    return total % 11 == 0


def se_pnr_valid(s):
    m = re.fullmatch(r"(\d{2})?(\d{2})(\d{2})(\d{2})[-+]?(\d{4})", s.strip())
    if not m:
        return False
    _, yy, mm, dd, tail = m.groups()
    day = int(dd)
    if day > 60:  # samordningsnummer
        day -= 60
    if not _valid_date(2000, int(mm), day):
        return False
    return luhn_valid([int(c) for c in yy + mm + dd + tail])


def fi_hetu_valid(s):
    m = re.fullmatch(r"(\d{2})(\d{2})(\d{2})[-+A-FU-Y](\d{3})([0-9A-Y])", s.strip().upper())
    if not m:
        return False
    dd, mm, yy, ind, check = m.groups()
    if not _valid_date(2000, int(mm), int(dd)):
        return False
    return "0123456789ABCDEFHJKLMNPRSTUVWXY"[int(dd + mm + yy + ind) % 31] == check


def be_nrn_valid(s):
    d = _digits(s, 11)
    if d is None:
        return False
    body = int("".join(map(str, d[:9])))
    check = d[9] * 10 + d[10]
    return check in (97 - body % 97, 97 - (2000000000 + body) % 97)
