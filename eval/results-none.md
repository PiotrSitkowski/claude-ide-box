Corpus: 230 documents (pl 83, en 74, de 73), NER: none, 0.1 ms per document

| Type | Gold | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| ADDRESS | 53 | 48 | 0 | 100.0 | 90.6 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| DOB | 32 | 32 | 0 | 100.0 | 100.0 |
| EMAIL | 41 | 41 | 0 | 100.0 | 100.0 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| IDCARD | 6 | 6 | 0 | 100.0 | 100.0 |
| LOCATION | 107 | 7 | 0 | 100.0 | 6.5 |
| NIP | 6 | 6 | 0 | 100.0 | 100.0 |
| ORG | 84 | 49 | 0 | 100.0 | 58.3 |
| PERSON | 170 | 14 | 0 | 100.0 | 8.2 |
| PESEL | 7 | 6 | 0 | 100.0 | 85.7 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| REGON | 6 | 6 | 0 | 100.0 | 100.0 |
| SSN | 7 | 6 | 0 | 100.0 | 85.7 |
| TAXID | 7 | 7 | 0 | 100.0 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| pl | 100.0 | 57.9 | 64.2 |
| en | 100.0 | 44.4 | 53.9 |
| de | 100.0 | 48.2 | 59.3 |

Field cases (from the end-to-end test): 35 values fully masked, 0 partly, 7 missed; 0 false findings

| Case | Language | Result |
|---|---|---|
| field-00 | pl | all masked |
| field-01 | pl | **missed** PERSON `Jan Kowalski` |
| field-02 | pl | **missed** PERSON `Janem Kowalskim` |
| field-03 | pl | **missed** PERSON `Agnieszką Kamińską` |
| field-04 | pl | **missed** LOCATION `Poznaniu` |
| field-05 | en | all masked |
| field-06 | en | **missed** PERSON `John Smith` |
| field-07 | en | all masked |
| field-08 | de | all masked |
| field-09 | de | **missed** PERSON `Jonas Becker` |
| field-10 | de | all masked |
| field-11 | pl | all masked |
| field-12 | pl | all masked |
| field-13 | pl | **missed** PERSON `Jan Kowalski` |
| field-14 | en | all masked |
