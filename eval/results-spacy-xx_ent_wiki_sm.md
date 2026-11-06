Corpus: 230 documents (pl 83, en 74, de 73), NER: spacy:xx_ent_wiki_sm, 2.3 ms per document

| Type | Gold | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| ADDRESS | 53 | 48 | 0 | 100.0 | 90.6 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| DOB | 32 | 32 | 0 | 100.0 | 100.0 |
| EMAIL | 41 | 41 | 0 | 100.0 | 100.0 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| IDCARD | 6 | 6 | 0 | 100.0 | 100.0 |
| LOCATION | 107 | 102 | 52 | 66.2 | 95.3 |
| NIP | 6 | 6 | 0 | 100.0 | 100.0 |
| ORG | 84 | 45 | 12 | 78.9 | 53.6 |
| PERSON | 170 | 157 | 17 | 90.2 | 92.4 |
| PESEL | 7 | 6 | 0 | 100.0 | 85.7 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| REGON | 6 | 6 | 0 | 100.0 | 100.0 |
| SSN | 7 | 6 | 0 | 100.0 | 85.7 |
| TAXID | 7 | 7 | 0 | 100.0 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| pl | 82.4 | 86.9 | 92.2 |
| en | 91.2 | 90.3 | 95.0 |
| de | 88.3 | 89.6 | 92.7 |

Field cases (from the end-to-end test): 31 values fully masked, 4 partly, 7 missed; 2 false findings

| Case | Language | Result |
|---|---|---|
| field-00 | pl | all masked |
| field-01 | pl | **missed** ORG `Bursztynowe Okna Sp. z o.o.` |
| field-02 | pl | partly ORG `Wiślańska Logistyka sp. z o.o.` |
| field-03 | pl | all masked |
| field-04 | pl | all masked |
| field-05 | en | false LOCATION `Email` |
| field-06 | en | partly ORG `Ashford Robotics Inc.` |
| field-07 | en | all masked |
| field-08 | de | **missed** PERSON `Lukas`; **missed** PERSON `Schmidt`; **missed** LOCATION `Berlin`; **missed** PERSON `Hannah`; **missed** PERSON `Weber`; **missed** LOCATION `Köln` |
| field-09 | de | partly ORG `Nordwind Handels GmbH` |
| field-10 | de | partly ORG `Alpenblick Software GmbH` |
| field-11 | pl | false LOCATION `Stanowisko` |
| field-12 | pl | all masked |
| field-13 | pl | all masked |
| field-14 | en | all masked |
