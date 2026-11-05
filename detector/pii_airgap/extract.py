"""Text extraction for scanning.

Office Open XML and OpenDocument files are read as ZIP archives with size
limits (no XML parser, no macros, nothing executed). PDFs go through
pdftotext, scans through pdftoppm + tesseract, legacy formats through
LibreOffice headless. Every external tool runs with a timeout; a missing
tool is an error, never a silent "no PII".
"""

import html
import os
import re
import shutil
import subprocess
import tempfile
import zipfile

DEFAULT_MAX_BYTES = 50 * 1024 * 1024
OCR_LANGS = os.environ.get("PII_AIRGAP_OCR_LANGS", "pol+eng+deu")
TIMEOUT = int(os.environ.get("PII_AIRGAP_TOOL_TIMEOUT", "300"))

OOXML_TEXT = {
    ".docx": (r"^word/(document|header\d*|footer\d*|footnotes|endnotes|comments)\.xml$", "docx"),
    ".docm": (r"^word/(document|header\d*|footer\d*|footnotes|endnotes|comments)\.xml$", "docx"),
    ".dotx": (r"^word/(document|header\d*|footer\d*|footnotes|endnotes|comments)\.xml$", "docx"),
    ".pptx": (r"^ppt/(slides/slide\d+|notesSlides/notesSlide\d+)\.xml$", "pptx"),
    ".odt": (r"^content\.xml$", "odf"),
    ".ods": (r"^content\.xml$", "odf"),
    ".odp": (r"^content\.xml$", "odf"),
}
LEGACY = {".doc": "txt:Text", ".rtf": "txt:Text", ".wpd": "txt:Text", ".xls": "csv", ".ppt": "txt:Text"}
IMAGES = (".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp")


class ExtractionError(Exception):
    pass


class Extracted(object):
    __slots__ = ("text", "method")

    def __init__(self, text, method):
        self.text, self.method = text, method


def _zip_read(z, name, budget):
    with z.open(name) as f:
        data = f.read(budget[0] + 1)
    if len(data) > budget[0]:
        raise ExtractionError("archive member %s expands beyond the size limit" % name)
    budget[0] -= len(data)
    return data.decode("utf-8", errors="replace")


def _xml_text(xml):
    xml = re.sub(r"<w:tab/>|<text:tab/>|<w:tab [^>]*/>", "\t", xml)
    xml = re.sub(r"</w:p>|</a:p>|<w:br/>|<w:br [^>]*/>|</text:p>|</text:h>|<text:line-break/>|</table:table-row>",
                 "\n", xml)
    xml = re.sub(r"</table:table-cell>", "\t", xml)
    return html.unescape(re.sub(r"<[^>]*>", "", xml))


def _xlsx(z, budget):
    names = z.namelist()
    shared = []
    if "xl/sharedStrings.xml" in names:
        for si in re.findall(r"<si>(.*?)</si>", _zip_read(z, "xl/sharedStrings.xml", budget), re.S):
            shared.append(html.unescape("".join(re.findall(r"<t[^>]*>(.*?)</t>", si, re.S))))
    out = []
    for n in sorted(x for x in names if re.match(r"^xl/worksheets/sheet\d+\.xml$", x)):
        for row in re.findall(r"<row[^>]*>(.*?)</row>", _zip_read(z, n, budget), re.S):
            cells = []
            for attrs, body in re.findall(r"<c([^>]*?)(?:/>|>(.*?)</c>)", row, re.S):
                v = re.search(r"<v>(.*?)</v>", body or "", re.S)
                if 't="s"' in attrs and v:
                    i = int(v.group(1))
                    cells.append(shared[i] if 0 <= i < len(shared) else "")
                elif v:
                    cells.append(html.unescape(v.group(1)))
                else:
                    cells.append(html.unescape("".join(re.findall(r"<t[^>]*>(.*?)</t>", body or "", re.S))))
            out.append("\t".join(cells))
    for n in sorted(x for x in names if re.match(r"^xl/comments\d*\.xml$", x)):
        out.append(_xml_text(_zip_read(z, n, budget)))
    return "\n".join(out)


