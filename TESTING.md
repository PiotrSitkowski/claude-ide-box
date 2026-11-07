# Testing

What is verified automatically, where, and what is not.

| Layer | Command | Needs |
|---|---|---|
| Static analysis | `shellcheck -x bin/pii-airgap tests/...` (see CI) | shellcheck 0.11 |
| Python unit | `cd detector && python3 -m unittest discover -s tests -t .` | Python 3.10+ only (`pdftotext` optional) |
| Shell unit | `tests/run-unit.sh [filter]` | bash 3.2+; `CLAUDE_IDE_BOX_SRC=<checkout>` enables the container-name cross-check |
| Integration | `PII_AIRGAP_IMAGE=pii-airgap:spacy tests/integration/run.sh` | Docker or Podman and a built image |
| Evaluation | `python3 eval/evaluate.py [--ner SPEC]` | the corpus in `eval/`; spaCy for `--ner spacy` |

## Python unit tests (104)

| File | Covers |
|---|---|
| `test_validators.py` (16) | every check-digit algorithm with specimen numbers from the specifications, and with one digit changed, wrong lengths, impossible dates |
| `test_detect.py` (13) | exact spans; bad checksums ignored; digits inside longer numbers ignored; weak checksums only with a context word; national IDs of PL, US, DE, ES, IT, NL; dates of birth only after a birth keyword; addresses in PL/DE/EN; local phone numbers only after "tel."; user lists (whole words, case-insensitive, file format); NER findings merged and losing overlaps to checksums |
| `test_tokens.py` (28) | same value same token, counters per type, exact text as key; refusal of token-shaped originals; round trip; unknown and ten kinds of altered tokens reported; near misses already in the original ignored; map file 600 in a 700 directory; trees: untouched files restored byte for byte, edits and new files restored, nothing written on a problem, `--keep-unresolved`, refusal on token-shaped text, documents with PII, git metadata at any depth and PII in file names - each leaving the tree unchanged; symlinks never followed; restoring to `--out` (an empty folder; the copy keeps its tokens; nothing written on a problem) and `--into-base` (only changed and new files, deletions reported not applied, never through a symlinked directory); `verify` finds values of the map (whole words only, symlinks not followed), also one the agent wrote and one in a binary file `anonymise` left alone |
| `test_scan.py` (8) | DOCX, XLSX, PDF (when `pdftotext` exists) extraction; binary files; zip bomb refused; report without values, with lines and confidence; cache reused for unchanged files, invalidated by content and by detector configuration, never holding values; symlinks not followed |
| `test_ner.py` (6) | chunking keeps offsets; GLiNER and spaCy label mapping (with fake models, no download); offsets across chunks; fingerprints differ per model; a missing model directory is an error |
| `test_cli.py` (11) | text and JSON reports, no value printed, NER warning; `--fail-on-pii`; an unloadable model fails closed with empty stdout; bad list file; anonymise/restore exit codes and messages; `restore` needs a destination, `--in-place` warns; `verify` exit 5 with file names and no values; documents from a scan report block; `system-prompt` |
| `test_rules.py` (22) | rules from the first end-to-end test: person, place and address columns from table headers (CSV, TSV, Markdown inside text, XLSX sheets, quoted cells, a blank line starting a new table, other "name" columns ignored, header cells never findings), CSV files pseudonymised as tables, delimiter sniffing; a model's person match widened over adjacent capitalised words with titles left outside and stopping at punctuation and line ends; company names with legal forms (Polish, German, English) beating a model's partial match, no company without a name; a one-word place at a sentence, line or cell start dropped only when the model does not find it in lower case; a model's match cut at line breaks |

## Shell unit tests (35)

`tests/run-unit.sh` runs each `test_*` function in a subshell with `set -e`, a private `HOME` and a
fake `docker` first on `PATH` that records every call. The wrapper is started with `$BASH`, so the
macOS job tests `/bin/bash` 3.2 and the `bash:3.2` image job tests bash 3.2 on busybox.

