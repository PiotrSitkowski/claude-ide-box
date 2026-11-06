# NER models: candidates, licences, languages

The model decides how many names, organisations and places are found. It is chosen on licence and
measured quality per language, not on reputation. This page records what was checked, from which
source, and what could not be checked.

**Verification environment.** The project was developed in a sandbox whose network allowed GitHub
and PyPI but blocked huggingface.co, arxiv.org and download.pytorch.org. Facts marked
"verified" come from a primary source that was reachable (a LICENSE file in the project's own
repository, package metadata on PyPI, model metadata in `explosion/spacy-models`). Facts marked
"not verified" come from search results or third-party mirrors and must be checked on the model
card before a release that ships the model.

## Candidates

| Candidate | Code licence | Weights licence | Languages | Status |
|---|---|---|---|---|
| **spaCy `xx_ent_wiki_sm` 3.8.0** (PER, ORG, LOC, MISC) | MIT (spaCy) | MIT, trained on WikiNER (CC BY 4.0) - **verified** in `explosion/spacy-models/meta/xx_ent_wiki_sm-3.8.0.json` | multilingual WikiNER (includes Polish, German, English) | **default**; measured below |
| **GLiNER `urchade/gliner_multi-v2.1`** (zero-shot labels) | Apache-2.0 - **verified** (`urchade/GLiNER` LICENSE; `gliner` 0.2.30 on PyPI) | Apache-2.0 per third-party mirrors - **not verified** (model card on huggingface.co unreachable) | multilingual (mDeBERTa-v3 encoder) | supported (`--ner gliner`); measured in CI, below |
| `urchade/gliner_multi` (v0) | Apache-2.0 | CC BY-NC 4.0 per search results - **not verified** | multilingual | excluded: non-commercial |
| `urchade/gliner_multi_pii-v1` | Apache-2.0 | **not verified** | card lists en, fr, de, es, pt, it - **not verified**; no Polish listed | not used |
| `fastino/gliner2-privacy-filter-PII-multi` (GLiNER2, 205M, 42 PII types, arXiv 2605.09973) | Apache-2.0 - **verified** (`fastino-ai/GLiNER2` LICENSE) | Apache-2.0 per a third-party copy - **not verified** | multilingual per the paper - **not verified** (arXiv unreachable) | promising next candidate; needs the `gliner2` package (different API), not implemented |
| `Davlan/xlm-roberta-base-ner-hrl` (XLM-R, PER/ORG/LOC) | - | AFL-3.0 per search results - **not verified** | ar, de, en, es, fr, it, lv, nl, pt, zh - **no Polish** | excluded: no Polish |
| `Babelscape/wikineural-multilingual-ner` (mBERT) | - | reported as CC BY-NC-SA 4.0 - **not verified** | 9 languages incl. Polish | excluded until verified (likely non-commercial) |
| spaCy `pl_core_news_lg` 3.8.0 | MIT (spaCy) | **GNU GPL 3.0** (trained on NKJP and UD PDB, GPL) - **verified** in its meta JSON | Polish | not shipped in an Apache-2.0 image; a user may build it for their own use |
| spaCy `de_core_news_lg`, `en_core_web_lg` 3.8.0 | MIT | MIT - **verified** | one language each | possible per-language add-ons |
| Microsoft Presidio (framework) | MIT - **verified** (`microsoft/presidio` LICENSE) | uses spaCy, stanza, transformers or GLiNER models | per model | not used as the framework, see below |

## Why not Presidio as the framework

Presidio (`presidio-analyzer` 2.2.366 on PyPI) is a good framework, but here it would add more than
it gives:

- it needs an NLP engine model per language even when only regex recognisers are used, and the
  analyzer pulls in spaCy, `tldextract`, `phonenumbers` and more; `tldextract` refreshes the public
  suffix list over the network unless configured otherwise, which has to be turned off and tested
  in an air-gapped image;
- the checksum layer pii-airgap needs (Polish identifiers with context words, IBAN, cards, a dozen
  national IDs) is about 300 lines of standard-library Python with unit tests per check digit;
- pseudonymisation here is reversible and strict, which Presidio's anonymizer operators do not do
  out of the box, so that part would be custom anyway.

Presidio recognisers can still be added later as another detection source if a country's
identifier is missing here.

## Measured: spaCy `xx_ent_wiki_sm`

On the synthetic corpus ([eval/](../eval/), 215 documents), together with the checksum and pattern
layers ([eval/results-spacy-xx_ent_wiki_sm.md](../eval/results-spacy-xx_ent_wiki_sm.md)):

| Type | Precision % | Recall % |
|---|---:|---:|
| PERSON | 90.1 | 96.7 |
| ORG | 79.6 | 52.0 |
| LOCATION | 66.9 | 98.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| Polish | 82.2 | 87.6 | 92.7 |
| English | 92.9 | 91.8 | 94.7 |
| German | 88.0 | 92.3 | 94.1 |

Observed weaknesses: many organisation names are tagged MISC (not used) or missed, city names
inside organisation names become LOCATION false positives, and German nouns at the start of a line
("Ansprechpartner") can become PERSON. 2.2-2.5 ms per short document on one CPU core.

## Measured: GLiNER `urchade/gliner_multi-v2.1`

Built and evaluated by CI (GitHub Actions, revision `main` at the time, CPU), inside the image under
`--network none` ([eval/results-gliner-urchade-gliner_multi-v2.1.md](../eval/results-gliner-urchade-gliner_multi-v2.1.md)):

| Type | Precision % | Recall % |
|---|---:|---:|
| PERSON | 100.0 | 100.0 |
| ORG | 100.0 | 92.0 |
| LOCATION | 92.5 | 100.0 |
| DOB | 71.1 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| Polish | 99.5 | 98.0 | 98.3 |
| English | 95.2 | 97.3 | 99.0 |
| German | 93.6 | 96.2 | 98.4 |

178.5 ms per short document (spaCy: 2.5 ms). The "date of birth" label adds 13 false positives
(ordinary dates); that costs readability, not privacy. Loading needs `protobuf` 7 and
`sentencepiece`, and the container's UID has no passwd entry, so the image sets `USER`/`LOGNAME`;
the build-time self-test runs as such a UID.

## Choosing the default

1. Check the weights licence of `urchade/gliner_multi-v2.1` (and of the GLiNER2 PII model) on their
   model cards; pin `GLINER_REVISION` to a commit.
2. Done: on this corpus GLiNER is better in every language, Polish most of all.
3. If the licence checks out, switch `ARG NER` and `pii-airgap build` to `gliner`, pin
   `GLINER_REVISION`, and decide whether 70 times the CPU time is acceptable (or keep spaCy for
   quick scans and GLiNER for `try-prepare`).
