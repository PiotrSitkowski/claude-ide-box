"""Reversible pseudonymisation with [TYPE_N] tokens.

The token map is the only link between tokens and real values. It is kept
by the caller somewhere the AI agent's container cannot see.

Restoration is strict: only exact tokens present in the map are replaced.
Unknown tokens and anything that looks like an altered token are reported,
never guessed.
"""

import json
import os
import re
import stat
from collections import Counter

from .detect import sniff_delimiter

STRICT = re.compile(r"\[([A-Z]+)_([0-9]+)\]")
MAP_FORMAT = "pii-airgap-map/1"
LINK_TYPES = ("ner",)  # sources that do not block on file names


class TokenCollision(Exception):
    """The input already contains token-shaped text, so restoring could not
    tell an original from a token."""


class Unrewritable(Exception):
    """Content that may hold PII but cannot be pseudonymised in place."""


class Problem(object):
    __slots__ = ("kind", "text", "line", "path")

    def __init__(self, kind, text, line, path=None):
        self.kind, self.text, self.line, self.path = kind, text, line, path

    def __repr__(self):
        return "Problem(%s, %r, line %d, %s)" % (self.kind, self.text, self.line, self.path)


class TokenMap(object):
    def __init__(self):
        self.tokens = {}   # token -> value
        self._by_value = {}  # (type, value) -> token
        self._next = Counter()

    def _add(self, token, value):
        m = STRICT.fullmatch(token)
        if not m:
            raise ValueError("bad token %r in map" % token)
        t, n = m.group(1), int(m.group(2))
        self.tokens[token] = value
        self._by_value[(t, value)] = token
        self._next[t] = max(self._next[t], n)

    def token_for(self, type, value):
        tok = self._by_value.get((type, value))
        if tok is None:
            self._next[type] += 1
            tok = "[%s_%d]" % (type, self._next[type])
            self.tokens[tok] = value
            self._by_value[(type, value)] = tok
        return tok

    def types(self):
        return sorted(set(STRICT.fullmatch(t).group(1) for t in self.tokens))

    @classmethod
    def load(cls, path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if data.get("format") != MAP_FORMAT:
            raise ValueError("%s is not a %s file" % (path, MAP_FORMAT))
        m = cls()
        for tok, value in data["tokens"].items():
            m._add(tok, value)
        return m

    @classmethod
    def load_or_new(cls, path):
        return cls.load(path) if os.path.exists(path) else cls()

    def save(self, path):
        d = os.path.dirname(os.path.abspath(path))
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
        tmp = "%s.tmp.%d" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"format": MAP_FORMAT, "tokens": self.tokens}, f, ensure_ascii=False, indent=1, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def anonymise_text(text, detector, tmap, where="input", table=None):
    m = STRICT.search(text)
    if m:
        raise TokenCollision("%s line %d already contains token-shaped text %s"
                             % (where, _line_of(text, m.start()), m.group(0)))
    pieces, last = [], 0
    for f in sorted(detector.detect(text, table=table), key=lambda f: f.start):
        pieces.append(text[last:f.start])
        pieces.append(tmap.token_for(f.type, f.text))
        last = f.end
    pieces.append(text[last:])
    return "".join(pieces)


def _near_miss_re(types):
    if not types:
        return None
    alt = "|".join(re.escape(t) for t in types)
    return re.compile(r"(?<![A-Za-z0-9])(?:\\?\[\s*)?(?:%s)[ _-]?\d+(?:\s*\\?\])?(?![A-Za-z0-9])" % alt, re.I)


def _near_misses(text, rx):
    """Near-miss strings with positions, outside strict token spans."""
    if rx is None:
        return []
    strict_spans = [(m.start(), m.end()) for m in STRICT.finditer(text)]
    out = []
    for m in rx.finditer(text):
        if any(m.start() < e and s < m.end() for s, e in strict_spans):
            continue
        out.append((m.group(0), m.start()))
    return out


def restore_text(text, tmap, baseline=None):
    problems = []
    pieces, last = [], 0
    for m in STRICT.finditer(text):
        tok = m.group(0)
        value = tmap.tokens.get(tok)
        if value is None:
            canonical = "[%s_%d]" % (m.group(1), int(m.group(2)))
            kind = "altered" if canonical in tmap.tokens else "unknown"
            problems.append(Problem(kind, tok, _line_of(text, m.start())))
            continue
        pieces.append(text[last:m.start()])
        pieces.append(value)
        last = m.end()
    pieces.append(text[last:])
    rx = _near_miss_re(tmap.types())
    allowed = Counter(s for s, _ in _near_misses(baseline or "", rx))
    seen = Counter()
    for s, pos in _near_misses(text, rx):
        seen[s] += 1
        if seen[s] > allowed[s]:
            problems.append(Problem("altered", s, _line_of(text, pos)))
    problems.sort(key=lambda p: p.line)
    return "".join(pieces), problems


