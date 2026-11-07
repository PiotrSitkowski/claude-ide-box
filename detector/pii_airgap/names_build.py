"""Build the name dictionary (one SQLite file) from the sources listed in
names/sources.json and the per-language rules in names/<lang>.json.

    python3 -m pii_airgap.names_build --sources names/sources.json \\
        --cache /tmp/names-src --out /opt/pii-airgap/names.db [--download] [--forms dict|rules]

Standard library only. Every source with a checksum is verified before it is
read; a mismatch stops the build. Frequencies are stored per million people
of the source's population, so thresholds compare across registries.
"""

import argparse
import fnmatch
import gzip
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import urllib.parse
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

SCHEMA_VERSION = "1"

# People counted by each registry, to turn counts into "per million".
POPULATION = {"pl": 38.0e6, "en": 308.7e6}

_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


class SourceError(Exception):
    pass


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(source, cache_dir):
    """Download SOURCE into CACHE_DIR unless it is already there."""
    path = os.path.join(cache_dir, source["file"])
    if os.path.exists(path):
        return path
    os.makedirs(cache_dir, exist_ok=True)
    url = source["url"]
    if source.get("query"):
        url += "?" + urllib.parse.urlencode({"query": source["query"]})
        req = urllib.request.Request(url, headers={"Accept": "text/tab-separated-values"})
    else:
        req = urllib.request.Request(url)
    tmp = path + ".part"
    with urllib.request.urlopen(req, timeout=600) as r, open(tmp, "wb") as out:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            out.write(block)
    os.replace(tmp, path)
    return path


def _xlsx_rows(path):
    """Rows of the first sheet, values as strings or ints (shared and inline strings)."""
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        shared = []
        if "xl/sharedStrings.xml" in names:
            for _, el in ET.iterparse(z.open("xl/sharedStrings.xml")):
                if el.tag == _NS + "si":
                    shared.append("".join(t.text or "" for t in el.iter(_NS + "t")))
                    el.clear()
        sheet = sorted(n for n in names if n.startswith("xl/worksheets/sheet"))[0]
        for _, el in ET.iterparse(z.open(sheet)):
            if el.tag != _NS + "row":
                continue
            row = []
            for c in el.iter(_NS + "c"):
                t = c.get("t")
                if t == "inlineStr":
                    row.append("".join(x.text or "" for x in c.iter(_NS + "t")))
                else:
                    v = c.find(_NS + "v")
                    if v is None:
                        row.append("")
                    elif t == "s":
                        row.append(shared[int(v.text)])
                    else:
                        try:
                            row.append(int(float(v.text)))
                        except ValueError:
                            row.append(v.text)
            el.clear()
            yield row


