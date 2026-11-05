import unittest

from pii_airgap.detect import Detector
from pii_airgap.ner import GlinerBackend, SpacyBackend, chunks, load_backend


class FakeGliner(object):
    def __init__(self):
        self.calls = []

    def predict_entities(self, text, labels, threshold=0.5):
        self.calls.append((text, tuple(labels), threshold))
        out = []
        for name, label, score in (("Jan Kowalski", "person", 0.93), ("Orlen", "organization", 0.7),
                                   ("cukrzyca", "medical condition", 0.4)):
            i = text.find(name)
            if i >= 0 and score >= threshold:
                out.append({"start": i, "end": i + len(name), "label": label, "score": score, "text": name})
        return out


class FakeEnt(object):
    def __init__(self, start, end, label):
        self.start_char, self.end_char, self.label_ = start, end, label


class FakeDoc(object):
    def __init__(self, text):
        self.ents = []
        for name, label in (("Hans Müller", "PER"), ("Berlin", "LOC"), ("Siemens", "ORG"), ("Euro", "MISC")):
            i = text.find(name)
            if i >= 0:
                self.ents.append(FakeEnt(i, i + len(name), label))


class NerTests(unittest.TestCase):
    def test_chunks_keep_offsets_and_split_on_whitespace(self):
        text = ("word " * 50 + "\n") * 10
        parts = list(chunks(text, 120))
        self.assertGreater(len(parts), 1)
        self.assertEqual("".join(p for _, p in parts), text)
        for off, p in parts:
            self.assertEqual(text[off:off + len(p)], p)
            self.assertLessEqual(len(p), 120)

    def test_gliner_labels_map_to_token_types(self):
        model = FakeGliner()
        ner = GlinerBackend(model, threshold=0.5, fingerprint="fake")
        text = "Umowa: Jan Kowalski, Orlen, cukrzyca"
        got = [(f.type, text[f.start:f.end], f.source) for f in ner(text)]
        self.assertEqual(got, [("PERSON", "Jan Kowalski", "ner"), ("ORG", "Orlen", "ner")])
        self.assertIn("person", model.calls[0][1])

    def test_gliner_offsets_survive_chunking(self):
        ner = GlinerBackend(FakeGliner(), chunk_size=40, fingerprint="fake")
        text = "x " * 30 + "Jan Kowalski " + "y " * 30
        got = [text[f.start:f.end] for f in ner(text)]
        self.assertEqual(got, ["Jan Kowalski"])

    def test_spacy_labels(self):
        ner = SpacyBackend(FakeDoc, fingerprint="fake")
        text = "Hans Müller (Siemens) wohnt in Berlin, 5 Euro"
        got = [(f.type, text[f.start:f.end]) for f in ner(text)]
        self.assertEqual(got, [("PERSON", "Hans Müller"), ("ORG", "Siemens"), ("LOCATION", "Berlin")])

    def test_detector_with_backend(self):
        d = Detector(ner=SpacyBackend(FakeDoc, fingerprint="fake"))
        self.assertNotEqual(d.fingerprint(), Detector().fingerprint())
        self.assertNotEqual(d.fingerprint(), Detector(ner=SpacyBackend(FakeDoc, fingerprint="other")).fingerprint())
        self.assertEqual([f.type for f in d.detect("Hans Müller, PESEL 44051401359")], ["PERSON", "PESEL"])

    def test_load_backend(self):
        self.assertIsNone(load_backend("none"))
        with self.assertRaises(ValueError):
            load_backend("magic:x")


if __name__ == "__main__":
    unittest.main()
