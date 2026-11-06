"""Rules added after the first end-to-end test with Claude IDE Box: people in
table columns, whole names around a model's partial match, company names
with their legal form, and capitalised first words of sentences."""

import os
import tempfile
import unittest
import zipfile

from pii_airgap.detect import Detector, Finding, sniff_delimiter
from pii_airgap.scan import scan_tree
from pii_airgap.tokens import TokenMap, anonymise_text, anonymise_tree


def spans(findings):
    return [(f.type, f.text) for f in findings]


def fake_ner(marks):
    """A model that finds exactly the (type, text) pairs given, wherever the
    text occurs (case-sensitive), like a model that relies on capitals."""

    def ner(text):
        out = []
        for t, s in marks:
            i = text.find(s)
            while i >= 0:
                out.append(Finding(i, i + len(s), t, "ner:fake", 0.8, "ner"))
                i = text.find(s, i + 1)
        return out

    ner.fingerprint = "fake"
    return ner


class TableTests(unittest.TestCase):
    def test_person_column_from_header_without_a_model(self):
        text = "imie_nazwisko,email,miasto\nAnna Nowak,anna@example.pl,Kraków\nJan Bąk,jan@example.pl,Gdańsk\n"
        got = spans(Detector().detect(text, table=","))
        self.assertIn(("PERSON", "Anna Nowak"), got)
        self.assertIn(("PERSON", "Jan Bąk"), got)
        self.assertIn(("EMAIL", "anna@example.pl"), got)
        self.assertNotIn(("PERSON", "Kraków"), got)
        self.assertNotIn(("PERSON", "imie_nazwisko"), got)

    def test_header_variants(self):
        for header, cell in (("Name", "Mary Johnson"), ("Full name", "Amy Lee"), ("Imię i nazwisko", "Ewa Lis"),
                             ("Nachname", "Schmidt"), ("Vorname", "Lukas"), ("last_name", "Miller"),
                             ("Ansprechpartner", "Jonas Becker"), ("pracownik", "Ola Kot")):
            text = "%s;Abteilung\n%s;sales\n" % (header, cell)
            self.assertIn(("PERSON", cell), spans(Detector().detect(text, table=";")), header)

    def test_other_name_columns_are_not_people(self):
        text = "Product name,Company name,File name\nWidget,Acme,report.pdf\n"
        self.assertEqual(spans(Detector().detect(text, table=",")), [])

    def test_quoted_cells_and_empty_cells(self):
        text = 'name,note\n"Kowalski, Jan","a, b"\n,empty name\n'
        got = Detector().detect(text, table=",")
        self.assertEqual(spans(got), [("PERSON", "Kowalski, Jan")])
        self.assertEqual(text[got[0].start:got[0].end], "Kowalski, Jan")

    def test_markdown_tables_inside_ordinary_text(self):
        text = "Lista:\n\n| Imię i nazwisko | Stanowisko |\n|---|---|\n| Ewa Lis | księgowa |\n| Jan Bąk | kierowca |\n\nKoniec."
        got = spans(Detector().detect(text))
        self.assertIn(("PERSON", "Ewa Lis"), got)
        self.assertIn(("PERSON", "Jan Bąk"), got)
        self.assertNotIn(("PERSON", "księgowa"), got)

    def test_a_blank_line_starts_a_new_table(self):
        text = "name\tx\nAmy Lee\t1\n\nproduct\tx\nWidget\t2\n"
        got = spans(Detector().detect(text, table="\t"))
        self.assertEqual(got, [("PERSON", "Amy Lee")])

    def test_model_matches_are_cut_at_line_breaks(self):
        d = Detector(ner=fake_ner([("LOCATION", "Gdańsk\nZofia")]))
        text = "miasto,x\nGdańsk\nZofia,y\n"
        self.assertIn(("LOCATION", "Gdańsk"), spans(d.detect(text, table=",")))

    def test_header_cells_are_never_findings(self):
        d = Detector(ner=fake_ner([("LOCATION", "Email"), ("PERSON", "Name")]))
        got = spans(d.detect("Name,Email\nAmy Lee,amy@example.com\n", table=","))
        self.assertEqual(got, [("PERSON", "Amy Lee"), ("EMAIL", "amy@example.com")])

    def test_place_and_address_columns(self):
        text = "miasto;adres;Ort\nGdańsk;ul. Długa 5;Köln\n"
        got = spans(Detector().detect(text, table=";"))
        self.assertEqual(got, [("LOCATION", "Gdańsk"), ("ADDRESS", "ul. Długa 5"), ("LOCATION", "Köln")])

    def test_sniff_delimiter(self):
        self.assertEqual(sniff_delimiter("a;b;c\n1;2;3\n"), ";")
        self.assertEqual(sniff_delimiter("a\tb\n"), "\t")
        self.assertEqual(sniff_delimiter("a,b\n"), ",")
        self.assertIsNone(sniff_delimiter("just text\n"))

    def test_csv_files_are_pseudonymised_as_tables(self):
        with tempfile.TemporaryDirectory() as t:
            root = os.path.join(t, "w")
            os.makedirs(root)
            with open(os.path.join(root, "people.csv"), "w") as f:
                f.write("Nachname;Vorname\nSchmidt;Lukas\n")
            anonymise_tree(root, os.path.join(t, "m.json"), Detector())
            with open(os.path.join(root, "people.csv")) as f:
                self.assertEqual(f.read(), "Nachname;Vorname\n[PERSON_1];[PERSON_2]\n")
        self.assertEqual(anonymise_text("name\nAmy Lee\n", Detector(), TokenMap(), table=","), "name\n[PERSON_1]\n")

    def test_xlsx_sheets_are_scanned_as_tables(self):
        with tempfile.TemporaryDirectory() as t:
            root = os.path.join(t, "p")
            os.makedirs(root)
            with zipfile.ZipFile(os.path.join(root, "staff.xlsx"), "w") as z:
                z.writestr("xl/sharedStrings.xml", "<sst><si><t>Imię i nazwisko</t></si><si><t>Ewa Lis</t></si></sst>")
                z.writestr("xl/worksheets/sheet1.xml", '<worksheet><sheetData><row><c t="s"><v>0</v></c></row>'
                                                       '<row><c t="s"><v>1</v></c></row></sheetData></worksheet>')
            rep = scan_tree(root, None, Detector())
            self.assertEqual(rep["files"][0]["counts"], {"PERSON": 1})