Covers: every container gets `--rm`, `--network none`, `--read-only`, `--cap-drop ALL`,
`no-new-privileges` and the caller's UID, the project read-only, never the Docker socket, the home
directory or the state directory; cache and lists mounts; options and stdout passed through; the
container's exit status; lists inside the scanned folder refused; no daemon or no image fails
before anything runs; paths with commas refused; rootless Podman gets `--userns=keep-id`;
`mask-add` writes the right [Claude IDE Box](https://github.com/PiotrSitkowski/claude-ide-box) file, keeps other settings, does not duplicate, refuses
paths outside the project, with spaces or glob characters, or missing; the container name equals
Claude IDE Box's own `cb_container_name` for odd names (skipped without `CLAUDE_IDE_BOX_SRC`);
`try-prepare` scans read-only without the map, then pseudonymises with the map in a 700 directory
outside the try root, stops when the scan fails, passes the refusal status through with advice;
`try-restore` mounts the map read-only and the snapshot as baseline; no try copy or no map fails;
`try-forget`; `system-prompt`; unknown commands; help text carries the "not a compliance tool"
statement.

## Integration tests (46 with a model, 45 without)

`tests/integration/run.sh` uses the real image and engine. It builds fixtures (DOCX, XLSX with
inline strings, a PDF, a PNG scan rendered from it and a legacy `.doc` converted by LibreOffice
inside the image) and checks: each format is read by the intended method and the expected types
are found; no value in the report or the cache; the project is unchanged by a scan; with a model,
names are found under `--network none` with no lists (proves the model is baked in); the second
scan comes from the cache. Then the whole try flow on a directory laid out like Claude IDE Box's
try copy: refusal on documents with PII (status 3, names them, nothing changed); after the
documents are blanked, tokens in the copy, `.git` removed, no value left, map 600 outside the try
root, files keep the host owner; an altered token stops restoration (status 4, file and line,
nothing written); after fixing it, untouched files equal the snapshot byte for byte and edited and
new files get the real values; `try-forget`.
Then the manual flow from the README: `restore` without a destination is refused and the copy keeps
its tokens; `restore --out` writes the real values to a new folder, the copy still passes `verify`,
and the new folder is recorded and fails `verify` (5); `--into-base` applies a new file to the
original; the old `--in-place` warns and `verify` then names the file (never the value). With
`CLAUDE_IDE_BOX_SRC` pointing at Claude IDE Box sources that have the pre-start check
(`lib/claude-ide-box/pii.sh`), its wrapper refuses to start in the restored copy and in the
`--out` folder, and does not refuse the tokenised copy; without them that part says SKIP.

## Results

| Environment | Result |
|---|---|
| Python 3.13, Ubuntu 24.04 (development sandbox) | 104 passed |
| Shell unit, GNU bash 5.2, with `CLAUDE_IDE_BOX_SRC` | 35 passed |
| Shell unit, `bash:3.2` image (bash 3.2.57, musl, busybox), with `CLAUDE_IDE_BOX_SRC` | 35 passed |
| shellcheck 0.11.0 | clean |
| Integration, Docker 29.9.2, image `NER=spacy` (1.36 GB) | 30 passed |
| Integration, Docker 29.9.2, image `NER=none` (0.90 GB) | 29 passed; 45 passed with the restore and pre-start checks (image built on Ubuntu 24.04 with the sandbox's proxy and CA; `CLAUDE_IDE_BOX_SRC` = the Claude IDE Box branch with the check) |
| Evaluation inside the `spacy` image under `--network none` | identical to the host run |
| CI (GitHub Actions), run 37 | all jobs green: shellcheck, shell unit on ubuntu, macOS `/bin/bash` 3.2 and `bash:3.2`, Python 3.10/3.12/3.13 and macOS, corpus and scores reproducible, integration with images `none`, `spacy` and `gliner` (30 passed), evaluation inside each image |

## Written test-first

Each stage's tests were committed with the code, but run red before the implementation existed:

- validators, detector, tokens and scanning: the four test modules (55 tests) failed to import;
- NER backends and CLI: `test_ner` (6) failed to import, all 9 CLI tests failed;
- short backend names (`--ner gliner`): 1 of 1 red;
- the shell wrapper: the first run showed 5 of 21 passing - the harness ran test functions without
  `set -e` inside a command substitution, so a failed assertion did not stop a test. Fixed, the
  real red run was 18 failed, 2 passed vacuously (refusal tests, which a missing script also
  "passes"), 1 skipped (cross-check without `CLAUDE_IDE_BOX_SRC`).

The rules from the first end-to-end test were written the same way: the corpus gained 15 cases
modelled on what that test let through and was scored before any rule changed (spaCy: 31 of 42
values fully masked; GLiNER in CI: 41 of 42), then `test_rules.py` failed to import (19 tests),
the rules were added, and three more tests were written red after a scoring run showed spaCy
joining a table's last cell to the next row, a header cell taken for a place, and place columns.
Afterwards: 42 of 42 with both models. The scan helper in `test_scan.py` had to accept the new
`table` argument of `detect`.

Problems the tests found on the way: tokens were numbered from the end of the text; a short PDF
was sent to OCR because the "has a text layer" threshold counted characters per file instead of
looking at each page (now per page, which also handles mixed PDFs); a PESEL in a test had a wrong
check digit (the validator was right); spaCy entities were not returned in text order;
`mask-add` refused to re-add an already masked, since deleted file; the first integration run had
three failures - two test bugs and one assertion that depended on the model (spaCy tags the word
"karta" as an organisation), now checked as "contains the expected types". A review before any
test caught that the model fingerprint used Python's randomised `hash()`, which would have made
every cache entry miss.

- restore never in place, `verify` and the copy record (after a leak found in a manual test: a copy
  restored in place was opened again and sent a contract with a PESEL to the API): 10 new
  `test_tokens` tests failed to import (`verify_tree`), 3 of the CLI tests failed; 11 of 13 new
  shell tests failed (the 2 refusal checks passed, as refusals do on a missing feature), then 1 more
  for the recorded `--out` folder. The new integration section run against `main` (image and
  wrapper from `main`) failed 13 of its 16 checks and all 3 restore commands it runs -
  `restore` without a destination silently restored the copy in place, and Claude IDE Box's wrapper
  started in the restored copy. The 3 checks that passed were the tokens after `anonymise` and two
  that a missing feature also passes. All of them pass on the branch (45 of 45 in the suite). Writing it also showed that
  `anonymise` leaves a value in a binary file it cannot read (the fixture's `bin.dat`): `verify`
  reports it, so Claude IDE Box refuses such a copy until the file is masked or removed.

- source code read as code (the model only in strings and comments): `test_code` (13 tests)
  failed to import before `pii_airgap/code.py` existed; then 3 more failed before `anonymise`
  passed the file's syntax on and the detector version changed (so cached scans of code files are
  redone). One test was wrong at first: its fake model matches "User" in "UserProfile", not the
  whole word.

## False alarms in code

`eval/code_alarms.py` with the corpus in `eval/code-corpus.json` (2602 source files of 9 packages:
Python, JavaScript, TypeScript, Go, Rust). A PERSON finding counts as a false alarm unless its
line is an attribution (copyright, author, ...).

| NER | Model reads | Code: PERSON false alarms | Masked PL % | Masked EN % | ms per code file |
|---|---|---:|---:|---:|---:|
| spaCy | the whole file (before) | 7289 | 96.1 | 97.5 | 22.2 |
| spaCy | strings and comments (after) | 3503 | 96.1 | 97.5 | 12.8 |
| GLiNER | the whole file (before) | 581 \* | 98.5 | 99.0 | 1814 |
| GLiNER | strings and comments (after) | 243 \* | 98.5 | 99.0 | 1075 |

\* every 4th file (651 files): GLiNER is about 100 times slower.

spaCy was measured in the development sandbox on all files and again in CI with the same counts
(the CI runner is slower: 21.2 ms per code file after the change); GLiNER in CI only, by the
`False alarms in code` workflow on the commit before the change and on the change. The text corpus is not code, so its masked share
does not change; it is listed to show that. What remains comes mostly from documentation inside
comments (JSDoc in lodash and rxjs: "Creates", "Checks", examples written as code in comments).

## Not tested, and why

- **GLiNER locally.** huggingface.co and download.pytorch.org were blocked in the development
  sandbox; the `gliner` image was built and tested only by CI. Its first three CI builds failed
  (missing `protobuf`, then a too strict `protobuf<7`, then torch calling `getpwuid()` for a UID
  without a passwd entry - each caught by the build-time self-test or the integration suite, as
  designed). The fourth passed. Those builds used `GLINER_REVISION=main`; it is now pinned to commit
  `443d26d` of the model repository, and its encoder `microsoft/mdeberta-v3-base` to `a048466`.
- **macOS and `/bin/bash` 3.2 on BSD userland**: covered by the CI job only (the first run failed: `TMPDIR` ends with `/` on macOS; fixed).
- **Podman** for real: only the fake-engine test of `--userns=keep-id`.
- **Claude IDE Box end to end** (`up --try --pseudonymise` with a real Claude session): the hooks
  are a proposal with their own unit tests in Claude IDE Box; the integration test here uses a
  directory laid out like its try copy.
- **How well Claude keeps tokens intact** with the appended prompt: needs real sessions; the
  restoration side is what is tested.
- **OCR quality** on real scans, photos and handwriting; only a clean rendered page is tested.
- **Real documents.** The corpus is synthetic; see the README on how to read the numbers.
