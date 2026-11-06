# pii-airgap

Air-gapped PII detector and reversible anonymiser for AI coding agents and document work - native
plugin for [Claude IDE Box](https://github.com/PiotrSitkowski/claude-ide-box), usable on its own with
plain `docker run --network none`.

> **Read this first.** No detector finds all personal data. Whatever pii-airgap misses is sent to the
> AI provider in clear text, exactly as without it. It reduces exposure; it does not make a workflow
> compliant with GDPR, CCPA, HIPAA or any other regulation, and it is not a substitute for a data
> protection assessment, a processing agreement with the provider, or not sending the data at all.

## What it does

- **`scan`** - tells you which files hold which kinds of personal data, with a confidence per finding.
  Plain text, DOCX/XLSX/PPTX, OpenDocument, PDF, scans (OCR in Polish, English and German) and
  legacy Office formats. Results are cached by file content hash; neither the cache nor the report
  ever contains a detected value, only its type, line, confidence and a masked preview.
- **`mask-add`** - adds chosen files to Claude IDE Box's masks for the project (in
  `~/.config/claude-ide-box/projects/<container>.conf`, never in the project), so the agent's
  container sees them as empty files.
- **Reversible pseudonymisation** - replaces values with tokens such as `[PERSON_1]` or `[IBAN_1]` in
  the copy the agent works on, keeps the token map on the host (mode 600, never mounted into the
  agent's container), and puts the real values back before the changes reach your files.
  Restoration is strict: only exact, known tokens are replaced; unknown or altered tokens are
  reported and nothing is guessed.

Everything runs in a throw-away container with `--network none`, a read-only root file system, no
capabilities and your UID. The model is baked into the image when it is built; at run time nothing
can be downloaded or sent anywhere. CPU only. The image is 0.9-1.4 GB (measured, see
[TESTING.md](TESTING.md)), so it is an optional add-on and never part of the Claude IDE Box base image.

## How detection works

Three layers, no single technique:

| Layer | Finds | Precision | Recall |
|---|---|---|---|
| Checksums | IBAN (mod 97), payment cards (Luhn + issuer prefix), PESEL (with date), NIP, REGON, Polish ID card and passport, German Steuer-ID, Spanish DNI/NIE, Italian codice fiscale, French NIR, Dutch BSN, Swedish personnummer, Finnish HETU, Belgian national number; US SSN (format rules - it has no check digit) | very high | high for the formats it knows |
| Patterns with context | e-mail, phone numbers (international format, or a local number after "tel."), dates of birth (a date after "ur.", "born", "geb."...), street addresses and Polish postcodes | high | depends on how the text is written |
| Your lists | client names, project code names - `~/.config/pii-airgap/lists/*.txt`, one `term` or `TYPE: term` per line | exact | exactly what you list |
| NER model | names, organisations, places | see below | see below |

Weak checksums (NIP, REGON, BSN, ID card and passport numbers, Steuer-ID) only count when a context
word is nearby ("NIP", "REGON", "BSN", "dowód"...), because about one random number in ten passes
them. Lists live outside any scanned folder: an agent that can edit the project must not be able
to edit what is looked for.

### Measured quality

On a synthetic labelled corpus (215 documents: Polish 75, English 70, German 70; every name,
company and number is invented - [eval/](eval/)). A prediction counts when it overlaps a labelled
entity of the same type. "Masked" is the share of labelled characters covered by any finding, i.e.
what pseudonymisation would actually hide.

With the default image (spaCy `xx_ent_wiki_sm`):

| Type | Labelled | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| PERSON | 150 | 145 | 16 | 90.1 | 96.7 |
| ORG | 75 | 39 | 10 | 79.6 | 52.0 |
| LOCATION | 99 | 97 | 48 | 66.9 | 98.0 |
| ADDRESS | 53 | 48 | 0 | 100.0 | 90.6 |
| DOB | 32 | 32 | 0 | 100.0 | 100.0 |
| EMAIL | 36 | 36 | 0 | 100.0 | 100.0 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| PESEL / NIP / REGON / ID card | 7 / 6 / 6 / 6 | 6 / 6 / 6 / 6 | 0 | 100.0 | 85.7 / 100 / 100 / 100 |
| SSN / TAXID | 7 / 7 | 6 / 7 | 0 | 100.0 | 85.7 / 100 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| Polish | 82.2 | 87.6 | 92.7 |
| English | 92.9 | 91.8 | 94.7 |
| German | 88.0 | 92.3 | 94.1 |

Without a model (`NER=none`) names, organisations and places are only found through your lists:
masked characters drop to 51 % (Polish), 46 % (English) and 44 % (German); everything else is
unchanged ([eval/results-none.md](eval/results-none.md)).

**How to read these numbers.** The templates were written by the same person as the rules, so the
checksum and pattern rows are optimistic: every miss in those rows comes from the handful of
"hard" sentences that were added afterwards without tuning the rules (a lower-case IBAN, a PESEL
with a stray space, an SSN without dashes, a UK mobile number, a German postcode, an inflected
Polish street name). Real documents
will do worse. The NER rows are a fairer picture of the model, but the corpus is small and
synthetic.

**GLiNER** (`pii-airgap build --ner gliner`, model `urchade/gliner_multi-v2.1`), measured by CI
inside the image without network ([eval/results-gliner-urchade-gliner_multi-v2.1.md](eval/results-gliner-urchade-gliner_multi-v2.1.md)):

| | Polish | English | German | ORG recall | PERSON recall | Speed |
|---|---:|---:|---:|---:|---:|---:|
| spaCy `xx_ent_wiki_sm` (default) - masked characters % | 92.7 | 94.7 | 94.1 | 52.0 | 96.7 | 2.5 ms/doc |
| GLiNER `gliner_multi-v2.1` - masked characters % | 98.3 | 99.0 | 98.4 | 92.0 | 100.0 | 178 ms/doc |

GLiNER finds clearly more, mostly organisations, at about 70 times the CPU time and with more false
dates of birth (13). It is not the default yet only because the licence of its weights has not been
checked on the model card (see [docs/MODELS.md](docs/MODELS.md)).

## Quick start

### On its own

```sh
docker build -f image/Dockerfile -t pii-airgap .          # NER=spacy by default
docker run --rm --network none --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
  -v "$PWD:$PWD:ro" pii-airgap scan "$PWD" --no-cache
```

or with the wrapper, which adds the cache, your lists and every isolation flag:

```sh
ln -s "$PWD/bin/pii-airgap" ~/.local/bin/pii-airgap
pii-airgap build                      # --ner gliner | spacy | none
cd ~/work/some-project && pii-airgap scan
pii-airgap scan --json > report.json  # machine-readable; --fail-on-pii exits 3 when anything is found
```

Pseudonymise a copy and restore it later (in place - never run it on your only copy):

```sh
cp -R project /tmp/project-copy
pii-airgap anonymise /tmp/project-copy --map ~/private/project.map.json --git strip
# ... work on /tmp/project-copy ...
pii-airgap restore /tmp/project-copy --map ~/private/project.map.json --base project
```

`anonymise` refuses (exit 3, nothing changed) when it would be unsafe: git metadata (its history
holds the original values and cannot be rewritten), a document with personal data that it cannot
rewrite in place (DOCX, PDF, scans... - mask or remove those), personal data in a file name, a
non-UTF-8 text file that seems to hold personal data, or text that already looks like a token.

### With Claude IDE Box

```sh
pii-airgap scan                         # what is in this project?
pii-airgap mask-add docs/contract.docx  # hide documents completely
claude-ide-box up --recreate            # masks apply when the container is created
```

Pseudonymised sessions build on Claude IDE Box's `up --try` mode (Claude works on a copy of the
project). The hooks below are proposed for Claude IDE Box and not merged yet; until then the two
steps can be run by hand around a try session (`pii-airgap try-prepare DIR` right after the copy is
made and before the container starts, `pii-airgap try-restore DIR` before `try apply`):

