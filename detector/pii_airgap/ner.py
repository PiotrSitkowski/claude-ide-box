"""NER backends. Both run fully offline from a model directory baked into
the image; nothing is downloaded at run time.

  gliner:<dir>   GLiNER zero-shot model (labels below)
  spacy:<name>   an installed spaCy pipeline, e.g. xx_ent_wiki_sm
  none           checksums, patterns and user lists only
"""

import hashlib
import json
import os

from .detect import Finding

GLINER_LABELS = {
    "person": "PERSON",
    "organization": "ORG",
    "address": "ADDRESS",
    "location": "LOCATION",
    "date of birth": "DOB",
    "medical condition": "HEALTH",
}
SPACY_LABELS = {"PER": "PERSON", "PERSON": "PERSON", "persName": "PERSON",
                "ORG": "ORG", "orgName": "ORG",
                "LOC": "LOCATION", "GPE": "LOCATION", "placeName": "LOCATION", "geogName": "LOCATION"}


def chunks(text, size):
    """(offset, piece) pieces of at most `size` characters, cut after a
    newline or a space where possible. Concatenated they give `text`."""
    pos, n = 0, len(text)
    while pos < n:
        end = min(pos + size, n)
        if end < n:
            cut = text.rfind("\n", pos, end)
            if cut <= pos:
                cut = text.rfind(" ", pos, end)
            if cut > pos:
                end = cut + 1
        yield pos, text[pos:end]
        pos = end


class GlinerBackend(object):
    def __init__(self, model, labels=None, threshold=0.5, chunk_size=1200, fingerprint="gliner"):
        self.model = model
        self.labels = labels or GLINER_LABELS
        self.threshold, self.chunk_size = threshold, chunk_size
        self.fingerprint = "%s:%s" % (fingerprint, threshold)

    def __call__(self, text):
        out = []
        for off, piece in chunks(text, self.chunk_size):
            if not piece.strip():
                continue
            for e in self.model.predict_entities(piece, list(self.labels), threshold=self.threshold):
                t = self.labels.get(e["label"])
                if t is None:
                    continue
                out.append(Finding(off + e["start"], off + e["end"], t, "ner:" + e["label"],
                                   float(e["score"]), "ner"))
        return sorted(out, key=lambda f: f.start)


class SpacyBackend(object):
    def __init__(self, nlp, chunk_size=50000, fingerprint="spacy", confidence=0.75):
        self.nlp, self.chunk_size, self.confidence = nlp, chunk_size, confidence
        self.fingerprint = fingerprint

    def __call__(self, text):
        out = []
        for off, piece in chunks(text, self.chunk_size):
            for e in self.nlp(piece).ents:
                t = SPACY_LABELS.get(e.label_)
                if t is not None:
                    out.append(Finding(off + e.start_char, off + e.end_char, t, "ner:" + e.label_,
                                       self.confidence, "ner"))
        return sorted(out, key=lambda f: f.start)


def _model_id(path):
    """Content id of a model directory: names and sizes of its files."""
    items = []
    for dirpath, _, names in os.walk(path):
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            items.append("%s:%d" % (os.path.relpath(p, path), os.path.getsize(p)))
    return hashlib.sha256("\n".join(sorted(items)).encode()).hexdigest()[:16] if items else "empty"


def load_backend(spec, threshold=None):
    """A backend for SPEC, or None for 'none'. Raises on any failure: a
    configured model that cannot be loaded must not silently turn into
    'no names found'."""
    if not spec or spec == "none":
        return None
    kind, _, arg = spec.partition(":")
    if not arg:
        arg = {"gliner": os.environ.get("PII_AIRGAP_MODEL_DIR", "/opt/pii-airgap/model"),
               "spacy": os.environ.get("PII_AIRGAP_SPACY_MODEL", "xx_ent_wiki_sm")}.get(kind, "")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    if kind == "gliner":
        if not os.path.isdir(arg):
            raise RuntimeError("NER model directory %s does not exist" % arg)
        from gliner import GLiNER  # noqa: imported only when configured
        model = GLiNER.from_pretrained(arg, local_files_only=True)
        th = float(threshold if threshold is not None else os.environ.get("PII_AIRGAP_NER_THRESHOLD", "0.5"))
        ident = _model_id(arg)
        try:
            with open(os.path.join(arg, "gliner_config.json")) as f:
                encoder = json.load(f).get("model_name") or ""
        except (OSError, ValueError):
            encoder = ""
        if os.path.isdir(encoder):
            ident += "+" + _model_id(encoder)  # a new encoder revision invalidates the scan cache
        return GlinerBackend(model, threshold=th, fingerprint="gliner:%s:%s" % (os.path.basename(arg.rstrip("/")),
                                                                                  ident))
    if kind == "spacy":
        import spacy  # noqa: imported only when configured
        nlp = spacy.load(arg, exclude=["parser", "tagger", "lemmatizer", "attribute_ruler"])
        return SpacyBackend(nlp, fingerprint="spacy:%s:%s" % (arg, nlp.meta.get("version", "?")))
    raise ValueError("unknown NER backend %r (use gliner:<dir>, spacy:<name> or none)" % spec)
