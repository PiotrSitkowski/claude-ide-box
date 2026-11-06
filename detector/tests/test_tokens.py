import json
import os
import stat
import tempfile
import unittest

from pii_airgap.detect import Detector
from pii_airgap.tokens import (
    TokenCollision,
    TokenMap,
    anonymise_text,
    anonymise_tree,
    restore_text,
    restore_tree,
    verify_tree,
)


def write(path, data, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(data)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class TextTests(unittest.TestCase):
    def setUp(self):
        self.d = Detector(lists=[("PERSON", "Jan Kowalski"), ("PERSON", "Anna Nowak")])
        self.m = TokenMap()

    def test_same_value_same_token_types_counted_separately(self):
        a = anonymise_text("Jan Kowalski, PESEL 44051401359; Anna Nowak; Jan Kowalski", self.d, self.m)
        self.assertEqual(a, "[PERSON_1], PESEL [PESEL_1]; [PERSON_2]; [PERSON_1]")
        b = anonymise_text("Anna Nowak", self.d, self.m)
        self.assertEqual(b, "[PERSON_2]")

    def test_exact_text_is_the_key(self):
        a = anonymise_text("Jan Kowalski / JAN KOWALSKI", self.d, self.m)
        self.assertEqual(a, "[PERSON_1] / [PERSON_2]")
        self.assertEqual(restore_text(a, self.m)[0], "Jan Kowalski / JAN KOWALSKI")

    def test_existing_token_shaped_text_is_refused(self):
        with self.assertRaises(TokenCollision):
            anonymise_text("template [PERSON_1] for Jan Kowalski", self.d, self.m)

    def test_round_trip(self):
        src = "Jan Kowalski <jan.k@example.com> PESEL 44051401359\nAnna Nowak"
        self.assertEqual(restore_text(anonymise_text(src, self.d, self.m), self.m), (src, []))

    def test_unknown_tokens_are_reported_not_guessed(self):
        anonymise_text("Jan Kowalski", self.d, self.m)
        out, problems = restore_text("[PERSON_1] and [PERSON_7] and [IBAN_1]", self.m)
        self.assertEqual(out, "Jan Kowalski and [PERSON_7] and [IBAN_1]")
        self.assertEqual([p.kind for p in problems], ["unknown", "unknown"])
        self.assertEqual([p.text for p in problems], ["[PERSON_7]", "[IBAN_1]"])

    def test_altered_tokens_are_reported(self):
        anonymise_text("Jan Kowalski", self.d, self.m)
        for altered in ["[person_1]", "[Person_1]", "[PERSON_1", "PERSON_1]", "[PERSON 1]",
                        "[ PERSON_1 ]", "[PERSON-1]", "PERSON_1", "[PERSON_01]", "\\[PERSON_1\\]"]:
            out, problems = restore_text("x %s y" % altered, self.m)
            self.assertEqual(out, "x %s y" % altered, altered)
            self.assertEqual([p.kind for p in problems], ["altered"], altered)

    def test_near_misses_already_in_the_original_are_not_problems(self):
        anonymise_text("Jan Kowalski", self.d, self.m)
        _, problems = restore_text("enum PERSON_1 = 1; [PERSON_1]", self.m, baseline="enum PERSON_1 = 1;")
        self.assertEqual(problems, [])
        _, problems = restore_text("PERSON_1 PERSON_1 [PERSON_1]", self.m, baseline="enum PERSON_1 = 1;")
        self.assertEqual(len(problems), 1)


class MapFileTests(unittest.TestCase):
    def test_map_file_is_private_and_reloadable(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "sub", "map.json")
            m = TokenMap()
            m.token_for("PERSON", "Jan Kowalski")
            m.save(p)
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode), 0o700)
            m2 = TokenMap.load(p)
            self.assertEqual(m2.token_for("PERSON", "Jan Kowalski"), "[PERSON_1]")
            self.assertEqual(m2.token_for("PERSON", "Anna Nowak"), "[PERSON_2]")
            with open(p) as f:
                self.assertEqual(json.load(f)["format"], "pii-airgap-map/1")


class TreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "work")
        self.base = os.path.join(self.tmp.name, "base")
        self.map = os.path.join(self.tmp.name, "state", "map.json")
        self.d = Detector(lists=[("PERSON", "Jan Kowalski")])
        for r in (self.root, self.base):
            write(os.path.join(r, "a.txt"), "Jan Kowalski, PESEL 44051401359\n")
            write(os.path.join(r, "src/b.py"), "OWNER = 'Jan Kowalski'\n")
            write(os.path.join(r, "clean.md"), "nothing here\n")
            write(os.path.join(r, ".git/config"), "Jan Kowalski\n")
            write(os.path.join(r, "bin.dat"), b"\x00\x01Jan Kowalski", "wb")

    def tearDown(self):
        self.tmp.cleanup()

    def test_anonymise_then_restore_untouched_is_identical(self):
        rep = anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertEqual(sorted(rep.changed), ["a.txt", "src/b.py"])
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "[PERSON_1], PESEL [PESEL_1]\n")
        self.assertFalse(os.path.exists(os.path.join(self.root, ".git")))
        rep = restore_tree(self.root, self.map, self.base)
        self.assertEqual(rep.problems, [])
        for rel in ("a.txt", "src/b.py", "clean.md"):
            self.assertEqual(read(os.path.join(self.root, rel)), read(os.path.join(self.base, rel)))

    def test_git_history_is_refused_by_default(self):
        from pii_airgap.tokens import Unrewritable
        os.makedirs(os.path.join(self.root, "vendor/lib/.git"))
        with self.assertRaises(Unrewritable) as cm:
            anonymise_tree(self.root, self.map, self.d)
        self.assertIn(".git", str(cm.exception))
        self.assertIn("vendor/lib/.git", str(cm.exception))
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "Jan Kowalski, PESEL 44051401359\n")
        anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertFalse(os.path.exists(os.path.join(self.root, "vendor/lib/.git")))

    def test_restore_after_edit(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "new.txt"), "Owner: [PERSON_1] ([PESEL_1])\n")
        rep = restore_tree(self.root, self.map, self.base)
        self.assertEqual(rep.problems, [])
        self.assertEqual(read(os.path.join(self.root, "new.txt")), "Owner: Jan Kowalski (44051401359)\n")

    def test_restore_writes_nothing_when_a_token_is_unknown_or_altered(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "new.txt"), "[PERSON_1] [PERSON_2]\n")
        write(os.path.join(self.root, "src/b.py"), "OWNER = '[person_1]'\n")
        rep = restore_tree(self.root, self.map, self.base)
        self.assertEqual(sorted((p.path, p.kind) for p in rep.problems),
                         [("new.txt", "unknown"), ("src/b.py", "altered")])
        self.assertFalse(rep.written)
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "[PERSON_1], PESEL [PESEL_1]\n")

    def test_restore_can_leave_problems_literal_when_asked(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "new.txt"), "[PERSON_1] [PERSON_2]\n")
        rep = restore_tree(self.root, self.map, self.base, keep_unresolved=True)
        self.assertTrue(rep.written)
        self.assertEqual(read(os.path.join(self.root, "new.txt")), "Jan Kowalski [PERSON_2]\n")

    def test_anonymise_refuses_token_shaped_text_and_writes_nothing(self):
        write(os.path.join(self.root, "tpl.txt"), "Dear [PERSON_1],\n")
        with self.assertRaises(TokenCollision) as cm:
            anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertIn("tpl.txt", str(cm.exception))
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "Jan Kowalski, PESEL 44051401359\n")

    def test_anonymise_refuses_documents_it_cannot_rewrite(self):
        from pii_airgap.tokens import Unrewritable
        with self.assertRaises(Unrewritable) as cm:
            anonymise_tree(self.root, self.map, self.d, git="strip", documents_with_pii=["contracts/umowa.docx"])
        self.assertIn("contracts/umowa.docx", str(cm.exception))
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "Jan Kowalski, PESEL 44051401359\n")

    def test_symlinks_are_never_followed(self):
        outside = os.path.join(self.tmp.name, "outside.txt")
        write(outside, "Jan Kowalski\n")
        os.symlink(outside, os.path.join(self.root, "link.txt"))
        anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertEqual(read(outside), "Jan Kowalski\n")
        write(outside, "[PERSON_1]\n")
        restore_tree(self.root, self.map, self.base)
        self.assertEqual(read(outside), "[PERSON_1]\n")

    def test_pii_in_file_names_blocks(self):
        write(os.path.join(self.root, "44051401359.txt"), "x\n")
        from pii_airgap.tokens import Unrewritable
        with self.assertRaises(Unrewritable) as cm:
            anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertIn("44051401359.txt", str(cm.exception))

    def test_anonymise_is_idempotent_with_existing_map(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        restore_tree(self.root, self.map, self.base)
        anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "[PERSON_1], PESEL [PESEL_1]\n")

    # A restored copy must never be the folder an agent works in again, so
    # restoration writes elsewhere and the copy keeps its tokens.

    def test_restore_to_out_leaves_the_copy_tokenised(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "new.txt"), "Owner: [PERSON_1]\n")
        out = os.path.join(self.tmp.name, "out")
        os.mkdir(out)
        rep = restore_tree(self.root, self.map, self.base, out=out)
        self.assertTrue(rep.written)
        self.assertEqual(read(os.path.join(self.root, "a.txt")), "[PERSON_1], PESEL [PESEL_1]\n")
        self.assertEqual(read(os.path.join(self.root, "new.txt")), "Owner: [PERSON_1]\n")
        self.assertEqual(read(os.path.join(out, "a.txt")), "Jan Kowalski, PESEL 44051401359\n")
        self.assertEqual(read(os.path.join(out, "new.txt")), "Owner: Jan Kowalski\n")
        self.assertEqual(read(os.path.join(out, "clean.md")), "nothing here\n")
        with open(os.path.join(out, "bin.dat"), "rb") as f:
            self.assertEqual(f.read(), b"\x00\x01Jan Kowalski")
        # Only the binary file, which anonymise cannot rewrite, still holds a value.
        self.assertEqual(verify_tree(self.root, self.map), [("bin.dat", 1)])

    def test_restore_to_out_needs_an_empty_directory(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        out = os.path.join(self.tmp.name, "out")
        write(os.path.join(out, "x.txt"), "x\n")
        with self.assertRaises(ValueError):
            restore_tree(self.root, self.map, self.base, out=out)

    def test_restore_to_out_writes_nothing_on_a_problem(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "new.txt"), "[PERSON_9]\n")
        out = os.path.join(self.tmp.name, "out")
        os.mkdir(out)
        rep = restore_tree(self.root, self.map, self.base, out=out)
        self.assertFalse(rep.written)
        self.assertEqual(os.listdir(out), [])

    def test_restore_into_base_applies_changes_only(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "src/b.py"), "OWNER = '[PERSON_1]'  # checked\n")
        write(os.path.join(self.root, "docs/new.md"), "[PERSON_1]\n")
        os.unlink(os.path.join(self.root, "clean.md"))
        before = os.stat(os.path.join(self.base, "a.txt")).st_mtime_ns
        rep = restore_tree(self.root, self.map, self.base, into_base=True)
        self.assertTrue(rep.written)
        self.assertEqual(sorted(rep.changed), ["docs/new.md", "src/b.py"])
        self.assertEqual(read(os.path.join(self.base, "src/b.py")), "OWNER = 'Jan Kowalski'  # checked\n")
        self.assertEqual(read(os.path.join(self.base, "docs/new.md")), "Jan Kowalski\n")
        self.assertEqual(os.stat(os.path.join(self.base, "a.txt")).st_mtime_ns, before)
        # Deleted in the copy: left in place and reported, never deleted.
        self.assertTrue(os.path.exists(os.path.join(self.base, "clean.md")))
        self.assertIn("clean.md", rep.kept)
        self.assertEqual(read(os.path.join(self.root, "src/b.py")), "OWNER = '[PERSON_1]'  # checked\n")

    def test_restore_into_base_never_writes_through_a_symlink(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        outside = os.path.join(self.tmp.name, "outside")
        os.mkdir(outside)
        os.symlink(outside, os.path.join(self.base, "docs"))
        write(os.path.join(self.root, "docs/new.md"), "[PERSON_1]\n")
        with self.assertRaises(ValueError):
            restore_tree(self.root, self.map, self.base, into_base=True)
        self.assertEqual(os.listdir(outside), [])

    def test_verify_flags_a_binary_file_anonymise_left_alone(self):
        anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertEqual(verify_tree(self.root, self.map), [("bin.dat", 1)])

    def test_verify_finds_values_of_the_map(self):
        os.unlink(os.path.join(self.root, "bin.dat"))
        anonymise_tree(self.root, self.map, self.d, git="strip")
        self.assertEqual(verify_tree(self.root, self.map), [])
        restore_tree(self.root, self.map, self.base)  # in place: the old, unsafe way
        found = verify_tree(self.root, self.map)
        self.assertEqual([rel for rel, _ in found], ["a.txt", "src/b.py"])
        self.assertEqual(dict(found)["a.txt"], 2)

    def test_verify_finds_a_value_the_agent_wrote(self):
        os.unlink(os.path.join(self.root, "bin.dat"))
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "notes/x.md"), "call 44051401359 today\n")
        self.assertEqual(verify_tree(self.root, self.map), [("notes/x.md", 1)])

    def test_verify_matches_whole_values_only(self):
        os.unlink(os.path.join(self.root, "bin.dat"))
        anonymise_tree(self.root, self.map, self.d, git="strip")
        write(os.path.join(self.root, "x.txt"), "1440514013590 Jan Kowalskiego\n")
        self.assertEqual(verify_tree(self.root, self.map), [])

    def test_verify_does_not_follow_symlinks(self):
        os.unlink(os.path.join(self.root, "bin.dat"))
        anonymise_tree(self.root, self.map, self.d, git="strip")
        outside = os.path.join(self.tmp.name, "outside.txt")
        write(outside, "Jan Kowalski\n")
        os.symlink(outside, os.path.join(self.root, "link.txt"))
        self.assertEqual(verify_tree(self.root, self.map), [])


if __name__ == "__main__":
    unittest.main()
