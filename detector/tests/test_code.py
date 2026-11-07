"""Source code: the NER model reads only string literals and comments, never
identifiers, keywords or other code. Checksums, patterns and lists still read
the whole file."""

import os
import tempfile
import unittest

from pii_airgap.code import code_spans, syntax_for
from pii_airgap.detect import Detector, Finding
from pii_airgap.scan import scan_file


def every_capitalised_word(text):
    """A model that calls every capitalised word a person - the worst case
    for code, where class names and constants are capitalised."""
    import re
    return [Finding(m.start(), m.end(), "PERSON", "ner:fake", 0.8, "ner")
            for m in re.finditer(r"\b[A-Z][a-z]+(?: [A-Z][a-z]+)*", text)]


every_capitalised_word.fingerprint = "fake"


def people(findings):
    return sorted(f.text for f in findings if f.type == "PERSON")


def spans_text(text, ext):
    return [text[a:b] for a, b in code_spans(text, syntax_for(ext))]


class SpansTests(unittest.TestCase):
    def test_python_strings_and_hash_comments_not_floor_division(self):
        src = 'x = a // b  # Anna Nowak\ny = "John Smith"\nz = \'Ewa\'\ndoc = """Jan\nKowalski"""\n'
        got = spans_text(src, ".py")
        self.assertIn("# Anna Nowak", got)
        self.assertIn('"John Smith"', got)
        self.assertIn("'Ewa'", got)
        self.assertIn('"""Jan\nKowalski"""', got)
        self.assertFalse(any("//" in s for s in got))

    def test_c_family_comments_and_strings(self):
        for ext in (".js", ".ts", ".go", ".java", ".c"):
            src = 'const Foo = a / b; // Anna Nowak\n/* John\nSmith */ s = "Jan Kowalski";\n'
            got = spans_text(src, ext)
            self.assertIn("// Anna Nowak", got, ext)
            self.assertIn("/* John\nSmith */", got, ext)
            self.assertIn('"Jan Kowalski"', got, ext)
            self.assertFalse(any("Foo" in s for s in got), ext)

    def test_rust_attributes_and_lifetimes_are_code(self):
        src = "#[derive(Debug)]\nfn f<'a>(x: &'a str) -> &'a str { x } // Anna Nowak\nlet s = \"Jan Kowalski\";\n"
        got = spans_text(src, ".rs")
        self.assertEqual(got, ["// Anna Nowak", '"Jan Kowalski"'])

    def test_go_raw_strings_and_sql_and_shell_comments(self):
        self.assertIn("`John Smith`", spans_text("s := `John Smith`\n", ".go"))
        self.assertIn("-- Anna Nowak", spans_text("SELECT a FROM b; -- Anna Nowak\n", ".sql"))
        self.assertIn("# Anna Nowak", spans_text("echo $x # Anna Nowak\n", ".sh"))

    def test_escaped_quotes_stay_inside_the_string(self):
        self.assertEqual(spans_text('s = "Anna \\"Nowak\\" Kowalska"; t = Foo\n', ".js"),
                         ['"Anna \\"Nowak\\" Kowalska"'])

    def test_html_comments_in_markup_files(self):
        self.assertIn("<!-- Anna Nowak -->", spans_text("<div class=\"Foo\"><!-- Anna Nowak --></div>", ".vue"))


class DetectTests(unittest.TestCase):
    def setUp(self):
        self.det = Detector(ner=every_capitalised_word)

    def test_model_only_in_strings_and_comments(self):
        src = ('class UserProfile(BaseModel):\n'
               '    # reviewed by Anna Nowak\n'
               '    Default = "John Smith"\n'
               '    def Render(self): return Template\n')
        got = people(self.det.detect(src, code=".py"))
        self.assertEqual(got, ["Anna Nowak", "John Smith"])

    def test_offsets_point_at_the_original_text(self):
        src = 'Foo = 1\n// Anna Nowak\nBar = "Jan Kowalski"\n'
        for f in self.det.detect(src, code=".js"):
            if f.type == "PERSON":
                self.assertIn(src[f.start:f.end], ("Anna Nowak", "Jan Kowalski"))

    def test_checksums_still_read_the_whole_file(self):
        src = "PESEL = 44051401359\nemail = contact\n"
        got = [f.type for f in self.det.detect(src, code=".py")]
        self.assertIn("PESEL", got)

    def test_text_is_read_whole(self):
        got = people(self.det.detect("UserProfile reviewed by Anna Nowak."))
        self.assertIn("Anna Nowak", got)
        self.assertTrue(any(g.startswith("User") for g in got), got)

    def test_the_model_runs_once_per_file(self):
        calls = []

        def counting(text):
            calls.append(text)
            return []
        counting.fingerprint = "count"
        src = "".join('x%d = "Anna Nowak %d"  # Jan %d\n' % (i, i, i) for i in range(50))
        Detector(ner=counting).detect(src, code=".py")
        self.assertEqual(len(calls), 1)


class ScanTests(unittest.TestCase):
    def test_scan_reads_code_files_as_code(self):
        det = Detector(ner=every_capitalised_word)
        with tempfile.TemporaryDirectory() as tmp:
            py = os.path.join(tmp, "a.py")
            txt = os.path.join(tmp, "a.txt")
            for p in (py, txt):
                with open(p, "w") as f:
                    f.write("UserProfile = Template  # Anna Nowak\n")
            in_py = [x["preview"] for x in scan_file(py, det)["findings"] if x["type"] == "PERSON"]
            in_txt = [x["preview"] for x in scan_file(txt, det)["findings"] if x["type"] == "PERSON"]
            self.assertEqual(len(in_py), 1)
            self.assertGreater(len(in_txt), 1)

    def test_anonymise_leaves_identifiers_in_code_alone(self):
        from pii_airgap.tokens import anonymise_text
        from pii_airgap.tokens import TokenMap
        src = "class UserProfile:  # Anna Nowak\n    pass\n"
        new = anonymise_text(src, Detector(ner=every_capitalised_word), TokenMap(), where="a.py", code=".py")
        self.assertIn("class UserProfile:", new)
        self.assertNotIn("Anna Nowak", new)

    def test_anonymise_tree_reads_code_files_as_code(self):
        from pii_airgap.tokens import anonymise_tree
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "copy")
            os.makedirs(root)
            with open(os.path.join(root, "a.py"), "w") as f:
                f.write("class UserProfile:  # Anna Nowak\n    pass\n")
            anonymise_tree(root, os.path.join(tmp, "map.json"), Detector(ner=every_capitalised_word))
            with open(os.path.join(root, "a.py")) as f:
                out = f.read()
            self.assertIn("class UserProfile:", out)
            self.assertNotIn("Anna Nowak", out)

    def test_detector_version_changes_with_code_mode(self):
        from pii_airgap import detect
        self.assertNotEqual(detect.VERSION, "2")

    def test_unknown_extensions_are_text(self):
        self.assertIsNone(syntax_for(".md"))
        self.assertIsNone(syntax_for(".txt"))
        self.assertIsNotNone(syntax_for(".PY"))


if __name__ == "__main__":
    unittest.main()
