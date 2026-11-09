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

from .code import syntax_for
from .detect import sniff_delimiter

STRICT = re.compile(r"\[([A-Z]+)_([0-9]+)\]")
STRICT_BYTES = re.compile(rb"\[[A-Z]+_[0-9]+\]")
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


def anonymise_text(text, detector, tmap, where="input", table=None, code=None):
    m = STRICT.search(text)
    if m:
        raise TokenCollision("%s line %d already contains token-shaped text %s"
                             % (where, _line_of(text, m.start()), m.group(0)))
    pieces, last = [], 0
    found = detector.detect(text, table=table, code=code) if code else detector.detect(text, table=table)
    for f in sorted(found, key=lambda f: f.start):
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
        self.left_out = []  # (rel, reason): removed from the copy, never pseudonymised


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


UNREWRITABLE = "document with personal data that cannot be rewritten in place"


def anonymise_tree(root, map_path, detector, git="refuse", documents_with_pii=(), leave_out=False):
    """Replace PII in every UTF-8 text file below root by tokens, in place.
    Everything is planned first; on any refusal nothing is written.

    documents_with_pii: paths (or (path, reason) pairs) the caller's scan
    found personal data in but that are not text. They block the run, unless
    leave_out is set: then they, and text files that are not UTF-8 but look
    like they hold personal data, are deleted from the tree (it must be a
    copy) and listed in the report's left_out."""
    tmap = TokenMap.load_or_new(map_path)
    files, gits, links = _walk(root)
    rep = Report()
    blockers = []
    left = {}
    if gits and git != "strip":
        blockers.append("git metadata (history holds the original values and cannot be rewritten): "
                        + ", ".join(gits))
    for d in documents_with_pii:
        rel, why = (d, UNREWRITABLE) if isinstance(d, str) else d
        if leave_out:
            left[rel] = why
        else:
            blockers.append("%s: %s (mask it)" % (rel, why))
    collisions = []
    planned = []
    for rel, path in files:
        if rel in left:
            continue
        for f in detector.detect(rel):
            if f.source not in LINK_TYPES:
                blockers.append("%s: the file name contains %s" % (rel, f.type))
        text, why = _read_text(path)
        if text is None:
            if why == "not-utf8":
                with open(path, "rb") as fh:
                    alt = fh.read().decode("cp1250", errors="replace")
                if detector.detect(alt):
                    if leave_out:
                        left[rel] = "not UTF-8 text and looks like it holds personal data"
                        continue
                    blockers.append("%s: not UTF-8 and looks like it holds PII (convert it or mask it)" % rel)
            rep.skipped.append((rel, why))
            continue
        table = None
        if rel.lower().endswith((".csv", ".tsv")):
            table = "\t" if rel.lower().endswith(".tsv") else sniff_delimiter(text)
        try:
            code = None if table else syntax_for(os.path.splitext(rel.lower())[1])
            new = anonymise_text(text, detector, tmap, where=rel, table=table, code=code)
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
    present = dict(files)
    for rel in sorted(left):
        # Only regular files found by the walk are removed; a path that is
        # not one (gone, or inside .git, already stripped) has nothing left.
        if rel in present:
            os.unlink(present[rel])
            rep.left_out.append((rel, left[rel]))
    for rel, path, new in planned:
        _write_atomic(path, new)
        rep.changed.append(rel)
    tmap.save(map_path)
    rep.written = True
    rep.skipped.extend((l, "symlink") for l in links)
    return rep


def _check_dir_chain(top, rel_dir):
    """Every directory from top down to top/rel_dir that exists must be a real
    directory, not a symlink: a write below it would land elsewhere."""
    cur = top
    for part in [p for p in rel_dir.split("/") if p]:
        cur = os.path.join(cur, part)
        try:
            st = os.lstat(cur)
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("%s is a symlink or not a directory; refusing to write below it" % cur)


