"""Pilot of the name dictionary layer: one row of numbers per configuration.

    PYTHONPATH=detector python3 eval/names_pilot.py --ner none,spacy:xx_ent_wiki_sm \\
        --names none,/path/names.db [--code-cache DIR]

Columns: masked characters (all types, PERSON only) for Polish and English,
the field cases, time per document, and - with --code-cache - findings in
the code corpus (eval/code-corpus.json): PERSON findings outside attribution
lines (copyright, author, ...) count as false alarms.
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "detector"))
sys.path.insert(0, HERE)

from evaluate import field_report, score  # noqa: E402
from pii_airgap.detect import Detector  # noqa: E402
from pii_airgap.names import load_names  # noqa: E402
from pii_airgap.ner import load_backend  # noqa: E402

import code_corpus  # noqa: E402


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(HERE, "corpus.jsonl"))
    ap.add_argument("--ner", default="none")
    ap.add_argument("--names", default="none")
    ap.add_argument("--code-cache", help="directory with the downloaded code corpus")
    ap.add_argument("--code-every", type=int, default=1, help="use every Nth file of the code corpus (a fixed sample)")
    ap.add_argument("--json", help="also write the rows as JSON here")
    args = ap.parse_args()
    with open(args.corpus, encoding="utf-8") as f:
        docs = [json.loads(line) for line in f if line.strip()]
    code = code_corpus.load(args.code_cache)[::args.code_every] if args.code_cache else None
    rows = []
    print("| NER | names | masked pl | masked en | PERSON pl | PERSON en | field full/part/missed/false | ms/doc |"
          " code: findings | code: PERSON | code: PERSON false alarms | code ms/file |")
    print("|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|")
    for ner_spec in args.ner.split(","):
        ner = load_backend(ner_spec)
        for names_spec in args.names.split(","):
            det = Detector(ner=ner, names=load_names(names_spec))
            _tp, _fp, _fn, chars, _pl, elapsed = score(docs, det)
            pc = score.person_chars
            _rows, tot = field_report(docs, det)
            row = {"ner": ner_spec, "names": os.path.basename(names_spec),
                   "masked_pl": pct(*chars["pl"]), "masked_en": pct(*chars["en"]),
                   "person_pl": pct(*pc["pl"]), "person_en": pct(*pc["en"]),
                   "field": tot, "ms_per_doc": 1000.0 * elapsed / max(1, len(docs))}
            if code is not None:
                t0 = time.time()
                row["code"] = code_corpus.false_alarms(code, det)
                row["code"]["ms_per_file"] = 1000.0 * (time.time() - t0) / max(1, len(code))
            rows.append(row)
            c = row.get("code", {})
            print("| %s | %s | %.1f | %.1f | %.1f | %.1f | %d/%d/%d/%d | %.1f | %s | %s | %s | %s |" % (
                row["ner"], row["names"], row["masked_pl"], row["masked_en"], row["person_pl"], row["person_en"],
                tot["full"], tot["partial"], tot["missed"], tot["false"], row["ms_per_doc"],
                c.get("findings", "-"), c.get("person", "-"), c.get("person_false", "-"),
                "%.1f" % c["ms_per_file"] if c else "-"))
            sys.stdout.flush()
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rows, f, indent=1)


if __name__ == "__main__":
    main()
