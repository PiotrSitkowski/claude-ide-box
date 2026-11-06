Corpus: 230 documents (pl 83, en 74, de 73), NER: spacy:xx_ent_wiki_sm, 2.5 ms per document

| Type | Gold | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| ADDRESS | 53 | 48 | 0 | 100.0 | 90.6 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| DOB | 32 | 32 | 0 | 100.0 | 100.0 |
| EMAIL | 41 | 41 | 0 | 100.0 | 100.0 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| IDCARD | 6 | 6 | 0 | 100.0 | 100.0 |
| LOCATION | 107 | 105 | 30 | 77.8 | 98.1 |
| NIP | 6 | 6 | 0 | 100.0 | 100.0 |
| ORG | 84 | 63 | 10 | 86.3 | 75.0 |
| PERSON | 170 | 165 | 25 | 86.8 | 97.1 |
| PESEL | 7 | 6 | 0 | 100.0 | 85.7 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| REGON | 6 | 6 | 0 | 100.0 | 100.0 |
| SSN | 7 | 6 | 0 | 100.0 | 85.7 |
| TAXID | 7 | 7 | 0 | 100.0 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| pl | 86.9 | 93.2 | 96.1 |
| en | 93.4 | 93.9 | 97.5 |
| de | 89.6 | 93.8 | 95.6 |

Field cases (from the end-to-end test): 42 values fully masked, 0 partly, 0 missed; 0 false findings

| Case | Language | Result |
|---|---|---|
| field-00 | pl | all masked |
| field-01 | pl | all masked |
| field-02 | pl | all masked |
| field-03 | pl | all masked |
| field-04 | pl | all masked |
| field-05 | en | all masked |
| field-06 | en | all masked |
| field-07 | en | all masked |
| field-08 | de | all masked |
| field-09 | de | all masked |
| field-10 | de | all masked |
| field-11 | pl | all masked |
| field-12 | pl | all masked |
| field-13 | pl | all masked |
| field-14 | en | all masked |
