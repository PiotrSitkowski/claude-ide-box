"""The false-alarm corpus: source code of public packages (code-corpus.json),
downloaded on demand into a cache directory and verified by checksum."""

import hashlib
import io
import json
import os
import re
import tarfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ATTRIBUTION = re.compile(r"copyright|\(c\)|©|author|maintain|contribut|signed-off|thanks|credit|written by|licen[cs]e",
                         re.I)


def spec():
    with open(os.path.join(HERE, "code-corpus.json"), encoding="utf-8") as f:
        return json.load(f)


def fetch(cache):
    os.makedirs(cache, exist_ok=True)
    for p in spec()["packages"]:
        path = os.path.join(cache, p["file"])
        if not os.path.exists(path):
            with urllib.request.urlopen(p["url"], timeout=300) as r:
                data = r.read()
            with open(path, "wb") as f:
                f.write(data)
        with open(path, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != p["sha256"]:
            raise SystemExit("code corpus: %s checksum %s does not match %s" % (p["id"], got, p["sha256"]))


def load(cache):
    """[(package id, path inside, text)] of every source file."""
    fetch(cache)
    exts = tuple(spec()["extensions"])
    files = []
    for p in spec()["packages"]:
        path = os.path.join(cache, p["file"])
        if p["format"] == "zip":
            with zipfile.ZipFile(path) as z:
                for n in z.namelist():
                    if n.endswith(exts):
                        files.append((p["id"], n, z.read(n).decode("utf-8", "replace")))
        else:
            with tarfile.open(path) as t:
                for m in t.getmembers():
                    if m.isfile() and m.name.endswith(exts):
                        files.append((p["id"], m.name, t.extractfile(m).read().decode("utf-8", "replace")))
    return files


def false_alarms(files, detector):
    """Counts over the corpus: all findings, PERSON findings, and PERSON
    findings outside attribution lines (false alarms). Also the most frequent
    false-alarm strings - public code, no personal data."""
    out = {"files": len(files), "findings": 0, "person": 0, "person_false": 0, "by_package": {}}
    top = {}
    for pkg, _name, text in files:
        for f in detector.detect(text, code=True):
            out["findings"] += 1
            if f.type != "PERSON":
                continue
            out["person"] += 1
            a = text.rfind("\n", 0, f.start) + 1
            b = text.find("\n", f.end)
            line = text[a:b if b >= 0 else len(text)]
            if ATTRIBUTION.search(line):
                continue
            out["person_false"] += 1
            out["by_package"][pkg] = out["by_package"].get(pkg, 0) + 1
            top[f.text] = top.get(f.text, 0) + 1
    out["top_false"] = sorted(top.items(), key=lambda x: -x[1])[:15]
    return out
