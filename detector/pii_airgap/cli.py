"""Command line: python -m pii_airgap <command> ...

Exit status: 0 ok, 1 error, 2 usage, 3 refused (anonymise) or PII found
(scan --fail-on-pii), 4 restore found unknown or altered tokens.
"""

import argparse
import json
import os
import sys

from . import __version__
from .detect import Detector, parse_list_file
from .ner import load_backend
from .scan import scan_tree
from .tokens import TokenCollision, Unrewritable, anonymise_tree, restore_tree

TEXT_METHODS = ("text", "text-cp1250")

SYSTEM_PROMPT = """\
Personal data in this project was replaced before you saw it. Tokens of the
form [TYPE_N] - for example [PERSON_1], [ORG_2], [IBAN_1], [PESEL_1] - stand
for real values that will be put back after your work, by exact text match.

Treat every such token as an opaque, immutable identifier:
- Copy tokens exactly: same square brackets, capital letters, underscore and
  number. Never change their case, spacing, separator or number, never escape
  or quote the brackets differently, never split or abbreviate them.
- Never invent new tokens, and never guess, reconstruct or ask for the real
  values behind them.
- Do not inflect, translate or reformat a token, and do not merge two tokens
  into one; one token always stands for the same value.
- Do not write code that parses, validates, measures or derives anything from
  a token's text; real values have other lengths and formats.
- When you need example personal data, use obviously fictional values that do
  not use the [TYPE_N] syntax.
A token that is altered cannot be restored and will be reported to the user.
"""


def _die(msg, status=1):
    sys.stderr.write("pii-airgap: %s\n" % msg)
    sys.exit(status)


def _detector(args):
    entries = []
    for path in args.lists or []:
        try:
            with open(path, encoding="utf-8") as f:
                e, errors = parse_list_file(f.read())
        except OSError as e:
            _die("cannot read list %s: %s" % (path, e))
        if errors:
            _die("%s: %s" % (path, "; ".join(errors)))
        entries.extend(e)
    spec = args.ner if args.ner is not None else os.environ.get("PII_AIRGAP_NER", "none")
    try:
        ner = load_backend(spec)
    except Exception as e:  # noqa: any failure to load the model is fatal
        _die("cannot load the NER model (%s): %s" % (spec, e))
    if ner is None:
        sys.stderr.write("pii-airgap: warning: NER is off - names, organisations and places are only found "
                         "through your lists\n")
    return Detector(lists=entries, ner=ner), spec


def _print_report(rep, min_conf):
    out = sys.stdout
    for f in rep["files"]:
        finds = [x for x in f["findings"] if x["confidence"] >= min_conf]
        if not finds:
            continue
        counts = {}
        for x in finds:
            counts[x["type"]] = counts.get(x["type"], 0) + 1
        out.write("%s  [%s]  %s\n" % (f["path"], f["method"],
                                     ", ".join("%s x%d" % kv for kv in sorted(counts.items()))))
        for x in finds:
            out.write("    line %-5d %-10s %-6s %-9s %s\n" % (x["line"], x["type"], "%.2f" % x["confidence"],
                                                           x["source"], x["preview"]))
    for e in rep["errors"]:
        out.write("NOT SCANNED %s: %s\n" % (e["path"], e["error"]))
    s = rep["summary"]
    out.write("%d file(s) scanned, %d with PII, %d finding(s), %d from cache, %d not scanned\n"
              % (s["files_scanned"], s["files_with_pii"], s["findings"], s["cached"], s["errors"]))
    if rep["skipped"]["binary"]:
        out.write("%d binary file(s) of unknown type were not scanned\n" % len(rep["skipped"]["binary"]))