class PersonSpanTests(unittest.TestCase):
    def test_first_name_next_to_a_partial_match_is_included(self):
        d = Detector(ner=fake_ner([("PERSON", "Kowalski")]))
        self.assertEqual(spans(d.detect("Umowę podpisał Jan Kowalski wczoraj.")), [("PERSON", "Jan Kowalski")])

    def test_surname_after_a_partial_match_is_included(self):
        d = Detector(ner=fake_ner([("PERSON", "Jan")]))
        self.assertEqual(spans(d.detect("Jan Kowalski podpisał.")), [("PERSON", "Jan Kowalski")])

    def test_titles_stay_outside_the_name(self):
        for title in ("Pan", "Pani", "Herr", "Frau", "Mr", "Mrs", "Dr.", "Prof."):
            d = Detector(ner=fake_ner([("PERSON", "Kowalski")]))
            got = spans(d.detect("%s Jan Kowalski podpisał." % title))
            self.assertEqual(got, [("PERSON", "Jan Kowalski")], title)

    def test_extension_stops_at_punctuation_and_line_ends(self):
        d = Detector(ner=fake_ner([("PERSON", "Kowalski")]))
        self.assertEqual(spans(d.detect("Kraków, Jan\nKowalski, Dyrektor")), [("PERSON", "Kowalski")])


class LegalFormTests(unittest.TestCase):
    def test_company_names_with_legal_forms(self):
        cases = ["Bursztynowe Okna Sp. z o.o.", "Wiślańska Logistyka sp. z o.o.", "Orlen S.A.",
                 "Kowalczyk i Synowie sp.j.", "Nordwind Handels GmbH", "Bergmann & Söhne KG",
                 "Rheintal Versicherung AG", "Harbor & Pine LLP", "Ashford Robotics Inc.",
                 "Crescent Valley Bank Ltd", "Bluefield Analytics Ltd."]
        for name in cases:
            got = spans(Detector().detect("umowa z %s w sprawie" % name))
            self.assertIn(("ORG", name), got, name)

    def test_legal_form_beats_a_partial_person_match(self):
        d = Detector(ner=fake_ner([("PERSON", "Bursztynowe Okna")]))
        self.assertEqual(spans(d.detect("Umowa z Bursztynowe Okna Sp. z o.o. obowiązuje.")),
                         [("ORG", "Bursztynowe Okna Sp. z o.o.")])

    def test_no_company_without_a_name(self):
        self.assertEqual(spans(Detector().detect("spółka sp. z o.o. oraz AG i Ltd")), [])


class SentenceStartTests(unittest.TestCase):
    def test_capitalised_first_word_is_not_a_place_when_it_is_only_the_capital(self):
        # The model tags "Zawarta" but not "zawarta": a capital, not a place.
        d = Detector(ner=fake_ner([("LOCATION", "Zawarta"), ("LOCATION", "Warszawa"), ("LOCATION", "warszawa")]))
        got = spans(d.detect("Zawarta pomiędzy stronami. Warszawa jest stolicą."))
        self.assertEqual(got, [("LOCATION", "Warszawa")])

    def test_places_inside_a_sentence_are_kept(self):
        d = Detector(ner=fake_ner([("LOCATION", "Gdańsku")]))
        self.assertEqual(spans(d.detect("Spotkanie w Gdańsku.")), [("LOCATION", "Gdańsku")])

    def test_first_cell_of_a_table_line_counts_as_a_line_start(self):
        d = Detector(ner=fake_ner([("LOCATION", "Stanowisko")]))
        self.assertEqual(spans(d.detect("Stanowisko | dział\n")), [])


if __name__ == "__main__":
    unittest.main()
