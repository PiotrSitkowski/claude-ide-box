# pii-airgap - design

## Goal

Lower the amount of personal data an AI agent (Claude Code in Claude IDE Box, or anything else
that works on a folder) sends to its provider, without sending anything anywhere else and without
pretending to be complete.

## Non-goals

- Compliance. The tool cannot know every identifier, and its misses are silent by nature.
- Pseudonymising binary documents in place (DOCX, PDF, images). Rewriting them while keeping them
  valid is possible but large; they are masked instead.
- A small local LLM as a detector. Slower, heavier, less predictable, and hard to evaluate.

## Components

```text
host                                             container (--network none, read-only, no caps)
----                                             ---------------------------------------------
bin/pii-airgap (bash 3.2)                        python3 -P -m pii_airgap
  paths, checks, mounts, map location              scan       extract + detect, report without values
  mask-add -> ~/.config/claude-ide-box/...         anonymise  plan, refuse or write tokens, save map
  try-prepare / try-restore / try-forget           restore    exact tokens only, report the rest
                                                   system-prompt
```

The detector package uses the Python standard library only; spaCy, GLiNER and torch are imported
only when that backend is configured. The unit tests therefore run anywhere with `python3`.

### Detection

`Detector.detect(text)` collects candidates from every rule, the user lists and the NER backend,
then keeps non-overlapping ones in this order: checksum and list findings, then patterns, then the
model; within a rank higher confidence, then longer spans. A rule may require a context word in
the 40 characters before a match (weak checksums, local phone numbers, dates of birth). Matches of
rules that allow trimming (IBAN, cards, international phones) are shortened at a separator when the
full match fails validation, so "PL61 ... 2874 EXP" still finds the IBAN.

### Scanning and the cache

Files are walked without following symlinks; `.git` is skipped. The cache key is the file's SHA-256
under a directory named after the detector fingerprint (rules version, list contents, model id), so
a change to lists or model rescans everything. Cache entries hold types, kinds, lines, confidence
and a preview of the first character only.

### Text extraction

| Input | How |
|---|---|
| DOCX/DOCM/DOTX, PPTX, ODT/ODS/ODP | read as ZIP, XML text parts only, 50 MB expanded-size budget per file (zip bombs) |
| XLSX | shared strings, inline strings and values per row |
| PDF | `pdftotext`; pages without a text layer are rendered (`pdftoppm`) and OCR'd |
| PNG, JPEG, TIFF, BMP, WebP | `tesseract -l pol+eng+deu` |
| DOC, XLS, PPT, RTF, WPD | LibreOffice headless with a throw-away profile |
| anything else | UTF-8, else cp1250; NUL bytes mean binary (reported, not scanned) |

Every tool has a timeout; a missing tool or a failed conversion is reported as "not scanned",
never as "no PII".

### Pseudonymisation

Tokens are `[TYPE_N]`, `TYPE` in `A-Z`, `N` counting from 1 per type. The exact text of a finding
is the key: the same text gets the same token in every file, `Jan Kowalski` and `JAN KOWALSKI` get
different ones, so restoration reproduces the bytes. `anonymise` plans the whole tree in memory
and writes only when nothing blocks:

| Blocks | Why |
|---|---|
| `.git` anywhere (unless `--git strip`) | history and packed objects hold the original values |
| a document with PII (from the scan report) | cannot be rewritten in place: mask it |
| PII in a file name (checksum, pattern or list) | names are visible to the agent; renaming would break `try apply` |
| non-UTF-8 text that seems to hold PII | it could only be rewritten by guessing the encoding |
| token-shaped text already in a file | restoration could not tell it from a token |

Files are replaced atomically (temporary file in the same directory, same mode, `rename`). The map
is saved last, mode 600 in a mode 700 directory.

### Restoration

Only `\[[A-Z]+_[0-9]+\]` occurrences that are keys of the map are replaced. Everything else that
looks like a token is a problem:

- *unknown* - well-formed but not in the map (`[PERSON_7]`);
- *altered* - a known token with a leading zero, or a near miss of a known type: other case,
  missing or escaped brackets, a space or dash instead of the underscore. Near misses that already
  occur in the original snapshot (`enum PERSON_1`) are not counted.

With any problem, nothing is written (exit 4) unless `--keep-unresolved`.

## Claude IDE Box integration

```text
claude-ide-box up --try --pseudonymise
  try_create                    work/ and base/ copies, masked files blanked in both
  pii-airgap try-prepare DIR    container 1: scan work/ read-only, report -> host temp file
                                container 2: anonymise work/ with the map dir, --git strip
  cb_ensure_container           Claude starts on the tokenised copy, system prompt appended
claude-ide-box try apply
  try_stop_container            nothing changes the copy any more
  pii-airgap try-restore DIR    work/ back to real values (base/ for near-miss baseline)
  try_plan / try_apply          unchanged: work/ vs base/ vs project
```

Two consequences:

- `try diff` must also stop the container and restore first, otherwise the diff is in token space
  against a snapshot with real values. After a restore the copy holds real values, so the session
  is marked "restored" and a resumed session runs `try-prepare` again before the container starts
  (the map is reused, so tokens stay stable).
- `.git` is removed from the working copy of a pseudonymised session. Claude IDE Box never applies
  `.git` from a try copy anyway, but the agent cannot run `git log` or `git diff` in that session.

## Threat model

| Threat | Mitigation | Residual risk |
|---|---|---|
| a missed value reaches the provider | layered detection, lists, masks, evaluation | inherent; documented |
| a malicious document exploits a parser | scanner has no network, no map, read-only project, no caps, limits | it can lie in its report (= a miss) or fill its own cache with false entries |
| the agent edits the lists to hide a client name | lists must be outside the scanned folder | none known |
| the agent reads the map | never mounted into its container; lives in `~/.local/state` | a host process that runs project code could read it - as any host file |
| an altered token restores to the wrong value | exact-match only, near-miss detection, nothing written on problems | a correct token copied to a new place is restored there |
| tokens survive into your files | restoration before apply; unknown tokens reported | `--keep-unresolved` writes them as they are, by request |
