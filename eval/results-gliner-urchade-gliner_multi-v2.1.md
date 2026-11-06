Corpus: 230 documents (pl 83, en 74, de 73), NER: gliner, 225.5 ms per document

| Type | Gold | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| ADDRESS | 53 | 49 | 1 | 98.0 | 92.5 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| DOB | 32 | 32 | 14 | 69.6 | 100.0 |
| EMAIL | 41 | 41 | 0 | 100.0 | 100.0 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| IDCARD | 6 | 6 | 0 | 100.0 | 100.0 |
| LOCATION | 107 | 107 | 8 | 93.0 | 100.0 |
| NIP | 6 | 6 | 0 | 100.0 | 100.0 |
| ORG | 84 | 78 | 0 | 100.0 | 92.9 |
| PERSON | 170 | 170 | 0 | 100.0 | 100.0 |
| PESEL | 7 | 6 | 0 | 100.0 | 85.7 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| REGON | 6 | 6 | 0 | 100.0 | 100.0 |
| SSN | 7 | 6 | 0 | 100.0 | 85.7 |
| TAXID | 7 | 7 | 0 | 100.0 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| pl | 99.1 | 98.2 | 98.5 |
| en | 95.5 | 97.4 | 99.0 |
| de | 93.9 | 96.4 | 98.5 |

Field cases (from the end-to-end test): 42 values fully masked, 0 partly, 0 missed; 1 false findings

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
| field-12 | pl | false DOB `1 marca` |
| field-13 | pl | all masked |
| field-14 | en | all masked |
