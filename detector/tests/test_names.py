"""The name dictionary layer: given names and surnames from registries,
Polish inflection, and the rules that decide when a capitalised word next to
a known given name is a person.

The databases here are built from tiny synthetic sources with the same
builder the image uses, so the tests pin the class of behaviour, not the
contents of any registry."""

import json
import os
import sqlite3
import tempfile
import unittest
import zipfile

from pii_airgap import names_build
from pii_airgap.detect import Detector
from pii_airgap.names import NamesLayer

HERE = os.path.dirname(os.path.abspath(__file__))
RULES = os.path.join(HERE, "..", "..", "names")


def xlsx(path, rows):
    """A minimal XLSX with inline strings, as the registry files are read."""
    def cell(v):
        if isinstance(v, int):
            return "<c><v>%d</v></c>" % v
        return '<c t="inlineStr"><is><t>%s</t></is></c>' % v
    body = "".join("<row>%s</row>" % "".join(cell(v) for v in r) for r in rows)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/worksheets/sheet1.xml",
                   '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
                   "<sheetData>%s</sheetData></worksheet>" % body)


def build_fixture(tmp, forms=True):
    src = os.path.join(tmp, "src")
    os.makedirs(src)
    xlsx(os.path.join(src, "given.xlsx"), [("IMIĘ_PIERWSZE", "PŁEĆ", "LICZBA_WYSTĄPIEŃ"),
                                           ("ANNA", "KOBIETA", 900000), ("JAN", "MĘŻCZYZNA", 800000),
                                           ("RÓŻA", "KOBIETA", 30000), ("MAJA", "KOBIETA", 90000),
                                           ("ZDZISŁAWA", "KOBIETA", 40)])
    xlsx(os.path.join(src, "surname.xlsx"), [("Nawisko aktualne", "Liczba"), ("NOWAK", 140000),
                                             ("KOWALSKI", 70000), ("WIŚNIEWSKA", 50000), ("BĄK", 9000)])
    with open(os.path.join(src, "first.txt"), "w") as f:
        f.write("MARY           2.629  2.629      1\nJOHN           3.271  6.589      2\n"
                "GRACE          0.100  9.000     80\nMAY            0.050  9.500    200\n"
                "WILL           0.020  9.900    400\n")
    with zipfile.ZipFile(os.path.join(src, "surnames.zip"), "w") as z:
        z.writestr("Names_2010Census.csv", "name,rank,count,prop100k\nSMITH,1,2442977,828.19\n"
                   "JOHNSON,2,1932812,655.24\nDAY,300,90000,30.0\nALL OTHER NAMES,0,29312001,0\n")
    import gzip
    with gzip.open(os.path.join(src, "polimorf.tab.gz"), "wt", encoding="utf-8") as f:
        for row in [("Janem", "Jan", "subst:sg:inst:m1", "imię"), ("Jana", "Jan", "subst:sg:gen:m1", "imię"),
                    ("Anną", "Anna", "subst:sg:inst:f", "imię"),
                    ("Kowalskim", "Kowalski", "subst:sg:inst:m1", "nazwisko"),
                    ("Kowalskiego", "Kowalski", "subst:sg:gen:m1", "nazwisko"),
                    ("Nowak", "Nowak", "subst:sg:nom:m1", "nazwisko"),
                    ("róża", "róża", "subst:sg:nom:f", "pospolita"), ("maja", "maj", "subst:sg:gen:m3", "pospolita"),
                    ("jana", "jan", "subst:sg:gen:m3", "")]:
            f.write("\t".join(row) + "\n")
    with open(os.path.join(src, "wd.tsv"), "w") as f:
        f.write('?l\n"True"@en\n"An"@en\n')
    sources = {"sources": [
        {"id": "wd", "lang": "en", "kind": "given", "format": "wikidata-tsv", "file": "wd.tsv"},
        {"id": "pesel-given", "lang": "pl", "kind": "given", "format": "pesel-xlsx", "file": "given.xlsx"},
        {"id": "pesel-surname", "lang": "pl", "kind": "surname", "format": "pesel-xlsx", "file": "surname.xlsx"},
        {"id": "census-first", "lang": "en", "kind": "given", "format": "census1990-first", "file": "first.txt"},
        {"id": "census-surname", "lang": "en", "kind": "surname", "format": "census2010-zip",
         "file": "surnames.zip"},
        {"id": "polimorf", "lang": "pl", "kind": "forms", "format": "polimorf-tab-gz", "file": "polimorf.tab.gz"},
    ]}
    if not forms:
        sources["sources"] = [s for s in sources["sources"] if s["kind"] != "forms"]
    db = os.path.join(tmp, "names.db")
    names_build.build(sources, src, db, rules_dir=RULES, verify=False)
    return db


def persons(findings):
    return [f.text for f in findings if f.type == "PERSON"]


