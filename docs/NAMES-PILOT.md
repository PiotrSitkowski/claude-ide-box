# Name dictionary pilot (Polish and English)

A fourth detection layer: registry given names and surnames, Polish inflection, and rules for when
a capitalised word next to a known given name is a person (`detector/pii_airgap/names.py`). Off by
default; this page holds the numbers the decision to turn it on is taken from.

## Sources

All listed in [`names/sources.json`](../names/sources.json) with URL, licence as checked at the
source on 2026-11-07, and checksum. Nothing from them is stored in git; the image build downloads
and verifies them.

| Source | Licence | Used for |
|---|---|---|
| PESEL given names and surnames, as of 2025-01-22 (dane.gov.pl datasets 1667 and 568) | CC0 1.0 | Polish names and frequencies |
| 1990 U.S. Census first names, 2010 U.S. Census surnames | public domain (17 U.S.C. 105; census.gov states no licence on the pages) | English names and frequencies |
| PoliMorf 0.6.7 | BSD-2-Clause | Polish inflected forms of names; Polish common nouns spelt like a name |
| Wikidata labels in pl/en | CC0 1.0 | extra names without frequency; not checksummable, left out of the image by default |

Not used: U.S. SSA baby names (www.ssa.gov answered 403 to automated downloads from the build
environment); datasets built from leaks.

## Size

| | Database | Image (`NER=none`) |
|---|---|---|
| without the layer | - | 897 MB |
| `NAMES=dict` (PoliMorf forms stored) | 7.3 MB | 907 MB (+10 MB) |
| `NAMES=rules` (forms derived from ending rules) | 5.5 MB | 904 MB (+7 MB) |

Stored forms grow the database by a factor of 1.33, under the 3x limit set for the pilot. With
Wikidata the databases are 7.7 and 5.9 MB.

## Results

Synthetic corpus `eval/corpus.jsonl` (Polish 83, English 74 documents) and the false-alarm corpus
`eval/code-corpus.json`: source code of 9 permissively licensed packages (requests, flask, express,
lodash, rxjs, cobra, gin, regex, serde - Python, JavaScript, TypeScript, Go, Rust; 2602 files,
6.9 million characters). A PERSON finding in the code corpus counts as a false alarm unless its
line is an attribution (copyright, author, ...).

| NER | Dictionary | Masked PL % | Masked EN % | PERSON PL % | PERSON EN % | Code: PERSON false alarms | ms per document |
|---|---|---:|---:|---:|---:|---:|---:|
| none | - | 64.2 | 53.9 | 6.6 | 5.2 | 0 | 0.1 |
| none | dict | 86.6 | 77.4 | 94.9 | 95.7 | 125 | 0.1 |
| spaCy | - | 96.1 | 97.5 | 98.4 | 99.7 | 7289 | 1.9 |
| spaCy | dict | 96.4 | 97.9 | 99.6 | 99.7 | 7363 | 2.0 |
| GLiNER | - | *running* | | | | | |
| GLiNER | dict | *running* | | | | | |

The spaCy rows were measured in the development sandbox and again in CI, with the same numbers.
With Wikidata added, spaCy + dictionary reaches 98.2 % in English (+0.3) and 7375 false alarms.
`NAMES=rules` gives the same English numbers and 96.1 % in Polish (the forms in the dictionary
are worth 0.3 points there).

**How to read these numbers.** The synthetic corpus draws its people from lists of common Polish
and English names, which are all in the registries, so the dictionary rows are optimistic for
names. The share of characters the layer adds on its own (64.2 -> 86.6 % in Polish) is real, but on
top of a NER model the ceiling is close: spaCy already masks 98.4 % of Polish and 99.7 % of
English person characters here.