def _write_new(path, data, mode):
    """Create path (it must not exist) without following symlinks."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(path, stat.S_IMODE(mode))


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def restore_tree(root, map_path, base=None, keep_unresolved=False, out=None, into_base=False):
    """Put real values back for exact, known tokens.

    Where the result goes:
      out=DIR         a full restored tree in DIR, which must be empty; root keeps its tokens
      into_base=True  changed and new files written into base (the original); root keeps
                      its tokens; files missing from root are left in base and reported
      neither         root itself, in place (a restored copy holds real values and must
                      never be opened with an agent again)
    Nothing is written when a token problem is found, unless keep_unresolved."""
    if out is not None and into_base:
        raise ValueError("choose one destination: out or into_base")
    if into_base and base is None:
        raise ValueError("into_base needs base")
    if out is not None:
        if not os.path.isdir(out) or os.path.islink(out):
            raise ValueError("%s is not a directory" % out)
        if os.listdir(out):
            raise ValueError("%s is not empty" % out)
    tmap = TokenMap.load(map_path)
    files, _, links = _walk(root)
    rep = Report()
    rep.kept = []
    planned = []  # (rel, src path, new bytes or None to copy as is)
    for rel, path in files:
        text, why = _read_text(path)
        if text is None:
            rep.skipped.append((rel, why))
            planned.append((rel, path, None))
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
        planned.append((rel, path, new.encode("utf-8") if new != text else None))
    rep.skipped.extend((l, "symlink") for l in links)
    if rep.problems and not keep_unresolved:
        return rep
    if out is None and not into_base:
        for rel, path, data in planned:
            if data is not None:
                _write_atomic(path, data.decode("utf-8"))
                rep.changed.append(rel)
        rep.written = True
        return rep
    if out is not None:
        for rel, path, data in planned:
            d = os.path.dirname(rel)
            if d:
                _check_dir_chain(out, d)
                os.makedirs(os.path.join(out, d), exist_ok=True)
            _write_new(os.path.join(out, rel), _read_bytes(path) if data is None else data,
                       os.lstat(path).st_mode)
            if data is not None:
                rep.changed.append(rel)
        rep.written = True
        return rep
    # into_base: plan and check every write first, then write.
    writes = []
    for rel, path, data in planned:
        content = _read_bytes(path) if data is None else data
        bp = os.path.join(base, rel)
        _check_dir_chain(base, os.path.dirname(rel))
        if os.path.lexists(bp):
            st = os.lstat(bp)
            if not stat.S_ISREG(st.st_mode):
                raise ValueError("%s in the original is a symlink or not a file; refusing to replace it" % rel)
            if _read_bytes(bp) == content:
                continue
        writes.append((rel, bp, content, os.lstat(path).st_mode))
    in_root = set(rel for rel, _, _ in planned)
    base_files, _, _ = _walk(base)
    rep.kept = sorted(rel for rel, _ in base_files if rel not in in_root)
    for rel, bp, content, mode in writes:
        d = os.path.dirname(bp)
        os.makedirs(d, exist_ok=True)
        if os.path.lexists(bp):
            tmp = os.path.join(d, ".pii-airgap.%d.tmp" % os.getpid())
            _write_new(tmp, content, os.lstat(bp).st_mode)
            os.replace(tmp, bp)
        else:
            _write_new(bp, content, mode)
        rep.changed.append(rel)
    rep.written = True
    return rep


def _value_patterns(tmap):
    """One bytes regex matching any value of the map as a whole word, in UTF-8
    and, where it differs, in cp1250 (legacy Polish text files)."""
    alts = set()
    for value in tmap.tokens.values():
        if not value.strip():
            continue
        for enc in ("utf-8", "cp1250"):
            try:
                alts.add(value.encode(enc))
            except UnicodeEncodeError:
                pass
    if not alts:
        return None
    body = b"|".join(re.escape(a) for a in sorted(alts, key=len, reverse=True))
    # Not part of a longer word or number: no ASCII letter or digit and no
    # non-ASCII byte right before or after.
    return re.compile(b"(?<![A-Za-z0-9\x80-\xff])(?:" + body + b")(?![A-Za-z0-9\x80-\xff])")


def verify_tree(root, map_path):
    """[(rel, count)] of regular files below root that contain values of the
    map in clear text. Symlinks are not followed; .git is searched too."""
    tmap = TokenMap.load(map_path)
    rx = _value_patterns(tmap)
    if rx is None:
        return []
    found = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not os.path.islink(os.path.join(dirpath, d)))
        for n in sorted(filenames):
            p = os.path.join(dirpath, n)
            if not stat.S_ISREG(os.lstat(p).st_mode):
                continue
            # Tokens are not values: a value that equals a type name ("NIP"
            # taken for an organisation) must not match inside "[NIP_1]".
            hits = len(rx.findall(STRICT_BYTES.sub(b" ", _read_bytes(p))))
            if hits:
                found.append((os.path.relpath(p, root).replace(os.sep, "/"), hits))
    return sorted(found)