def _zip_doc(path, ext, max_bytes):
    budget = [max_bytes]
    try:
        with zipfile.ZipFile(path) as z:
            if ext in (".xlsx", ".xlsm"):
                return Extracted(_xlsx(z, budget), "xlsx")
            pattern, method = OOXML_TEXT[ext]
            parts = [_xml_text(_zip_read(z, n, budget)) for n in z.namelist() if re.match(pattern, n)]
            return Extracted("\n".join(parts), method)
    except (zipfile.BadZipFile, KeyError, ValueError) as e:
        raise ExtractionError("cannot read %s as a %s archive: %s" % (path, ext, e))


def _run(cmd, **kw):
    if shutil.which(cmd[0]) is None:
        raise ExtractionError("%s is not installed (use the pii-airgap image)" % cmd[0])
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT,
                              check=True, **kw).stdout
    except subprocess.TimeoutExpired:
        raise ExtractionError("%s timed out" % cmd[0])
    except subprocess.CalledProcessError as e:
        raise ExtractionError("%s failed: %s" % (cmd[0], e.stderr.decode("utf-8", "replace").strip()[:200]))


def _ocr_images(images):
    out = []
    for img in images:
        out.append(_run(["tesseract", img, "-", "-l", OCR_LANGS]).decode("utf-8", "replace"))
    return "\n".join(out)


def _pdf(path):
    text = _run(["pdftotext", "-enc", "UTF-8", path, "-"]).decode("utf-8", "replace")
    pages = text.split("\f")
    if pages and pages[-1].strip() == "":
        pages = pages[:-1] or [""]
    empty = [i + 1 for i, p in enumerate(pages) if not p.strip()]
    if not empty:
        return Extracted(text, "pdftotext")
    # Pages without a text layer are probably scans: render and OCR them.
    with tempfile.TemporaryDirectory() as tmp:
        for n in empty:
            _run(["pdftoppm", "-r", "200", "-png", "-f", str(n), "-l", str(n), path, os.path.join(tmp, "p%05d" % n)])
        images = sorted(os.path.join(tmp, x) for x in os.listdir(tmp))
        ocr = _ocr_images(images)
    return Extracted(text + "\n" + ocr, "pdftotext+ocr")


def _legacy(path, ext):
    with tempfile.TemporaryDirectory() as tmp:
        profile = "file://" + os.path.join(tmp, "profile")
        _run(["soffice", "-env:UserInstallation=" + profile, "--headless", "--convert-to", LEGACY[ext],
              "--outdir", tmp, path])
        outs = [n for n in os.listdir(tmp) if n != "profile"]
        if not outs:
            raise ExtractionError("LibreOffice produced no output for %s" % path)
        with open(os.path.join(tmp, outs[0]), "rb") as f:
            return Extracted(f.read().decode("utf-8", "replace"), "libreoffice")


def extract_text(path, max_bytes=DEFAULT_MAX_BYTES):
    """Extracted(text, method), or None for binary files that are not a
    supported document type. Raises ExtractionError when a supported file
    cannot be read."""
    ext = os.path.splitext(path)[1].lower()
    size = os.path.getsize(path)
    if ext in OOXML_TEXT or ext in (".xlsx", ".xlsm"):
        return _zip_doc(path, ext, max_bytes)
    if size > max_bytes:
        raise ExtractionError("larger than the %d byte limit" % max_bytes)
    if ext == ".pdf":
        return _pdf(path)
    if ext in IMAGES:
        return Extracted(_ocr_images([path]), "ocr")
    if ext in LEGACY:
        return _legacy(path, ext)
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data[:8192]:
        return None
    try:
        return Extracted(data.decode("utf-8"), "text")
    except UnicodeDecodeError:
        return Extracted(data.decode("cp1250", errors="replace"), "text-cp1250")
