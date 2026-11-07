"""False alarms in source code, next to the masked share of the text corpus:
one row of numbers per NER backend.

    PYTHONPATH=detector python3 eval/code_alarms.py --ner none,spacy:xx_ent_wiki_sm \\
        --code-cache DIR [--code-every N] [--json FILE]

Columns: masked characters of the text corpus (all types, PERSON only) for
Polish and English, time per document, and for the code corpus
(eval/code-corpus.json) all findings, PERSON findings and PERSON findings
outside attribution lines (copyright, author, ...) - the false alarms.
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "detector"))
sys.path.insert(0, HERE)

from evaluate import score  # noqa: E402
from pii_airgap.detect import Detector  # noqa: E402
from pii_airgap.ner import load_backend  # noqa: E402

import code_corpus  # noqa: E402


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def person_chars(docs, detector):
    """Share of PERSON characters masked, per language."""
    out = {}
    for lang in ("pl", "en"):
        covered = total = 0
        for d in docs:
            if d["lang"] != lang:
                continue
            preds = detector.detect(d["text"], table=d.get("delimiter")) if d.get("format") == "csv" \
                else detector.detect(d["text"])
            for g in d["entities"]:
                if g["type"] == "PERSON":
                    covered += sum(1 for c in range(g["start"], g["end"]) if any(p.start <= c < p.end for p in preds))
                    total += g["end"] - g["start"]
        out[lang] = pct(covered, total)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(HERE, "corpus.jsonl"))
    ap.add_argument("--ner", default="none")
    ap.add_argument("--code-cache", required=True, help="directory for the downloaded code corpus")
    ap.add_argument("--code-every", type=int, default=1, help="use every Nth file of the code corpus (a fixed sample)")
    ap.add_argument("--json", help="also write the rows as JSON here")
    args = ap.parse_args()
    with open(args.corpus, encoding="utf-8") as f:
        docs = [json.loads(line) for line in f if line.strip()]
    code = code_corpus.load(args.code_cache)[::args.code_every]
    rows = []
    print("| NER | masked pl | masked en | PERSON pl | PERSON en | ms/doc | code files | code: findings |"
          " code: PERSON | code: PERSON false alarms | code ms/file |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for spec in args.ner.split(","):
        det = Detector(ner=load_backend(spec))
        _tp, _fp, _fn, chars, _pl, elapsed = score(docs, det)
        pc = person_chars(docs, det)
        t0 = time.time()
        c = code_corpus.false_alarms(code, det)
        c["ms_per_file"] = 1000.0 * (time.time() - t0) / max(1, len(code))
        row = {"ner": spec, "masked_pl": pct(*chars["pl"]), "masked_en": pct(*chars["en"]),
               "person_pl": pc["pl"], "person_en": pc["en"], "ms_per_doc": 1000.0 * elapsed / max(1, len(docs)),
               "code": c}
        rows.append(row)
        print("| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %d | %d | %d | %.1f |" % (
            spec, row["masked_pl"], row["masked_en"], row["person_pl"], row["person_en"], row["ms_per_doc"],
            c["files"], c["findings"], c["person"], c["person_false"], c["ms_per_file"]))
        sys.stdout.flush()
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rows, f, indent=1)


if __name__ == "__main__":
    main()