# --------------------------------------------------------------------------
# Trees
# --------------------------------------------------------------------------

class Report(object):
    def __init__(self):
        self.changed, self.problems, self.skipped, self.written = [], [], [], False


def _walk(root):
    """(rel, abs) of regular files below root; never follows symlinks.
    .git entries are returned separately."""
    files, gits, links = [], [], []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir + "/"
        for d in list(dirnames):
            p = os.path.join(dirpath, d)
            if d == ".git":
                gits.append(rel_dir + d)
                dirnames.remove(d)
            elif os.path.islink(p):
                links.append(rel_dir + d)
                dirnames.remove(d)
        dirnames.sort()
        for n in sorted(filenames):
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            if n == ".git":
                gits.append(rel_dir + n)
            elif stat.S_ISLNK(st.st_mode):
                links.append(rel_dir + n)
            elif stat.S_ISREG(st.st_mode):
                files.append((rel_dir + n, p))
    return files, gits, links


def _read_text(path):
    """(text, None) for UTF-8 text, (None, reason) otherwise."""
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data:
        return None, "binary"
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        return None, "not-utf8"


def _write_atomic(path, text):
    st = os.lstat(path)
    tmp = os.path.join(os.path.dirname(path), ".pii-airgap.%d.tmp" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(text.encode("utf-8"))
    os.chmod(tmp, stat.S_IMODE(st.st_mode))
    os.replace(tmp, path)


def _rmtree(path):
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
        return
    for dirpath, dirnames, filenames in os.walk(path, topdown=False):
        for n in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            os.unlink(os.path.join(dirpath, n))
        for d in dirnames:
            p = os.path.join(dirpath, d)
            if not os.path.islink(p):
                os.rmdir(p)
    os.rmdir(path)


def anonymise_tree(root, map_path, detector, git="refuse", documents_with_pii=()):
    """Replace PII in every UTF-8 text file below root by tokens, in place.
    Everything is planned first; on any refusal nothing is written."""
    tmap = TokenMap.load_or_new(map_path)
    files, gits, links = _walk(root)
    rep = Report()
    blockers = []
    if gits and git != "strip":
        blockers.append("git metadata (history holds the original values and cannot be rewritten): "
                        + ", ".join(gits))
    for d in documents_with_pii:
        blockers.append("%s: document with PII that cannot be rewritten in place (mask it)" % d)
    collisions = []
    planned = []
    for rel, path in files:
        for f in detector.detect(rel):
            if f.source not in LINK_TYPES:
                blockers.append("%s: the file name contains %s" % (rel, f.type))
        text, why = _read_text(path)
        if text is None:
            if why == "not-utf8":
                with open(path, "rb") as fh:
                    alt = fh.read().decode("cp1250", errors="replace")
                if detector.detect(alt):
                    blockers.append("%s: not UTF-8 and looks like it holds PII (convert it or mask it)" % rel)
            rep.skipped.append((rel, why))
            continue
        table = None
        if rel.lower().endswith((".csv", ".tsv")):
            table = "\t" if rel.lower().endswith(".tsv") else sniff_delimiter(text)
        try:
            new = anonymise_text(text, detector, tmap, where=rel, table=table)
        except TokenCollision as e:
            collisions.append(str(e))
            continue
        if new != text:
            planned.append((rel, path, new))
    if collisions:
        raise TokenCollision("token-shaped text already present, restoring would be ambiguous:\n  "
                             + "\n  ".join(collisions))
    if blockers:
        raise Unrewritable("refusing to pseudonymise, nothing was changed:\n  " + "\n  ".join(blockers))
    for g in gits:
        _rmtree(os.path.join(root, g))
    for rel, path, new in planned:
        _write_atomic(path, new)
        rep.changed.append(rel)
    tmap.save(map_path)
    rep.written = True
    rep.skipped.extend((l, "symlink") for l in links)
    return rep


def restore_tree(root, map_path, base=None, keep_unresolved=False):
    tmap = TokenMap.load(map_path)
    files, _, links = _walk(root)
    rep = Report()
    planned = []
    for rel, path in files:
        text, why = _read_text(path)
        if text is None:
            rep.skipped.append((rel, why))
            continue
        baseline = None
        if base is not None:
            bp = os.path.join(base, rel)
            if os.path.isfile(bp) and not os.path.islink(bp):
                baseline, _ = _read_text(bp)
        new, problems = restore_text(text, tmap, baseline)
        for p in problems:
            p.path = rel
        rep.problems.extend(problems)
        if new != text:
            planned.append((rel, path, new))
    rep.skipped.extend((l, "symlink") for l in links)
    if rep.problems and not keep_unresolved:
        return rep
    for rel, path, new in planned:
        _write_atomic(path, new)
        rep.changed.append(rel)
    rep.written = True
    return rep
