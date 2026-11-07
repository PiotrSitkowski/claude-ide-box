"""Name dictionary layer: people found from registry given names and
surnames, next to the patterns, the user's lists and the NER model.

Rules (the per-language data comes from the database, built from
names/<lang>.json):

- a known given name next to a capitalised word before or after it is a
  person; confidence rises when that word is a known surname or has a
  typical surname ending;
- a given name that is also an ordinary word (Grace, May, Róża) needs a
  known surname next to it and is not taken at the start of a sentence;
- a surname alone counts only after a title (pani, Mr, dr) or when the same
  surname was already found with a given name in the text;
- in source code only string literals and comments are searched, never
  identifiers.
"""

import json
import os
import re
import sqlite3
from functools import lru_cache

from .detect import Finding, _SENTENCE_START

_TOKEN = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*")
_GAP = re.compile(r"^[ \t]{1,2}$")


def code_spans(text):
    """(start, end) of string literals and comments in source code, for the
    common syntaxes: "..." '...' `...` and triple quotes; # // -- comments to
    the end of the line; /* */ and <!-- --> blocks."""
    spans = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if c == "#" or two == "//" or (two == "--" and (i == 0 or text[i - 1] in " \t\n")):
            j = text.find("\n", i)
            j = n if j < 0 else j
            spans.append((i, j))
            i = j
        elif two == "/*" or text.startswith("<!--", i):
            close = "*/" if two == "/*" else "-->"
            j = text.find(close, i + 2)
            j = n if j < 0 else j + len(close)
            spans.append((i, j))
            i = j
        elif text.startswith('"""', i) or text.startswith("'''", i):
            q = text[i:i + 3]
            j = text.find(q, i + 3)
            j = n if j < 0 else j + 3
            spans.append((i, j))
            i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and text[j] != c and (c == "`" or text[j] != "\n"):
                j += 2 if text[j] == "\\" else 1
            spans.append((i, min(j + 1, n)))
            i = j + 1
        else:
            i += 1
    return spans


