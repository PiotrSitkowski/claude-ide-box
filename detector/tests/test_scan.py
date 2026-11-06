import json
import os
import shutil
import tempfile
import unittest
import zipfile

from pii_airgap.detect import Detector
from pii_airgap.extract import ExtractionError, extract_text
from pii_airgap.scan import scan_tree


def write(path, data, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(data)


def make_docx(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("word/document.xml",
                   '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                   "<w:body><w:p><w:r><w:t>%s</w:t></w:r></w:p><w:p><w:r><w:t>end</w:t></w:r></w:p></w:body></w:document>" % text)


def make_xlsx(path, cells):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ss = "".join("<si><t>%s</t></si>" % c for c in cells)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/sharedStrings.xml",
                   '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">%s</sst>' % ss)
        z.writestr("xl/worksheets/sheet1.xml",
                   '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
                   '<row><c t="s"><v>0</v></c><c><v>44051401359</v></c></row></sheetData></worksheet>')


def make_pdf(path, text):
    """A one-page PDF with a single line of Helvetica text."""
    stream = "BT /F1 12 Tf 72 720 Td (%s) Tj ET" % text
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        "/Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = "%PDF-1.4\n"
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += "%d 0 obj\n%s\nendobj\n" % (i, o)
    xref = len(out)
    out += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += "".join("%010d 00000 n \n" % off for off in offsets)
    out += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="latin-1") as f:
        f.write(out)


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, name):
        return os.path.join(self.tmp.name, name)

    def test_plain_text_and_docx_and_xlsx(self):
        write(self.p("a.txt"), "PESEL 44051401359")
        self.assertEqual(extract_text(self.p("a.txt")).text, "PESEL 44051401359")
        make_docx(self.p("u.docx"), "Jan Kowalski")
        r = extract_text(self.p("u.docx"))
        self.assertEqual(r.method, "docx")
        self.assertIn("Jan Kowalski\nend", r.text)
        make_xlsx(self.p("t.xlsx"), ["Anna Nowak"])
        r = extract_text(self.p("t.xlsx"))
        self.assertIn("Anna Nowak", r.text)
        self.assertIn("44051401359", r.text)

    def test_binary_is_not_text(self):
        write(self.p("x.bin"), b"\x00\x01\x02abc", "wb")
        self.assertIsNone(extract_text(self.p("x.bin")))

    def test_zip_bomb_is_refused(self):
        path = self.p("bomb.docx")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("word/document.xml", "<w:t>" + "A" * (3 * 1024 * 1024) + "</w:t>")
        with self.assertRaises(ExtractionError):
            extract_text(path, max_bytes=1024 * 1024)

    @unittest.skipUnless(shutil.which("pdftotext"), "pdftotext not installed")
    def test_pdf(self):
        make_pdf(self.p("s.pdf"), "PESEL 44051401359")
        r = extract_text(self.p("s.pdf"))
        self.assertEqual(r.method, "pdftotext")
        self.assertIn("44051401359", r.text)


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "proj")
        self.cache = os.path.join(self.tmp.name, "cache")
        write(os.path.join(self.root, "a.txt"), "Jan Kowalski\nPESEL 44051401359\n")
        write(os.path.join(self.root, "clean.txt"), "nothing\n")
        write(os.path.join(self.root, ".git/HEAD"), "PESEL 44051401359\n")
        make_docx(os.path.join(self.root, "docs/umowa.docx"), "konto PL61 1090 1014 0000 0712 1981 2874")

    def tearDown(self):
        self.tmp.cleanup()

    def counting(self, lists=()):
        d = Detector(lists=list(lists))
        calls = []
        orig = d.detect

        def detect(text, **kw):
            calls.append(text)
            return orig(text, **kw)

        d.detect = detect
        return d, calls

    def test_report(self):
        d, _ = self.counting([("PERSON", "Jan Kowalski")])
        rep = scan_tree(self.root, self.cache, d)
        files = {f["path"]: f for f in rep["files"]}
        self.assertEqual(sorted(files), ["a.txt", "docs/umowa.docx"])
        a = files["a.txt"]
        self.assertEqual(a["counts"], {"PERSON": 1, "PESEL": 1})
        pesel = [f for f in a["findings"] if f["type"] == "PESEL"][0]
        self.assertEqual(pesel["line"], 2)
        self.assertGreaterEqual(pesel["confidence"], 0.95)
        self.assertNotIn("44051401359", json.dumps(rep))
        self.assertEqual(files["docs/umowa.docx"]["method"], "docx")
        self.assertEqual(rep["summary"]["files_with_pii"], 2)
        self.assertEqual(rep["summary"]["files_scanned"], 3)

    def test_cache_skips_unchanged_files_and_holds_no_values(self):
        d, calls = self.counting()
        scan_tree(self.root, self.cache, d)
        self.assertEqual(len(calls), 3)
        d2, calls2 = self.counting()
        rep = scan_tree(self.root, self.cache, d2)
        self.assertEqual(len(calls2), 0)
        self.assertEqual(rep["summary"]["cached"], 3)
        write(os.path.join(self.root, "a.txt"), "PESEL 02270803624\n")
        d3, calls3 = self.counting()
        scan_tree(self.root, self.cache, d3)
        self.assertEqual(len(calls3), 1)
        for dirpath, _, names in os.walk(self.cache):
            for n in names:
                with open(os.path.join(dirpath, n)) as f:
                    body = f.read()
                self.assertNotIn("44051401359", body)
                self.assertNotIn("02270803624", body)

    def test_cache_depends_on_detector_configuration(self):
        d, _ = self.counting()
        scan_tree(self.root, self.cache, d)
        d2, calls2 = self.counting([("PERSON", "Jan Kowalski")])
        rep = scan_tree(self.root, self.cache, d2)
        self.assertEqual(len(calls2), 3)
        self.assertIn("PERSON", {f["path"]: f for f in rep["files"]}["a.txt"]["counts"])

    def test_symlinks_and_special_files_are_not_followed(self):
        outside = os.path.join(self.tmp.name, "outside.txt")
        write(outside, "PESEL 44051401359\n")
        os.symlink(outside, os.path.join(self.root, "link.txt"))
        d, _ = self.counting()
        rep = scan_tree(self.root, self.cache, d)
        self.assertNotIn("link.txt", [f["path"] for f in rep["files"]])
        self.assertIn("link.txt", rep["skipped"]["symlink"])


if __name__ == "__main__":
    unittest.main()
