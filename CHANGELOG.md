# Changelog

All notable changes to pii-airgap are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): before 1.0, a minor version may change
behaviour, options or the detector's results in ways that need attention when updating; the notes
say so.

## [0.1.0] - unreleased

The first release. `pii-airgap --version` prints `0.1.0`. The detector's own version, which keys the
scan cache, is `3`.

> [!WARNING]
> No detector finds all personal data. What pii-airgap misses is sent to the AI provider in clear
> text. It reduces exposure; it is not GDPR, CCPA or HIPAA compliance.

### Platforms

Every command runs in a Docker container started by the `bin/pii-airgap` wrapper; the wrapper runs
on bash 3.2 and on BSD, GNU and busybox tools. Checked: Linux with Docker Engine (development
sandbox and CI: unit, integration and evaluation); macOS in CI for the shell wrapper (`/bin/bash`
3.2) and the Python unit tests only. Docker Desktop on macOS or Windows, Apple Silicon and Podman
have not been run (Podman only through a fake engine in a unit test). Building the image needs
network access; using it does not.

### Added

- **`scan`**: which files hold which kinds of personal data, with a confidence per finding, as text
  or JSON (`--json`; `--fail-on-pii` exits 3 when anything is found). Reads plain text,
  DOCX/XLSX/PPTX, OpenDocument, PDF (text layer checked per page), scans (OCR in Polish, English and
  German) and legacy Office formats, with size limits for archives. Results are cached by content
  hash; neither the cache nor the report holds a detected value - only type, line, confidence and a
  masked preview.
- **Detection in layers**:
  - checksums for IBAN, payment cards, PESEL, NIP, REGON, Polish ID card and passport, US SSN
    (format rules), German Steuer-ID, Spanish DNI/NIE, Italian codice fiscale, French NIR, Dutch
    BSN, Swedish personnummer, Finnish HETU and Belgian national number; weak checksums count only
    with a context word nearby;
  - patterns with context for e-mail, phone numbers, dates of birth, street addresses and Polish
    postcodes;
  - tables: every cell of a column whose header names a person, a place or an address (CSV, TSV,
    XLSX, Markdown);
  - legal forms: capitalised words before `Sp. z o.o.`, `S.A.`, `GmbH`, `Ltd`, `Inc.`... are one
    organisation;
  - your own lists in `~/.config/pii-airgap/lists/`, outside every scanned folder;
  - a local NER model for names, organisations and places: spaCy `xx_ent_wiki_sm` by default,
    GLiNER `urchade/gliner_multi-v2.1` as an option (`pii-airgap build --ner gliner`), or none.
    A person match is widened over adjacent capitalised words (titles left outside), cut at line
    breaks, and a one-word place at the start of a sentence is dropped when the model no longer
    finds it in lower case.
- **Source code read as code**: in files with a known source extension the model reads only
  string literals and comments, never identifiers or keywords; checksums, patterns and lists
  still read the whole file. The comment and string syntax is data per language (Python, shells,
  the C family, JavaScript and TypeScript, Go, Rust, PHP, SQL, Lua, Haskell, Erlang, PowerShell).
- **`anonymise` and `restore`**: values become `[TYPE_N]` tokens in a copy; the token map stays on
  the host. `restore` never writes into the copy: `--out NEW_DIR` writes the restored tree to a new,
  empty folder, `--base ORIGINAL --into-base` applies changed and new files to the original
  (deletions are reported, not applied). `--in-place` remains for scripts and warns. Restoration is
  strict: only exact known tokens are replaced; unknown or altered ones are reported with file and
  line and nothing is written (unless `--keep-unresolved`).
- **`verify COPY` and the copy record**: `anonymise` and `restore --out` record the folder, its map
  and the map's fingerprint in `~/.local/state/pii-airgap/copies`; `verify` lists files that hold
  values of the map in clear text (exit 5), never printing a value; `forget-copy` deletes a record.
  Claude IDE Box reads these records and refuses to start a container in such a folder.
- **Claude IDE Box integration**: `mask-add FILE...` adds files to the project's masks in Claude IDE
  Box's per-project config (never in the project); `try-prepare` and `try-restore` pseudonymise
  and restore the copy of a `claude-ide-box up --try` session; `system-prompt` prints the
  instructions that tell the agent tokens are immutable. The Claude IDE Box side of the try hooks is
  a proposal and not part of its 0.1.0 release; the two steps can be run by hand around a try
  session.
- **The image** (`image/Dockerfile`, `pii-airgap build`): Ubuntu 24.04 with poppler, Tesseract
  (pol, eng, deu) and headless LibreOffice; the model is baked in at build time and a self-test
  with the model fails the build if it cannot load. GLiNER's weights and its encoder are pinned to
  commits. A TLS-intercepting proxy's CA can be passed as a build secret and is not stored. Measured
  sizes: 0.90 GB with `NER=none`, 1.36 GB with spaCy.
- **Evaluation**: a synthetic labelled corpus of 230 documents in Polish, English and German, a
  scorer with precision, recall and masked characters per type and language, 15 cases from the
  first end-to-end test with Claude IDE Box, and a false-alarm corpus of source code (2602 files of
  9 permissively licensed packages, downloaded at pinned versions and checked against their
  checksums, not stored in git) with a workflow that measures it.

### Security

- Every scan, pseudonymisation and restoration runs in a throw-away container with
  `--network none`, a read-only root file system, no capabilities, your UID, and memory and process
  limits; the project is mounted read-only for scanning.
- The token map lives in `~/.local/state/pii-airgap/` (directory 700, file 600) and is never mounted
  into the agent's container or the scanner.
- A configured model that fails to load stops the run; a missing model never turns into "no names
  found".
- `anonymise` refuses, changing nothing, when git metadata is present (its history holds the
  original values), when a document with personal data cannot be rewritten in place, when a file
  name holds personal data, when a non-UTF-8 text file seems to hold some, or when text already
  looks like a token.
- Real values never come back into the folder an agent works in (see `restore` above); this
  follows a manual test in which a copy restored in place was opened again and a contract with a
  PESEL was sent to the API.
- Lists of what is looked for must live outside every scanned folder, so an agent that can edit the
  project cannot edit them.

Known limitations, in [SECURITY.md](SECURITY.md): a compromised parser in the scan container can
report "no PII"; misses are sent in clear text; a valid token the agent copied to a new place is
restored there too; the pre-start check in Claude IDE Box knows only copies recorded on this
machine.

### Measured quality

On the synthetic corpus with the default spaCy model, masked characters: Polish 96.1 %, English
97.5 %, German 95.6 %; with GLiNER 98.5 %, 99.0 % and 98.5 %, at about 90 times the CPU time. All 42
values of the 15 end-to-end cases are fully masked with either model. Reading code as code cut
spaCy's PERSON false alarms in the code corpus from 7289 to 3503 (GLiNER, every 4th file: 581 to
243), with the masked share of the text corpus unchanged. The corpus is small and synthetic, and
written by the same person as the rules; real documents will do worse. Details and how to read the
numbers: README and [TESTING.md](TESTING.md).

[0.1.0]: https://github.com/PiotrSitkowski/pii-airgap/releases/tag/v0.1.0
