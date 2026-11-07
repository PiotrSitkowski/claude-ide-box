"""Scan a tree and report which files hold which kinds of PII.

Results are cached by file content hash and detector fingerprint. The cache
and the report never contain the detected values, only types, positions,
confidence and a masked preview.
"""

import hashlib
import json
import os
import stat
from collections import Counter

from .code import syntax_for
from .detect import sniff_delimiter
from .extract import DEFAULT_MAX_BYTES, ExtractionError, extract_text


def preview(s):
    s = " ".join(s.split())
    if len(s) <= 2:
        return "*" * len(s)
    return s[0] + "*" * min(len(s) - 1, 12)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _cache_get(cache_dir, key):
    if not cache_dir:
        return None
    p = os.path.join(cache_dir, key[:2], key + ".json")
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _cache_put(cache_dir, key, entry):
    if not cache_dir:
        return
    d = os.path.join(cache_dir, key[:2])
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".%s.%d" % (key, os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(entry, f)
    os.replace(tmp, os.path.join(d, key + ".json"))


def scan_file(path, detector, max_bytes=DEFAULT_MAX_BYTES):
    ex = extract_text(path, max_bytes=max_bytes)
    if ex is None:
        return None
    findings = []
    table = None
    low = path.lower()
    if ex.method == "xlsx" or low.endswith(".tsv"):
        table = "\t"
    elif low.endswith(".csv"):
        table = sniff_delimiter(ex.text)
    code = None if table else syntax_for(os.path.splitext(low)[1])
    for f in (detector.detect(ex.text, table=table, code=code) if code else detector.detect(ex.text, table=table)):
        findings.append({
            "type": f.type, "kind": f.kind, "source": f.source,
            "confidence": round(f.confidence, 3),
            "line": ex.text.count("\n", 0, f.start) + 1,
            "preview": preview(f.text),
        })
    return {"method": ex.method, "findings": findings}


def scan_tree(root, cache_dir, detector, max_bytes=DEFAULT_MAX_BYTES, progress=None):
    root = os.path.abspath(root)
    fp = detector.fingerprint()
    cache = os.path.join(cache_dir, fp[:16]) if cache_dir else None
    report = {"root": root, "detector": fp, "files": [], "errors": [],
              "skipped": {"symlink": [], "binary": [], "git": [], "special": []}}
    scanned = cached = total = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir + "/"
        for d in list(dirnames):
            if d == ".git":
                report["skipped"]["git"].append(rel_dir + d)
                dirnames.remove(d)
            elif os.path.islink(os.path.join(dirpath, d)):
                report["skipped"]["symlink"].append(rel_dir + d)
                dirnames.remove(d)
        dirnames.sort()
        for n in sorted(filenames):
            rel, path = rel_dir + n, os.path.join(dirpath, n)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                report["skipped"]["symlink"].append(rel)
                continue
            if not stat.S_ISREG(st.st_mode):
                report["skipped"]["special"].append(rel)
                continue
            if progress:
                progress(rel)
            key = _sha256(path)
            entry = _cache_get(cache, key)
            if entry is not None:
                cached += 1
            else:
                try:
                    entry = scan_file(path, detector, max_bytes)
                except ExtractionError as e:
                    report["errors"].append({"path": rel, "error": str(e)})
                    continue
                if entry is None:
                    entry = {"method": "binary", "findings": []}
                _cache_put(cache, key, entry)
            if entry["method"] == "binary":
                report["skipped"]["binary"].append(rel)
                continue
            scanned += 1
            if entry["findings"]:
                counts = Counter(f["type"] for f in entry["findings"])
                total += len(entry["findings"])
                report["files"].append({
                    "path": rel, "sha256": key, "method": entry["method"],
                    "counts": dict(counts),
                    "max_confidence": max(f["confidence"] for f in entry["findings"]),
                    "findings": entry["findings"],
                })
    report["summary"] = {"files_scanned": scanned, "files_with_pii": len(report["files"]),
                         "findings": total, "cached": cached, "errors": len(report["errors"])}
    return report
