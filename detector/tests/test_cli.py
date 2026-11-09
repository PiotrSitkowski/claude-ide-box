import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)


def run(*args, **kw):
    env = dict(os.environ, PYTHONPATH=PKG, PII_AIRGAP_NER="none")
    env.update(kw.pop("env", {}))
    return subprocess.run([sys.executable, "-m", "pii_airgap"] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, env=env, **kw)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(data)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "proj")
        self.lists = os.path.join(self.tmp.name, "lists.txt")
        write(os.path.join(self.root, "a.txt"), "Jan Kowalski, PESEL 44051401359\n")
        write(os.path.join(self.root, "b.txt"), "nothing\n")
        write(self.lists, "PERSON: Jan Kowalski\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_scan_text_report(self):
        r = run("scan", self.root, "--lists", self.lists, "--cache", os.path.join(self.tmp.name, "c"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("a.txt", r.stdout)
        self.assertIn("PESEL", r.stdout)
        self.assertIn("PERSON", r.stdout)
        self.assertNotIn("b.txt", r.stdout)
        self.assertNotIn("44051401359", r.stdout + r.stderr)
        self.assertIn("NER is off", r.stderr)

    def test_scan_json(self):
        r = run("scan", self.root, "--json", "--no-cache")
        rep = json.loads(r.stdout)
        self.assertEqual([f["path"] for f in rep["files"]], ["a.txt"])
        self.assertEqual(rep["ner"], "none")

    def test_scan_exit_status_with_fail_on_pii(self):
        self.assertEqual(run("scan", self.root, "--no-cache", "--fail-on-pii").returncode, 3)

    def test_unloadable_ner_fails_closed(self):
        r = run("scan", self.root, "--no-cache", env={"PII_AIRGAP_NER": "gliner:/nonexistent/model"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NER", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_bad_list_file_fails(self):
        write(self.lists, "bad type!: x\n")
        r = run("scan", self.root, "--lists", self.lists, "--no-cache")
        self.assertEqual(r.returncode, 1)
        self.assertIn("line 1", r.stderr)

    def test_anonymise_and_restore(self):
        m = os.path.join(self.tmp.name, "state", "map.json")
        r = run("anonymise", self.root, "--map", m, "--lists", self.lists)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.root, "a.txt")) as f:
            self.assertEqual(f.read(), "[PERSON_1], PESEL [PESEL_1]\n")
        write(os.path.join(self.root, "c.txt"), "[PERSON_2]\n")
        out = os.path.join(self.tmp.name, "out")
        os.mkdir(out)
        r = run("restore", self.root, "--map", m, "--out", out)
        self.assertEqual(r.returncode, 4)
        self.assertIn("c.txt:1: unknown token [PERSON_2]", r.stderr)
        os.unlink(os.path.join(self.root, "c.txt"))
        r = run("restore", self.root, "--map", m, "--out", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(out, "a.txt")) as f:
            self.assertEqual(f.read(), "Jan Kowalski, PESEL 44051401359\n")
        with open(os.path.join(self.root, "a.txt")) as f:
            self.assertEqual(f.read(), "[PERSON_1], PESEL [PESEL_1]\n")

    def test_restore_needs_a_destination(self):
        m = os.path.join(self.tmp.name, "state", "map.json")
        run("anonymise", self.root, "--map", m, "--lists", self.lists)
        r = run("restore", self.root, "--map", m)
        self.assertEqual(r.returncode, 2)
        self.assertIn("--out", r.stderr)
        with open(os.path.join(self.root, "a.txt")) as f:
            self.assertEqual(f.read(), "[PERSON_1], PESEL [PESEL_1]\n")
        r = run("restore", self.root, "--map", m, "--in-place")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("must not be opened", r.stderr)

    def test_verify_exit_status_and_no_values_printed(self):
        m = os.path.join(self.tmp.name, "state", "map.json")
        run("anonymise", self.root, "--map", m, "--lists", self.lists)
        r = run("verify", self.root, "--map", m)
        self.assertEqual(r.returncode, 0, r.stderr)
        run("restore", self.root, "--map", m, "--in-place")
        r = run("verify", self.root, "--map", m)
        self.assertEqual(r.returncode, 5)
        self.assertEqual(r.stdout, "a.txt\t2\n")
        self.assertNotIn("44051401359", r.stdout + r.stderr)
        self.assertNotIn("Kowalski", r.stdout + r.stderr)
        r = run("verify", self.root, "--map", os.path.join(self.tmp.name, "missing.json"))
        self.assertEqual(r.returncode, 1)

    def test_anonymise_refusal_exit_status(self):
        os.makedirs(os.path.join(self.root, ".git"))
        r = run("anonymise", self.root, "--map", os.path.join(self.tmp.name, "m.json"))
        self.assertEqual(r.returncode, 3)
        self.assertIn(".git", r.stderr)

    def test_anonymise_blocks_documents_from_scan_report(self):
        rep = os.path.join(self.tmp.name, "scan.json")
        with open(rep, "w") as f:
            json.dump({"files": [{"path": "x.docx", "method": "docx", "counts": {"PERSON": 1}},
                                 {"path": "a.txt", "method": "text", "counts": {"PESEL": 1}}]}, f)
        r = run("anonymise", self.root, "--map", os.path.join(self.tmp.name, "m.json"), "--scan-report", rep)
        self.assertEqual(r.returncode, 3)
        self.assertIn("x.docx", r.stderr)
        self.assertNotIn("a.txt", r.stderr)

    def test_anonymise_leaves_out_documents_from_scan_report(self):
        write(os.path.join(self.root, "x.docx"), "PK")
        write(os.path.join(self.root, "y.pdf"), "%PDF")
        rep = os.path.join(self.tmp.name, "scan.json")
        with open(rep, "w") as f:
            json.dump({"files": [{"path": "x.docx", "method": "docx", "counts": {"PERSON": 1}},
                                 {"path": "a.txt", "method": "text", "counts": {"PESEL": 1}}],
                       "errors": [{"path": "y.pdf", "error": "timeout"}]}, f)
        r = run("anonymise", self.root, "--map", os.path.join(self.tmp.name, "m.json"), "--scan-report", rep,
                "--leave-out", "--lists", self.lists)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("x.docx: DOCX document with personal data", r.stderr)
        self.assertIn("y.pdf: could not be scanned: timeout", r.stderr)
        self.assertNotIn("mask", r.stderr.lower())
        self.assertFalse(os.path.exists(os.path.join(self.root, "x.docx")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "y.pdf")))
        self.assertEqual(r.stdout, "a.txt\n")

    def test_system_prompt(self):
        r = run("system-prompt")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[PERSON_1]", r.stdout)
        self.assertIn("never", r.stdout.lower())


if __name__ == "__main__":
    unittest.main()
