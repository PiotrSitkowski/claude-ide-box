Corpus: 230 documents (pl 83, en 74, de 73), NER: none, 0.1 ms per document

| Type | Gold | Found | False positives | Precision % | Recall % |
|---|---:|---:|---:|---:|---:|
| ADDRESS | 53 | 48 | 0 | 100.0 | 90.6 |
| CARD | 19 | 19 | 0 | 100.0 | 100.0 |
| DOB | 32 | 32 | 0 | 100.0 | 100.0 |
| EMAIL | 41 | 41 | 0 | 100.0 | 100.0 |
| IBAN | 26 | 25 | 0 | 100.0 | 96.2 |
| IDCARD | 6 | 6 | 0 | 100.0 | 100.0 |
| LOCATION | 107 | 0 | 0 | - | 0.0 |
| NIP | 6 | 6 | 0 | 100.0 | 100.0 |
| ORG | 84 | 0 | 0 | - | 0.0 |
| PERSON | 170 | 0 | 0 | - | 0.0 |
| PESEL | 7 | 6 | 0 | 100.0 | 85.7 |
| PHONE | 39 | 36 | 0 | 100.0 | 92.3 |
| REGON | 6 | 6 | 0 | 100.0 | 100.0 |
| SSN | 7 | 6 | 0 | 100.0 | 85.7 |
| TAXID | 7 | 7 | 0 | 100.0 | 100.0 |

| Language | Precision % | Recall % | Masked characters % |
|---|---:|---:|---:|
| pl | 100.0 | 45.2 | 48.6 |
| en | 100.0 | 35.7 | 44.4 |
| de | 100.0 | 35.2 | 42.6 |

Field cases (from the end-to-end test): 5 values fully masked, 0 partly, 37 missed; 0 false findings

| Case | Language | Result |
|---|---|---|
| field-00 | pl | **missed** PERSON `Anna Nowak`; **missed** LOCATION `Kraków`; **missed** PERSON `Jan Kowalski`; **missed** LOCATION `Gdańsk`; **missed** PERSON `Zofia Wiśniewska`; **missed** LOCATION `Lublin` |
| field-01 | pl | **missed** PERSON `Jan Kowalski`; **missed** ORG `Bursztynowe Okna Sp. z o.o.` |
| field-02 | pl | **missed** ORG `Wiślańska Logistyka sp. z o.o.`; **missed** PERSON `Janem Kowalskim` |
| field-03 | pl | **missed** PERSON `Agnieszką Kamińską` |
| field-04 | pl | **missed** LOCATION `Poznaniu`; **missed** ORG `Mazowiecki Dom Mediowy S.A.` |
| field-05 | en | **missed** PERSON `Mary Johnson`; **missed** LOCATION `Boston`; **missed** PERSON `David Miller`; **missed** LOCATION `Denver` |
| field-06 | en | **missed** PERSON `John Smith`; **missed** ORG `Ashford Robotics Inc.` |
| field-07 | en | **missed** ORG `Harbor & Pine LLP`; **missed** ORG `Crescent Valley Bank Ltd` |
| field-08 | de | **missed** PERSON `Lukas`; **missed** PERSON `Schmidt`; **missed** LOCATION `Berlin`; **missed** PERSON `Hannah`; **missed** PERSON `Weber`; **missed** LOCATION `Köln` |
| field-09 | de | **missed** PERSON `Jonas Becker`; **missed** ORG `Nordwind Handels GmbH` |
| field-10 | de | **missed** ORG `Bergmann & Söhne KG`; **missed** ORG `Alpenblick Software GmbH` |
| field-11 | pl | **missed** PERSON `Ewa Lis`; **missed** PERSON `Jan Bąk`; **missed** PERSON `Ola Kot` |
| field-12 | pl | all masked |
| field-13 | pl | **missed** PERSON `Jan Kowalski` |
| field-14 | en | **missed** PERSON `Amy Lee`; **missed** PERSON `Bo Ng` |