```text
claude-ide-box up --try --pseudonymise
    copy the project -> pii-airgap try-prepare (scan, then tokens in the copy, .git removed)
    -> start the container with an appended system prompt (below)
claude-ide-box try diff | apply | end
    stop the container -> pii-airgap try-restore (strict) -> compare and apply as usual
```

A failed `try-prepare` stops the session before the container starts; a failed `try-restore` stops
`apply` and leaves your files untouched.

## Telling the agent that tokens are immutable

The wrapper appends `pii-airgap system-prompt` to the agent's system prompt (Claude Code:
`--append-system-prompt`). In short: copy `[TYPE_N]` tokens character for character, never invent,
inflect, split, translate or decode them, never write code that parses them, and use obviously
fictional data that does not look like a token when examples are needed.

What can still go wrong, even with that prompt:

- **Altered tokens** - `[person_1]`, `[PERSON 1]`, `PERSON_1`, escaped brackets in a regex or JSON
  string. Restoration reports them (file and line) and writes nothing until you fix them or pass
  `--keep-unresolved`.
- **Invented tokens** - `[PERSON_7]` that was never issued. Reported as unknown, never guessed.
- **Valid tokens in the wrong place** - the agent copies `[PERSON_1]` into a log message, a test
  fixture or a commit message. It is a known token, so it is restored there, and the real value ends
  up in a new place. Review the diff (`try diff` shows the restored text).
- **Meaning lost** - Polish inflection (`Kowalski` / `Kowalskiego` are different tokens), the
  agent cannot see that two tokens are the same person, cannot check a checksum, compute an age
  from a date of birth or validate a format. Code that depends on real values has to be tested on
  the host, after restoration.
- **Misses** - anything not detected stays in clear text in the copy and is sent to the provider.
- **Things outside the copy** - the agent's own conversation history, prompts you type, files you
  paste into the chat and tool output from allowlisted network services are not pseudonymised.

## Security model

- The scanner parses untrusted files (PDF, Office, images). It runs with no network, a read-only
  root, no capabilities, your UID, memory and process limits, and the project mounted read-only.
  The token map is never mounted into it.
- The pseudonymiser and the restorer see the map, but run only pii-airgap's own Python (no PDF,
  Office or OCR code) on plain text files, with no network.
- The map lives in `~/.local/state/pii-airgap/` (directory 700, file 600), outside anything the
  agent's container can see.
- A compromised scanner could lie (report "no PII"). That is the same outcome as a miss and is
  stated above; it cannot reach the network or the map.

More: [SECURITY.md](SECURITY.md), [docs/DESIGN.md](docs/DESIGN.md).

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md) - architecture, data flow, decisions
- [docs/MODELS.md](docs/MODELS.md) - NER candidates, licences, languages, what was verified
- [TESTING.md](TESTING.md) - what is tested, where, and what is not
- [CONTRIBUTING.md](CONTRIBUTING.md)

## Licence

Apache License 2.0, see [LICENSE](LICENSE). Models and tools installed into the image keep their own
licences (spaCy and `xx_ent_wiki_sm`: MIT, trained on WikiNER, CC BY 4.0; GLiNER: see
[docs/MODELS.md](docs/MODELS.md); LibreOffice: MPL 2.0; poppler: GPL; Tesseract: Apache 2.0).