def read_source(source, path):
    """Yield (name, per_million) for name lists, or (form, lemma, kind,
    qualifier) for forms."""
    fmt = source["format"]
    pop = POPULATION.get(source["lang"], 1e6)
    if fmt == "pesel-xlsx":
        for row in _xlsx_rows(path):
            if len(row) < 2 or not isinstance(row[-1], int):
                continue
            yield row[0], row[-1] * 1e6 / pop
    elif fmt == "census1990-first":
        with open(path, encoding="ascii", errors="replace") as f:
            for line in f:
                p = line.split()
                if len(p) >= 2:
                    yield p[0], float(p[1]) * 1e4  # percent of the sex -> per million
    elif fmt == "census2010-zip":
        with zipfile.ZipFile(path) as z:
            name = [n for n in z.namelist() if n.lower().endswith(".csv")][0]
            for i, line in enumerate(io.TextIOWrapper(z.open(name), encoding="ascii", errors="replace")):
                p = line.strip().split(",")
                if i == 0 or len(p) < 3 or not p[2].isdigit() or p[0].upper() == "ALL OTHER NAMES":
                    continue
                yield p[0], int(p[2]) * 1e6 / pop
    elif fmt == "wikidata-tsv":
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r'^"(.*)"@[a-z-]+\s*$', line)
                if m:
                    yield m.group(1).replace('\\"', '"'), None
    elif fmt == "polimorf-tab-gz":
        with gzip.open(path, "rt", encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4:
                    yield p[0], p[1], p[2], p[3]
    else:
        raise SourceError("%s: unknown format %r" % (source["id"], fmt))


_WORD = re.compile(r"^[^\W\d_]+(?:['’-][^\W\d_]+)*$")


def norm(s):
    s = s.strip()
    return s.casefold() if _WORD.match(s) else None


def _freq(per, lang):
    """Column value: per million, -1 for a name known without a frequency
    (Wikidata, the dictionary), NULL when the language has no such name."""
    if lang not in per:
        return None
    return -1.0 if per[lang] is None else round(per[lang], 3)


def load_rules(rules_dir, langs):
    rules = {}
    for lang in langs:
        with open(os.path.join(rules_dir, "%s.json" % lang), encoding="utf-8") as f:
            rules[lang] = json.load(f)
    return rules


def build(sources, src_dir, out, rules_dir, verify=True, download=False, forms="dict", langs=None):
    """Build OUT from SOURCES (the parsed sources.json). FORMS is "dict"
    (store the dictionary's inflected forms) or "rules" (leave them out; the
    layer derives lemmas from the ending rules)."""
    entries = [s for s in sources["sources"] if langs is None or s["lang"] in langs]
    langs = sorted({s["lang"] for s in entries})
    rules = load_rules(rules_dir, langs)
    paths = {}
    for s in entries:
        path = fetch(s, src_dir) if download else os.path.join(src_dir, s["file"])
        if not os.path.exists(path):
            raise SourceError("%s: %s is missing" % (s["id"], path))
        if verify and s.get("sha256"):
            got = _sha256(path)
            if got != s["sha256"]:
                raise SourceError("%s: checksum %s does not match %s" % (s["id"], got, s["sha256"]))
        paths[s["id"]] = path

    names = {"given": {}, "surname": {}}  # name -> {lang: per_million or None}
    counts = {}
    for s in entries:
        if s["kind"] not in names:
            continue
        n = 0
        for raw, pm in read_source(s, paths[s["id"]]):
            key = norm(raw)
            if not key:
                continue
            n += 1
            per = names[s["kind"]].setdefault(key, {})
            if pm is None:
                per.setdefault(s["lang"], None)
            else:
                per[s["lang"]] = (per.get(s["lang"]) or 0.0) + pm
        counts[s["id"]] = n

    # Registry names below the language's threshold are dropped; names known
    # only from Wikidata or the dictionary (no frequency) are kept.
    for kind in names:
        for key in list(names[kind]):
            per = names[kind][key]
            keep = False
            for lang, pm in per.items():
                minimum = rules[lang]["min_%s_per_million" % kind]
                if pm is None or pm >= minimum:
                    keep = True
            if not keep:
                del names[kind][key]

    form_rows = {}
    common = set()
    for s in entries:
        if s["kind"] != "forms":
            continue
        name_keys = set()
        n = 0
        for form, lemma, _tag, qual in read_source(s, paths[s["id"]]):
            kind = "given" if "imię" in qual else "surname" if "nazwisko" in qual else None
            if kind is None:
                continue
            f, l = norm(form), norm(lemma)
            if not f or not l:
                continue
            n += 1
            names[kind].setdefault(l, {}).setdefault(s["lang"], None)
            name_keys.add(f)
            name_keys.add(l)
            if forms == "dict" and f != l:
                form_rows[(f, kind)] = l
        # Common nouns whose forms are spelt like a name (Róża, Maja): such
        # names need a stronger neighbour.
        name_keys.update(names["given"])
        name_keys.update(names["surname"])
        for form, _lemma, _tag, qual in read_source(s, paths[s["id"]]):
            if qual == "pospolita" and form[:1].islower():
                f = norm(form)
                if f in name_keys:
                    common.add(f)
        counts[s["id"]] = n

    tmp = out + ".part"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    cols = ", ".join("%s REAL" % lang for lang in langs)
    for kind in ("given", "surname"):
        db.execute("CREATE TABLE %s (name TEXT PRIMARY KEY, %s) WITHOUT ROWID" % (kind, cols))
        db.executemany("INSERT INTO %s VALUES (?, %s)" % (kind, ", ".join("?" for _ in langs)),
                       ((k,) + tuple(_freq(per, lang) for lang in langs) for k, per in sorted(names[kind].items())))
    db.execute("CREATE TABLE form (form TEXT, kind TEXT, lemma TEXT, PRIMARY KEY (form, kind)) WITHOUT ROWID")
    db.executemany("INSERT INTO form VALUES (?, ?, ?)", ((f, k, l) for (f, k), l in sorted(form_rows.items())))
    db.execute("CREATE TABLE common (word TEXT PRIMARY KEY) WITHOUT ROWID")
    db.executemany("INSERT INTO common VALUES (?)", ((w,) for w in sorted(common)))
    db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    h = hashlib.sha256()
    for s in entries:
        h.update(("%s:%s:%s\n" % (s["id"], s.get("sha256", ""), counts.get(s["id"], 0))).encode())
    h.update(json.dumps(rules, sort_keys=True).encode())
    h.update(forms.encode())
    meta = {"schema": SCHEMA_VERSION, "langs": json.dumps(langs), "rules": json.dumps(rules, ensure_ascii=False),
            "forms": forms, "fingerprint": h.hexdigest()[:16],
            "sources": json.dumps({s["id"]: {"rows": counts.get(s["id"], 0), "licence": s.get("licence")}
                                   for s in entries})}
    db.executemany("INSERT INTO meta VALUES (?, ?)", sorted(meta.items()))
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, out)
    return counts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sources", required=True)
    ap.add_argument("--rules", help="directory with <lang>.json (default: next to the sources file)")
    ap.add_argument("--cache", required=True, help="directory for the downloaded source files")
    ap.add_argument("--out", required=True)
    ap.add_argument("--download", action="store_true", help="download missing source files")
    ap.add_argument("--forms", choices=("dict", "rules"), default="dict")
    ap.add_argument("--langs", help="comma-separated, e.g. pl,en (default: all in the sources file)")
    ap.add_argument("--skip", default="", help="comma-separated source ids (or patterns like wikidata-*) to leave out")
    args = ap.parse_args(argv)
    with open(args.sources, encoding="utf-8") as f:
        sources = json.load(f)
    skip = [p for p in args.skip.split(",") if p]
    sources["sources"] = [s for s in sources["sources"] if not any(fnmatch.fnmatch(s["id"], p) for p in skip)]
    langs = set(args.langs.split(",")) if args.langs else None
    try:
        counts = build(sources, args.cache, args.out, args.rules or os.path.dirname(os.path.abspath(args.sources)),
                       download=args.download, forms=args.forms, langs=langs)
    except (SourceError, OSError) as e:
        sys.stderr.write("names_build: %s\n" % e)
        return 1
    for k, v in sorted(counts.items()):
        sys.stderr.write("names_build: %-22s %d rows\n" % (k, v))
    sys.stderr.write("names_build: %s, %.1f MB\n" % (args.out, os.path.getsize(args.out) / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
