# Contributing

Design: [docs/DESIGN.md](docs/DESIGN.md). Model choices: [docs/MODELS.md](docs/MODELS.md).

## Language and style
- Everything in the repository is in English: code, comments, docs, commit messages.
- Plain hyphens (-) in prose, not em dashes.
- **Never commit real personal data**, not even in a test or an issue. Use invented names and
  numbers generated with valid check digits (see `eval/make_corpus.py`).

## Shell (`bin/`, `tests/`)
- Must run on **bash 3.2** (macOS default) and on GNU and BSD userlands. Not allowed: associative
  arrays, `mapfile`/`readarray`, `${var,,}`, `[[ -v ]]`, `wait -n`, `flock`, `timeout`,
  `sed -i` without a suffix argument, `stat -c`, `date -d`, `readlink -f`. Empty arrays are expanded
  as `${a[@]+"${a[@]}"}` (bash 3.2 treats `"${a[@]}"` of an empty array as unset under `set -u`).
- `set -euo pipefail`; `shellcheck` 0.11 must pass; any disabled check carries a comment.
- The wrapper never reads file contents and never runs anything from the scanned folder.

## Python (`detector/`)
- Standard library only in the core; optional backends are imported lazily.
- Python 3.9 or newer.
- Anything that cannot be read is an error in the report, never an empty result.

## Rules that keep the design honest
- A detection rule comes with tests for both what it must find and what it must not.
- New identifiers need a check digit or a context word; a bare digit pattern is not enough.
- Every container started by the wrapper keeps `--network none`, `--read-only`, `--cap-drop ALL`,
  `no-new-privileges` and the caller's UID. The map is never mounted into the scan container.
- Changes to detection update `eval/results-*.md` and the README tables (CI compares them).

## Tests
Test first: add the test, run it and see it fail, then implement. See [TESTING.md](TESTING.md).