def cmd_scan(args):
    det, spec = _detector(args)
    cache = None if args.no_cache else (args.cache or os.environ.get("PII_AIRGAP_CACHE"))
    rep = scan_tree(args.root, cache, det)
    rep["ner"] = spec
    if args.json:
        json.dump(rep, sys.stdout, indent=1, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        _print_report(rep, args.min_confidence)
    if args.fail_on_pii and rep["files"]:
        return 3
    return 1 if rep["errors"] and args.fail_on_error else 0


def cmd_anonymise(args):
    det, _ = _detector(args)
    docs = []
    if args.scan_report:
        with open(args.scan_report, encoding="utf-8") as f:
            rep = json.load(f)
        docs = [x["path"] for x in rep.get("files", []) if x.get("method") not in TEXT_METHODS]
        docs += ["%s (could not be scanned: %s)" % (x["path"], x["error"]) for x in rep.get("errors", [])]
    try:
        r = anonymise_tree(args.root, args.map, det, git=args.git, documents_with_pii=docs)
    except (TokenCollision, Unrewritable) as e:
        _die(str(e), 3)
    sys.stderr.write("pii-airgap: pseudonymised %d file(s)\n" % len(r.changed))
    for rel in r.changed:
        sys.stdout.write("%s\n" % rel)
    return 0


def cmd_restore(args):
    try:
        r = restore_tree(args.root, args.map, args.base, keep_unresolved=args.keep_unresolved)
    except (OSError, ValueError) as e:
        _die("cannot restore: %s" % e)
    for p in r.problems:
        sys.stderr.write("%s:%d: %s token %s\n" % (p.path, p.line, p.kind, p.text))
    if r.problems and not r.written:
        sys.stderr.write("pii-airgap: %d token problem(s); nothing was restored. Fix the tokens in the files "
                         "above, or pass --keep-unresolved to leave them as they are.\n" % len(r.problems))
        return 4
    sys.stderr.write("pii-airgap: restored %d file(s)%s\n"
                     % (len(r.changed), ", %d problem(s) left as written" % len(r.problems) if r.problems else ""))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="pii-airgap")
    p.add_argument("--version", action="version", version="pii-airgap " + __version__)
    sub = p.add_subparsers(dest="cmd")

    def common(sp):
        sp.add_argument("--lists", action="append", help="list file: 'term' or 'TYPE: term' per line")
        sp.add_argument("--ner", help="gliner:<dir>, spacy:<name> or none (default: $PII_AIRGAP_NER)")

    s = sub.add_parser("scan", help="report which files hold which kinds of PII")
    s.add_argument("root")
    common(s)
    s.add_argument("--json", action="store_true")
    s.add_argument("--cache")
    s.add_argument("--no-cache", action="store_true")
    s.add_argument("--min-confidence", type=float, default=0.0)
    s.add_argument("--fail-on-pii", action="store_true")
    s.add_argument("--fail-on-error", action="store_true")

    a = sub.add_parser("anonymise", aliases=["anonymize"], help="replace PII by [TYPE_N] tokens, in place")
    a.add_argument("root")
    common(a)
    a.add_argument("--map", required=True)
    a.add_argument("--git", choices=("refuse", "strip"), default="refuse")
    a.add_argument("--scan-report", help="scan --json output; documents with PII in it block the run")

    r = sub.add_parser("restore", help="put real values back for exact known tokens")
    r.add_argument("root")
    r.add_argument("--map", required=True)
    r.add_argument("--base", help="the original tree, to tell new near-miss tokens from old text")
    r.add_argument("--keep-unresolved", action="store_true")

    sub.add_parser("system-prompt", help="print the instructions to append to the agent's system prompt")

    args = p.parse_args(argv)
    if args.cmd == "scan":
        return cmd_scan(args)
    if args.cmd in ("anonymise", "anonymize"):
        return cmd_anonymise(args)
    if args.cmd == "restore":
        return cmd_restore(args)
    if args.cmd == "system-prompt":
        sys.stdout.write(SYSTEM_PROMPT)
        return 0
    p.print_help(sys.stderr)
    return 2
