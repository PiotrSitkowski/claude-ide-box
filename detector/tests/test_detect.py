import unittest

from pii_airgap.detect import Detector, Finding, parse_list_file


def spans(findings):
    return [(f.type, f.text) for f in findings]


class DeterministicTests(unittest.TestCase):
    def setUp(self):
        self.d = Detector()

    def found(self, text):
        return spans(self.d.detect(text))

    def test_email_phone_iban_with_exact_spans(self):
        text = "Kontakt: anna.nowak@example.com, tel. +48 601 234 567, konto PL61 1090 1014 0000 0712 1981 2874."
        got = self.d.detect(text)
        self.assertIn(("EMAIL", "anna.nowak@example.com"), spans(got))
        self.assertIn(("PHONE", "+48 601 234 567"), spans(got))
        self.assertIn(("IBAN", "PL61 1090 1014 0000 0712 1981 2874"), spans(got))
        for f in got:
            self.assertEqual(text[f.start:f.end], f.text)

    def test_bad_checksums_are_not_reported(self):
        self.assertEqual(self.found("konto PL61 1090 1014 0000 0712 1981 2875"), [])
        self.assertEqual(self.found("zamówienie nr 44051401358"), [])
        self.assertEqual(self.found("card 4111 1111 1111 1112"), [])

    def test_pesel_and_card(self):
        self.assertIn(("PESEL", "44051401359"), self.found("PESEL 44051401359"))
        self.assertIn(("PESEL", "44051401359"), self.found("klient 44051401359 zgłosił"))
        self.assertIn(("CARD", "4111 1111 1111 1111"), self.found("Visa 4111 1111 1111 1111 exp 12/29"))

    def test_digits_inside_longer_numbers_are_ignored(self):
        self.assertEqual(self.found("ref 1244051401359"), [])
        self.assertEqual(self.found("ref 440514013591"), [])

    def test_weak_checksums_need_context(self):
        self.assertIn(("NIP", "123-456-32-18"), self.found("NIP: 123-456-32-18"))
        self.assertIn(("NIP", "1234563218"), self.found("Steuernummer / NIP 1234563218"))
        self.assertEqual(self.found("order 1234563218 shipped"), [])
        self.assertIn(("REGON", "123456785"), self.found("REGON 123456785"))
        self.assertEqual(self.found("invoice 123456785"), [])
        self.assertIn(("NATIONALID", "111222333"), self.found("BSN: 111222333"))
        self.assertEqual(self.found("artikel 111222333"), [])

    def test_national_ids_of_other_countries(self):
        self.assertIn(("SSN", "123-45-6789"), self.found("SSN 123-45-6789"))
        self.assertIn(("TAXID", "86095742719"), self.found("Steuer-ID: 86095742719"))
        self.assertIn(("NATIONALID", "12345678Z"), self.found("DNI 12345678Z"))
        self.assertIn(("TAXID", "RSSMRA85T10A562S"), self.found("CF RSSMRA85T10A562S"))
        self.assertIn(("IDCARD", "ABA300000"), self.found("dowód osobisty ABA300000"))
        self.assertIn(("PASSPORT", "EA1234567"), self.found("paszport EA1234567"))

    def test_date_of_birth_needs_a_birth_keyword(self):
        self.assertIn(("DOB", "14.05.1944"), self.found("Jan, ur. 14.05.1944 w Radomiu"))
        self.assertIn(("DOB", "14 May 1944"), self.found("date of birth: 14 May 1944"))
        self.assertIn(("DOB", "14. Mai 1944"), self.found("geboren am 14. Mai 1944"))
        self.assertEqual(self.found("faktura z dnia 14.05.2024"), [])

    def test_addresses(self):
        got = self.found("Adres: ul. Długa 15/3, 00-950 Warszawa")
        self.assertIn(("ADDRESS", "ul. Długa 15/3"), got)
        self.assertIn(("ADDRESS", "00-950 Warszawa"), got)
        self.assertIn(("ADDRESS", "Hauptstraße 12"), self.found("wohnt in der Hauptstraße 12 in Köln"))
        self.assertIn(("ADDRESS", "221 Baker Street"), self.found("lives at 221 Baker Street, London"))

    def test_phone_needs_international_prefix_or_context(self):
        self.assertIn(("PHONE", "601 234 567"), self.found("tel. 601 234 567"))
        self.assertEqual(self.found("kod 601 234 567"), [])
        self.assertIn(("PHONE", "+49 30 1234567"), self.found("Telefon +49 30 1234567"))


class ListAndNerTests(unittest.TestCase):
    def test_user_list_whole_words_case_insensitive(self):
        d = Detector(lists=[("CLIENT", "Acme Sp. z o.o."), ("PROJECT", "Bluebird")])
        got = spans(d.detect("Umowa z ACME sp. z o.o. w projekcie bluebird. Acmeville, Bluebirds."))
        self.assertIn(("CLIENT", "ACME sp. z o.o."), got)
        self.assertIn(("PROJECT", "bluebird"), got)
        self.assertEqual(len(got), 2)

    def test_list_file_format(self):
        entries, errors = parse_list_file("# comment\nAcme Corp\nPROJECT: Bluebird\n\nbad type!: x\n")
        self.assertEqual(entries, [("CUSTOM", "Acme Corp"), ("PROJECT", "Bluebird")])
        self.assertEqual(len(errors), 1)

    def test_ner_backend_is_merged_and_loses_overlaps(self):
        text = "Jan Kowalski, PESEL 44051401359, Kraków"

        def fake_ner(t):
            return [Finding(0, 12, "PERSON", "ner:person", 0.91, "ner"),
                    Finding(14, 31, "PERSON", "ner:person", 0.55, "ner"),
                    Finding(33, 39, "LOCATION", "ner:location", 0.8, "ner")]

        got = spans(Detector(ner=fake_ner).detect(text))
        self.assertEqual(got, [("PERSON", "Jan Kowalski"), ("PESEL", "44051401359"), ("LOCATION", "Kraków")])

    def test_findings_have_confidence_and_source(self):
        f = Detector(lists=[("CLIENT", "Acme")]).detect("PESEL 44051401359 Acme")
        by = {x.type: x for x in f}
        self.assertGreaterEqual(by["PESEL"].confidence, 0.95)
        self.assertEqual(by["PESEL"].source, "checksum")
        self.assertEqual(by["CLIENT"].source, "list")


if __name__ == "__main__":
    unittest.main()