class NamesLayer(object):
    def __init__(self, path):
        if not os.path.isfile(path):
            raise OSError("%s does not exist" % path)
        self.path = path
        self.db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, check_same_thread=False)
        meta = dict(self.db.execute("SELECT key, value FROM meta"))
        self.rules = json.loads(meta["rules"])
        self.fingerprint = "names:%s" % meta["fingerprint"]
        self.titles = set()
        self.stop = set()
        self.common_given = set()
        self.endings = []
        self.inflection = []
        for r in self.rules.values():
            self.titles.update(r["titles"])
            self.stop.update(r["stop_neighbours"])
            self.common_given.update(r.get("common_given", []))
            self.endings.extend(r.get("surname_endings", []))
            self.inflection.extend(tuple(x) for x in r.get("inflection", []))
        self.inflection.sort(key=lambda x: -len(x[0]))
        self._lookup = lru_cache(maxsize=65536)(self._lookup_uncached)

    # --- lookups --------------------------------------------------------

    def _candidates(self, key):
        """KEY and the lemmas the ending rules could make of it."""
        out = [key]
        for form_end, lemma_end in self.inflection:
            if key.endswith(form_end) and len(key) - len(form_end) >= 2:
                cand = key[:len(key) - len(form_end)] + lemma_end
                if cand not in out:
                    out.append(cand)
        return out

    def _lookup_uncached(self, key):
        """(given_lemma or None, surname_strength 0-2, ambiguous) for a casefolded word.
        A given name known only without a frequency (Wikidata, the dictionary)
        counts as ambiguous: it needs a known surname next to it."""
        given = None
        given_freq = False
        surname = 0
        for kind in ("given", "surname"):
            lemmas = [r[0] for r in self.db.execute("SELECT lemma FROM form WHERE form=? AND kind=?", (key, kind))]
            for cand in lemmas + self._candidates(key):
                row = self.db.execute("SELECT * FROM %s WHERE name=?" % kind, (cand,)).fetchone()
                if row:
                    if kind == "given":
                        given = given or cand
                        given_freq = any(v is not None and v > 0 for v in row[1:])
                    else:
                        surname = 2
                    break
        if not surname:
            for cand in self._candidates(key):
                if any(cand.endswith(e) and len(cand) > len(e) + 1 for e in self.endings):
                    surname = 1
                    break
        ambiguous = bool(self.db.execute("SELECT 1 FROM common WHERE word=?", (key,)).fetchone()) or \
            key in self.common_given or (given is not None and given in self.common_given) or \
            (given is not None and not given_freq)
        if key in self.stop:
            given = None
        return given, surname, ambiguous

    # --- detection ------------------------------------------------------

    def _tokens(self, text, code):
        allowed = code_spans(text) if code else [(0, len(text))]
        toks = []
        for a, b in allowed:
            for m in _TOKEN.finditer(text, a, b):
                w = m.group(0)
                # In code, upper-case words are constants and licence text.
                if code and w.isupper():
                    continue
                toks.append((m.start(), m.end(), w))
        return toks

    @staticmethod
    def _capital(word):
        return word[:1].isupper() and len(word) > 1

    def _adjacent(self, text, left, right):
        return _GAP.match(text[left[1]:right[0]]) is not None

    def _sentence_start(self, text, tok):
        return bool(_SENTENCE_START.search(text[max(0, tok[0] - 20):tok[0]]))

    def __call__(self, text, code=False):
        toks = self._tokens(text, code)
        info = [self._lookup(t[2].casefold()) if self._capital(t[2]) else (None, 0, False) for t in toks]
        taken = [False] * len(toks)
        out = []
        found_surnames = set()

        def usable(j):
            if j < 0 or j >= len(toks) or taken[j]:
                return False
            w = toks[j][2]
            return self._capital(w) and w.casefold() not in self.stop

        for i, t in enumerate(toks):
            given, _, ambiguous = info[i]
            if given is None or taken[i]:
                continue
            if ambiguous and self._sentence_start(text, t):
                continue
            best = None
            for j in (i + 1, i - 1):
                if not usable(j):
                    continue
                a, b = (i, j) if j > i else (j, i)
                if not self._adjacent(text, toks[a], toks[b]):
                    continue
                strength = info[j][1] if info[j][1] else (2 if info[j][0] and not info[j][2] else 0)
                if strength == 0 and (ambiguous or (j < i and self._sentence_start(text, toks[j]))):
                    continue
                if ambiguous and strength < 2:
                    continue
                if best is None or strength > best[1]:
                    best = (j, strength)
            if best is None:
                continue
            j, strength = best
            lo, hi = min(i, j), max(i, j)
            # A third part: Anna Maria Nowak, Jan Kowalski-Nowak are one token or two.
            k = hi + 1
            if usable(k) and self._adjacent(text, toks[hi], toks[k]) and (info[k][1] == 2 or info[k][0]):
                hi = k
            for x in range(lo, hi + 1):
                taken[x] = True
                if info[x][1] and x != i:
                    found_surnames.add(self._surname_lemma(toks[x][2]))
            conf = {2: 0.9, 1: 0.75}.get(strength, 0.6)
            out.append(Finding(toks[lo][0], toks[hi][1], "PERSON", "names:pair", conf, "names"))

        for i, t in enumerate(toks):
            if taken[i] or not self._capital(t[2]) or info[i][1] != 2:
                continue
            prev = toks[i - 1][2].casefold().rstrip(".") if i > 0 else ""
            titled = i > 0 and prev in self.titles and _GAP.match(text[toks[i - 1][1]:t[0]].lstrip(".")) is not None
            if titled or self._surname_lemma(t[2]) in found_surnames:
                taken[i] = True
                out.append(Finding(t[0], t[1], "PERSON", "names:surname", 0.8 if titled else 0.7, "names"))
        return out

    def _surname_lemma(self, word):
        key = word.casefold()
        row = self.db.execute("SELECT lemma FROM form WHERE form=? AND kind='surname'", (key,)).fetchone()
        if row:
            return row[0]
        for cand in self._candidates(key):
            if self.db.execute("SELECT 1 FROM surname WHERE name=?", (cand,)).fetchone():
                return cand
        return key


def load_names(path):
    """A NamesLayer for PATH, or None for an empty path or 'none'."""
    if not path or path == "none":
        return None
    return NamesLayer(path)