class BuildTests(unittest.TestCase):
    def test_database_holds_names_frequencies_and_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = build_fixture(tmp)
            c = sqlite3.connect(db)
            self.assertEqual(c.execute("SELECT count(*) FROM given WHERE name='anna'").fetchone()[0], 1)
            self.assertEqual(c.execute("SELECT count(*) FROM surname WHERE name='smith'").fetchone()[0], 1)
            self.assertEqual(c.execute("SELECT count(*) FROM surname WHERE name='all other names'").fetchone()[0], 0)
            self.assertEqual(c.execute("SELECT lemma FROM form WHERE form='kowalskim'").fetchone()[0], "kowalski")
            # Polish common nouns that are also name forms, kept to tell them apart
            self.assertEqual(c.execute("SELECT count(*) FROM common WHERE word IN ('róża','maja')").fetchone()[0], 2)
            # a registry name below the minimum count is left out
            self.assertEqual(c.execute("SELECT count(*) FROM given WHERE name='zdzisława'").fetchone()[0], 0)

    def test_a_source_with_a_wrong_checksum_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "src")
            os.makedirs(src)
            with open(os.path.join(src, "x.txt"), "w") as f:
                f.write("JOHN 1.0 1.0 1\n")
            sources = {"sources": [{"id": "x", "lang": "en", "kind": "given", "format": "census1990-first",
                                    "file": "x.txt", "sha256": "0" * 64}]}
            with self.assertRaises(names_build.SourceError):
                names_build.build(sources, src, os.path.join(tmp, "n.db"), rules_dir=RULES, verify=True)

    def test_sources_file_records_licence_and_check_date(self):
        with open(os.path.join(RULES, "sources.json"), encoding="utf-8") as f:
            data = json.load(f)
        self.assertTrue(data["sources"])
        for s in data["sources"]:
            for key in ("id", "url", "licence", "licence_source", "licence_checked", "lang", "kind", "format"):
                self.assertIn(key, s, "%s lacks %s" % (s.get("id"), key))
            self.assertTrue(s["commercial_use"], "%s does not allow commercial use" % s["id"])
            if s.get("reproducible", True):
                self.assertRegex(s.get("sha256", ""), r"^[0-9a-f]{64}$", s["id"])


class DetectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.layer = NamesLayer(build_fixture(cls.tmp.name))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def detect(self, text, **kw):
        return persons(Detector(names=self.layer).detect(text, **kw))

    def test_given_name_and_surname_pl_and_en(self):
        self.assertIn("Anna Nowak", self.detect("Umowę podpisała Anna Nowak w Warszawie."))
        self.assertIn("John Smith", self.detect("The contract was signed by John Smith yesterday."))

    def test_surname_first_order(self):
        self.assertIn("Nowak Anna", self.detect("Lista: Nowak Anna, kierownik."))

    def test_given_name_with_an_unknown_capitalised_neighbour(self):
        # Not in the surname list, but next to a well-known given name.
        self.assertIn("Anna Brzęczyszczykiewicz", self.detect("Wniosek złożyła Anna Brzęczyszczykiewicz."))

    def test_polish_inflection_from_the_dictionary(self):
        self.assertIn("Janem Kowalskim", self.detect("Umowa zawarta z Janem Kowalskim w dniu 1 maja."))

    def test_polish_surname_endings_without_dictionary_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            layer = NamesLayer(build_fixture(tmp, forms=False))
            got = persons(Detector(names=layer).detect("Spotkanie z Janem Wiśniewskiego nie odbyło się."))
            self.assertIn("Janem Wiśniewskiego", got)

    def test_a_given_name_alone_is_not_a_person(self):
        self.assertEqual([], self.detect("Anna ma kota."))
        self.assertEqual([], self.detect("Ask John."))

    def test_names_that_are_common_words_need_a_known_surname(self):
        self.assertEqual([], self.detect("Grace Period applies to every invoice."))
        self.assertEqual([], self.detect("May Day is a holiday."))
        self.assertEqual([], self.detect("Róża Wiatrów na mapie."))
        self.assertIn("Grace Johnson", self.detect("Signed by Grace Johnson."))

    def test_function_words_are_not_surnames(self):
        self.assertEqual([], self.detect("When John The report arrived."))
        self.assertEqual([], self.detect("Pisał Jan W sumie niewiele."))

    def test_surname_alone_needs_a_title_or_an_earlier_full_name(self):
        self.assertEqual([], self.detect("Nowak to popularne nazwisko."))
        self.assertIn("Nowak", self.detect("Proszę przekazać panu Nowakowi, że pani Nowak dzwoniła."))
        self.assertIn("Smith", self.detect("Dear Mr Smith, thank you."))
        got = self.detect("Anna Nowak przyszła rano. Potem Nowak wyszła.")
        self.assertEqual(got.count("Nowak"), 1)
        self.assertIn("Anna Nowak", got)

    def test_code_only_in_strings_and_comments(self):
        code = ('def annaNowak(JanKowalski):\n'
                '    # reviewed by Anna Nowak\n'
                '    author = "John Smith"\n'
                '    Anna_Nowak = JohnSmith + 1\n')
        got = self.detect(code, code=True)
        self.assertEqual(sorted(got), ["Anna Nowak", "John Smith"])

    def test_function_words_are_not_given_names(self):
        self.assertEqual([], self.detect("Returns An Observable."))

    def test_names_known_only_from_wikidata_need_a_known_surname(self):
        self.assertEqual([], self.detect("It Returns True Value."))
        self.assertIn("True Smith", self.detect("Signed by True Smith."))

    def test_upper_case_words_in_code_are_not_names(self):
        self.assertEqual([], self.detect("# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND\n", code=True))
        self.assertIn("JAN KOWALSKI", self.detect("Imię i nazwisko: JAN KOWALSKI, PESEL 44051401359"))

    def test_the_layer_does_not_cut_a_longer_model_finding(self):
        from pii_airgap.detect import Finding

        def ner(text):
            i = text.find("Fundacja Anny Nowak")
            return [Finding(i, i + len("Fundacja Anny Nowak"), "ORG", "ner:fake", 0.75, "ner")]
        ner.fingerprint = "fake"
        got = Detector(ner=ner, names=self.layer).detect("Darowizna dla: Fundacja Anny Nowak, Kraków.")
        self.assertEqual([(f.type, f.text) for f in got], [("ORG", "Fundacja Anny Nowak")])

    def test_findings_are_typed_and_sourced(self):
        f = [x for x in Detector(names=self.layer).detect("Signed by John Smith.") if x.type == "PERSON"][0]
        self.assertEqual(f.source, "names")

    def test_detector_without_the_layer_is_unchanged(self):
        self.assertEqual([], persons(Detector().detect("Umowę podpisała Anna Nowak.")))

    def test_fingerprint_changes_with_the_layer(self):
        self.assertNotEqual(Detector().fingerprint(), Detector(names=self.layer).fingerprint())


class ScanAndCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.db = build_fixture(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_scan_reads_source_code_as_code(self):
        from pii_airgap.scan import scan_file
        root = os.path.join(self.tmp.name, "proj")
        os.makedirs(root, exist_ok=True)
        with open(os.path.join(root, "a.py"), "w") as f:
            f.write("JanKowalski = 1\n# reviewed by Anna Nowak\nx = Anna\nNowak = 2\n")
        with open(os.path.join(root, "a.txt"), "w") as f:
            f.write("Anna\nNowak dzwoniła, a potem Anna Nowak przyszła.\n")
        det = Detector(names=NamesLayer(self.db))
        py = [x["preview"] for x in scan_file(os.path.join(root, "a.py"), det)["findings"] if x["type"] == "PERSON"]
        self.assertEqual(len(py), 1)
        txt = [x for x in scan_file(os.path.join(root, "a.txt"), det)["findings"] if x["type"] == "PERSON"]
        self.assertTrue(txt)

    def _run(self, *args, env=None):
        import subprocess
        import sys
        e = dict(os.environ, PYTHONPATH=os.path.dirname(HERE), PII_AIRGAP_NER="none")
        e.update(env or {})
        return subprocess.run([sys.executable, "-m", "pii_airgap"] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True, env=e)

    def test_cli_uses_the_dictionary_from_the_environment(self):
        root = os.path.join(self.tmp.name, "cli")
        os.makedirs(root, exist_ok=True)
        with open(os.path.join(root, "a.txt"), "w") as f:
            f.write("Umowę podpisała Anna Nowak.\n")
        off = self._run("scan", root, "--no-cache", "--json")
        on = self._run("scan", root, "--no-cache", "--json", env={"PII_AIRGAP_NAMES": self.db})
        self.assertEqual(on.returncode, 0, on.stderr)
        def counts(r):
            files = json.loads(r.stdout)["files"]  # files without findings are left out
            return files[0]["counts"] if files else {}
        self.assertNotIn("PERSON", counts(off))
        self.assertIn("PERSON", counts(on))
        self.assertIn("name dictionary", on.stderr)

    def test_a_missing_dictionary_fails_closed(self):
        r = self._run("scan", self.tmp.name, "--no-cache", env={"PII_AIRGAP_NAMES": "/nonexistent/names.db"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("name dictionary", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_names_off_by_default(self):
        from pii_airgap import cli
        self.assertEqual(cli.names_spec(None, {}), "none")
        self.assertEqual(cli.names_spec(None, {"PII_AIRGAP_NAMES": "/x.db"}), "/x.db")
        self.assertEqual(cli.names_spec("off", {"PII_AIRGAP_NAMES": "/x.db"}), "none")
        # the image sets PII_AIRGAP_NAMES to its NAMES build argument
        self.assertEqual(cli.names_spec(None, {"PII_AIRGAP_NAMES": "off"}), "none")
        self.assertEqual(cli.names_spec(None, {"PII_AIRGAP_NAMES": "dict"}), cli.BUNDLED_NAMES)
        self.assertEqual(cli.names_spec(None, {"PII_AIRGAP_NAMES": "rules"}), cli.BUNDLED_NAMES)


if __name__ == "__main__":
    unittest.main()
