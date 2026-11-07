"""Precision and recall per entity type on the synthetic corpus.

    PYTHONPATH=detector python3 eval/evaluate.py [--ner SPEC] [--corpus eval/corpus.jsonl]

A prediction is a true positive when it overlaps a gold entity of the same
type (one-to-one). "Masked" is the share of gold characters covered by any
prediction, whatever its type: what pseudonymisation actually hides.
"""

import argparse
import inspect
import json
import os
import sys
import time
from collections import defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "detector"))

from pii_airgap.detect import Detector  # noqa: E402
from pii_airgap.ner import load_backend  # noqa: E402

try:
    from pii_airgap.names import load_names  # noqa: E402
except ImportError:  # detector without the name layer
    load_names = None

# Table-aware detection (headers naming a person column) where supported.
_TABLES = "table" in inspect.signature(Detector.detect).parameters


def score(docs, detector):
    tp, fp, fn = defaultdict(int), defaultdict(int), defaultdict(int)
    chars = defaultdict(lambda: [0, 0])  # lang -> [covered, total]
    person_chars = defaultdict(lambda: [0, 0])  # the same for PERSON values only
    per_lang = defaultdict(lambda: [0, 0, 0])
    elapsed = 0.0
    for d in docs:
        t0 = time.time()
        if d.get("format") == "csv" and _TABLES:
            preds = detector.detect(d["text"], table=d["delimiter"])
        else:
            preds = detector.detect(d["text"])
        elapsed += time.time() - t0
        used = set()
        for g in d["entities"]:
            hit = None
            for i, p in enumerate(preds):
                if i not in used and p.type == g["type"] and p.start < g["end"] and g["start"] < p.end:
                    hit = i
                    break
            if hit is None:
                fn[g["type"]] += 1
                per_lang[d["lang"]][2] += 1
            else:
                used.add(hit)
                tp[g["type"]] += 1
                per_lang[d["lang"]][0] += 1
            covered = sum(1 for c in range(g["start"], g["end"]) if any(p.start <= c < p.end for p in preds))
            chars[d["lang"]][0] += covered
            chars[d["lang"]][1] += g["end"] - g["start"]
            if g["type"] == "PERSON":
                person_chars[d["lang"]][0] += covered
                person_chars[d["lang"]][1] += g["end"] - g["start"]
        for i, p in enumerate(preds):
            if i not in used:
                fp[p.type] += 1
                per_lang[d["lang"]][1] += 1
    score.person_chars = person_chars
    return tp, fp, fn, chars, per_lang, elapsed


def field_report(docs, detector):
    """Per document of the field cases: each labelled value fully masked,
    partly masked or missed, and each finding that matches nothing."""
    rows = []
    totals = {"full": 0, "partial": 0, "missed": 0, "false": 0}
    for d in docs:
        if not d["id"].startswith("field-"):
            continue
        if d.get("format") == "csv" and _TABLES:
            preds = detector.detect(d["text"], table=d["delimiter"])
        else:
            preds = detector.detect(d["text"])
        notes = []
        for g in d["entities"]:
            covered = sum(1 for c in range(g["start"], g["end"]) if any(p.start <= c < p.end for p in preds))
            size = g["end"] - g["start"]
            text = d["text"][g["start"]:g["end"]]
            if covered == size:
                totals["full"] += 1
            elif covered:
                totals["partial"] += 1
                notes.append("partly %s `%s`" % (g["type"], text))
            else:
                totals["missed"] += 1
                notes.append("**missed** %s `%s`" % (g["type"], text))
        for p in preds:
            if not any(p.start < g["end"] and g["start"] < p.end for g in d["entities"]):
                totals["false"] += 1
                notes.append("false %s `%s`" % (p.type, d["text"][p.start:p.end]))
        rows.append((d["id"], d["lang"], "; ".join(notes) or "all masked"))
    return rows, totals


def pct(a, b):
    return "-" if b == 0 else "%.1f" % (100.0 * a / b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus.jsonl"))
    ap.add_argument("--ner", default="none")
    ap.add_argument("--names", default="none", help="name dictionary database (default: none)")
    args = ap.parse_args()
    with open(args.corpus, encoding="utf-8") as f:
        docs = [json.loads(line) for line in f if line.strip()]
    if args.names != "none":
        det = Detector(ner=load_backend(args.ner), names=load_names(args.names))
    else:
        det = Detector(ner=load_backend(args.ner))
    tp, fp, fn, chars, per_lang, elapsed = score(docs, det)
    print("Corpus: %d documents (%s), NER: %s%s, %.1f ms per document\n"
          % (len(docs), ", ".join("%s %d" % (l, sum(1 for d in docs if d["lang"] == l)) for l in ("pl", "en", "de")),
             args.ner, "" if args.names == "none" else ", names: " + os.path.basename(args.names),
             1000.0 * elapsed / max(1, len(docs))))
    print("| Type | Gold | Found | False positives | Precision % | Recall % |")
    print("|---|---:|---:|---:|---:|---:|")
    for t in sorted(set(tp) | set(fp) | set(fn)):
        print("| %s | %d | %d | %d | %s | %s |" % (t, tp[t] + fn[t], tp[t], fp[t], pct(tp[t], tp[t] + fp[t]),
                                                 pct(tp[t], tp[t] + fn[t])))
    print("\n| Language | Precision % | Recall % | Masked characters % |")
    print("|---|---:|---:|---:|")
    for lang in ("pl", "en", "de"):
        a, b, c = per_lang[lang]
        print("| %s | %s | %s | %s |" % (lang, pct(a, a + b), pct(a, a + c), pct(chars[lang][0], chars[lang][1])))
    if args.names != "none":
        pc = score.person_chars
        print("\nMasked characters of PERSON values: %s" % ", ".join(
            "%s %s %%" % (lang, pct(pc[lang][0], pc[lang][1])) for lang in ("pl", "en", "de")))
    rows, totals = field_report(docs, det)
    if rows:
        print("\nField cases (from the end-to-end test): %d values fully masked, %d partly, %d missed; "
              "%d false findings\n" % (totals["full"], totals["partial"], totals["missed"], totals["false"]))
        print("| Case | Language | Result |")
        print("|---|---|---|")
        for case, lang, note in rows:
            print("| %s | %s | %s |" % (case, lang, note))


if __name__ == "__main__":
    main()
