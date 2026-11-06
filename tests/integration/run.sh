#!/bin/bash
# shellcheck disable=SC2016 # the single-quoted sh -c scripts expand their own $1, $2
# Integration tests against a real container engine and a built image.
#   PII_AIRGAP_IMAGE=pii-airgap:spacy tests/integration/run.sh
# Without an engine or the image the suite says SKIPPED and exits 0, unless
# PII_AIRGAP_REQUIRE_DOCKER=1 (CI), where that is a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PA="$ROOT/bin/pii-airgap"
IMAGE="${PII_AIRGAP_IMAGE:-pii-airgap:latest}"
ENGINE="${PII_AIRGAP_DOCKER:-docker}"
export PII_AIRGAP_IMAGE="$IMAGE"
pass=0
failn=0

skip() {
  if [ "${PII_AIRGAP_REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAILED: $*" >&2
    exit 1
  fi
  echo "SKIPPED: $*"
  exit 0
}

ok() {
  pass=$((pass + 1))
  echo "ok   $*"
}

bad() {
  failn=$((failn + 1))
  echo "FAIL $*"
}

check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

command -v "$ENGINE" >/dev/null 2>&1 || skip "no $ENGINE"
"$ENGINE" info >/dev/null 2>&1 || skip "$ENGINE is not running"
"$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || skip "image $IMAGE not built (pii-airgap build)"
NER="$("$ENGINE" run --rm --entrypoint sh "$IMAGE" -c 'echo $PII_AIRGAP_NER')"
echo "image $IMAGE, NER=$NER"

tmpbase="${TMPDIR:-/tmp}"
T="$(mktemp -d "${tmpbase%/}/pii-airgap-it.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state"
mkdir -p "$HOME"
P="$T/proj"
mkdir -p "$P/docs" "$P/src"

# ------------------------------------------------------------ fixtures
printf 'Klient: Jan Kowalski\nPESEL 44051401359\nkonto PL61 1090 1014 0000 0712 1981 2874\n' >"$P/notes.txt"
printf 'nothing personal here\n' >"$P/clean.txt"
printf 'OWNER = "anna.nowak@example.com"\n' >"$P/src/config.py"
python3 - "$P" <<'EOF'
import os, sys, zipfile
p = sys.argv[1]
with zipfile.ZipFile(os.path.join(p, "docs/umowa.docx"), "w") as z:
    z.writestr("[Content_Types].xml", "<Types/>")
    z.writestr("word/document.xml", '<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Najemca: Piotr Nowak, '
               'IBAN DE89 3704 0044 0532 0130 00</w:t></w:r></w:p></w:body></w:document>')
with zipfile.ZipFile(os.path.join(p, "docs/lista.xlsx"), "w") as z:
    z.writestr("xl/sharedStrings.xml", '<sst><si><t>karta</t></si></sst>')
    z.writestr("xl/worksheets/sheet1.xml", '<worksheet><sheetData><row><c t="s"><v>0</v></c>'
               '<c t="inlineStr"><is><t>4111 1111 1111 1111</t></is></c></row></sheetData></worksheet>')
stream = "BT /F1 18 Tf 72 700 Td (SSN 123-45-6789) Tj ET"
objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out, offs = "%PDF-1.4\n", []
for i, o in enumerate(objs, 1):
    offs.append(len(out)); out += "%d 0 obj\n%s\nendobj\n" % (i, o)
x = len(out)
out += "xref\n0 6\n0000000000 65535 f \n" + "".join("%010d 00000 n \n" % o for o in offs)
out += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % x
open(os.path.join(p, "docs/ssn.pdf"), "w", encoding="latin-1").write(out)
EOF
# A scan (PNG of the PDF page) and a legacy .doc, both made inside the image.
"$ENGINE" run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --mount "type=bind,src=$P/docs,dst=/d" --entrypoint sh "$IMAGE" -c '
    pdftoppm -r 150 -png -singlefile /d/ssn.pdf /d/scan &&
    cd /tmp && printf "Najemca: Piotr Nowak, IBAN DE89 3704 0044 0532 0130 00\n" >/tmp/legacy.txt &&
    soffice -env:UserInstallation=file:///tmp/lo --headless --convert-to doc --outdir /d /tmp/legacy.txt >/dev/null 2>&1'
check "fixtures: PNG scan and .doc created" test -s "$P/docs/scan.png" -a -s "$P/docs/legacy.doc"
before="$(cd "$P" && find . -type f -exec cksum {} + | sort)"

# ------------------------------------------------------------ scan
mkdir -p "$XDG_CONFIG_HOME/pii-airgap/lists"
printf 'PERSON: Jan Kowalski\nPERSON: Piotr Nowak\n' >"$XDG_CONFIG_HOME/pii-airgap/lists/people.txt"
json="$("$PA" scan "$P" --json 2>"$T/scan.err")" || bad "scan exit status"
printf '%s\n' "$json" >"$T/scan.json"
counts() {
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); f={x["path"]: x for x in r["files"]}; \
print(" ".join(sorted(f[sys.argv[2]]["counts"])) if sys.argv[2] in f else "-", f[sys.argv[2]]["method"] if sys.argv[2] in f else "")' "$T/scan.json" "$1"
}
# has FILE METHOD TYPE... - FILE was read with METHOD and holds every TYPE
# (a model may add more types; that is scored by the evaluation, not here).
has() {
  local got t
  got=" $(counts "$1") "
  case "$got" in *" $2 "*) ;; *) echo "  $1: $got" >&2; return 1 ;; esac
  shift 2
  for t in "$@"; do
    case "$got" in *" $t "*) ;; *) echo "  missing $t: $got" >&2; return 1 ;; esac
  done
}
check "scan: text file (PESEL, IBAN, list name)" has notes.txt text IBAN PERSON PESEL
check "scan: docx" has docs/umowa.docx docx IBAN PERSON
check "scan: xlsx inline strings" has docs/lista.xlsx xlsx CARD
check "scan: pdf text layer" has docs/ssn.pdf pdftotext SSN
check "scan: OCR of a PNG scan (tesseract pol+eng+deu)" has docs/scan.png ocr SSN
check "scan: legacy .doc through LibreOffice" has docs/legacy.doc libreoffice IBAN PERSON
check "scan: clean file not listed" test "$(counts clean.txt)" = "- "
check "scan: no detected value in the report" sh -c '! grep -q 44051401359 "$1"' _ "$T/scan.json"
check "scan: project unchanged" test "$before" = "$(cd "$P" && find . -type f -exec cksum {} + | sort)"
if [ "$NER" != none ]; then
  check "scan: the model loads and runs with --network none (no list needed)" \
    sh -c 'mkdir -p "$1" && printf "Spotkanie z Hansem Müllerem w Berlinie.\n" >"$1/t.txt" && PII_AIRGAP_LISTS=/nonexistent "$2" scan "$1" --json | grep -q PERSON' _ "$T/m" "$PA"
fi
second="$("$PA" scan "$P" 2>/dev/null | tail -n 1)"
check "scan: unchanged files come from the cache" sh -c 'case "$1" in *" 8 from cache"*) ;; *) exit 1 ;; esac' _ "$second"
check "scan: cache holds no values" sh -c '! grep -rq 44051401359 "$1"' _ "$XDG_CACHE_HOME/pii-airgap"

# ------------------------------------------------------------ try flow
name="$("$PA" container-name --project "$P")"
TR="$XDG_CACHE_HOME/claude-ide-box/try/$name"
mkdir -p "$TR"
cp -pPR "$P" "$TR/work"
cp -pPR "$P" "$TR/base"
mkdir -p "$TR/work/.git"
printf 'Jan Kowalski\n' >"$TR/work/.git/COMMIT_EDITMSG"
set +e
"$PA" try-prepare "$P" >"$T/prep.out" 2>&1
rc=$?
set -e
check "try-prepare: refuses documents with PII (status 3)" test "$rc" = 3
check "try-prepare: names the documents" grep -q "docs/umowa.docx" "$T/prep.out"
check "try-prepare: nothing changed after a refusal" grep -q "Jan Kowalski" "$TR/work/notes.txt"
# What Claude IDE Box's masks would do: blank the masked documents.
for f in docs/umowa.docx docs/lista.xlsx docs/ssn.pdf docs/scan.png docs/legacy.doc; do
  : >"$TR/work/$f"
  : >"$TR/base/$f"
done
"$PA" try-prepare "$P" >"$T/prep.out" 2>&1 || { cat "$T/prep.out"; bad "try-prepare after masking"; }
check "try-prepare: values replaced by tokens" grep -qx 'PESEL \[PESEL_1\]' "$TR/work/notes.txt"
check "try-prepare: list names replaced" grep -qx 'Klient: \[PERSON_1\]' "$TR/work/notes.txt"
check "try-prepare: .git removed from the copy" test ! -e "$TR/work/.git"
check "try-prepare: no value left in the copy" sh -c '! grep -rqE "44051401359|Kowalski|anna.nowak" "$1"' _ "$TR/work"
MAP="$XDG_STATE_HOME/pii-airgap/try/$name.map.json"
# shellcheck disable=SC2012 # mode string of one known file
check "map: mode 600, outside the try root" test "$(ls -l "$MAP" | cut -c1-10)" = "-rw-------"
check "map: holds the values" grep -q 44051401359 "$MAP"
check "try-prepare: files keep the host owner" test "$(find "$TR/work/notes.txt" -user "$(id -u)" | wc -l | tr -d ' ')" = 1

# Claude edits the copy: one good edit, one new file, one altered token.
printf 'Owner: [PERSON_1] / [PESEL_1]\n' >"$TR/work/src/owner.txt"
printf 'OWNER = "[email_1]"\n' >"$TR/work/src/config.py"
set +e
"$PA" try-restore "$P" >"$T/rest.out" 2>&1
rc=$?
set -e
check "try-restore: altered token stops it (status 4)" test "$rc" = 4
check "try-restore: reports file and line" grep -q "src/config.py:1: altered token \[email_1\]" "$T/rest.out"
check "try-restore: nothing restored after a problem" grep -q '\[PESEL_1\]' "$TR/work/notes.txt"
printf 'OWNER = "[EMAIL_1]"\n' >"$TR/work/src/config.py"
"$PA" try-restore "$P" >"$T/rest.out" 2>&1 || { cat "$T/rest.out"; bad "try-restore"; }
check "try-restore: untouched files identical to the snapshot" cmp -s "$TR/work/notes.txt" "$TR/base/notes.txt"
check "try-restore: edited file restored" grep -qx 'OWNER = "anna.nowak@example.com"' "$TR/work/src/config.py"
check "try-restore: new file restored" grep -qx 'Owner: Jan Kowalski / 44051401359' "$TR/work/src/owner.txt"
"$PA" try-forget "$P" 2>/dev/null
check "try-forget: map deleted" test ! -e "$MAP"

# ------------------------------------------------------------ manual flow: a restored folder is never
# opened again. anonymise -> restore must not put real values back into the copy, and Claude IDE Box
# (when its sources with the check are in CLAUDE_IDE_BOX_SRC) must refuse to start in any folder that
# holds values of a recorded map.
O="$T/orig"
mkdir -p "$O"
printf 'Umowa\nKlient PESEL 44051401359\n' >"$O/umowa.txt"
cp -R "$O" "$T/copyA"
"$PA" anonymise "$T/copyA" --map "$T/private/a.json" >/dev/null 2>&1 || bad "anonymise copyA"
check "manual: the copy holds tokens" grep -qx 'Klient PESEL \[PESEL_1\]' "$T/copyA/umowa.txt"
check "manual: verify passes on the tokenised copy" "$PA" verify "$T/copyA"
set +e
"$PA" restore "$T/copyA" --map "$T/private/a.json" >"$T/r.out" 2>&1
rc=$?
set -e
check "manual: restore without a destination is refused" test "$rc" != 0
check "manual: ... and the copy keeps its tokens" grep -qx 'Klient PESEL \[PESEL_1\]' "$T/copyA/umowa.txt"
# The work: a new file with a token, then restore to a new folder.
printf 'Notatka dla [PESEL_1]\n' >"$T/copyA/notatka.txt"
"$PA" restore "$T/copyA" --map "$T/private/a.json" --base "$O" --out "$T/outA" >/dev/null 2>&1 || bad "restore --out"
check "manual: restore --out writes the real values to the new folder" grep -qx 'Notatka dla 44051401359' "$T/outA/notatka.txt"
check "manual: after restore --out the copy still holds no value of the map" "$PA" verify "$T/copyA"
check "manual: ... and still has its tokens" grep -qx 'Notatka dla \[PESEL_1\]' "$T/copyA/notatka.txt"
set +e
"$PA" verify "$T/outA" >"$T/v.out" 2>&1
rc=$?
set -e
check "manual: the restored folder is recorded and fails verify (status 5)" test "$rc" = 5
"$PA" restore "$T/copyA" --map "$T/private/a.json" --base "$O" --into-base >/dev/null 2>&1 || bad "restore --into-base"
check "manual: restore --into-base applies the new file to the original" grep -qx 'Notatka dla 44051401359' "$O/notatka.txt"
check "manual: ... and the copy still holds no value of the map" "$PA" verify "$T/copyA"
# The old way, still possible, now caught.
cp -R "$O" "$T/copyB"
rm -f "$T/copyB/notatka.txt"
"$PA" anonymise "$T/copyB" --map "$T/private/b.json" >/dev/null 2>&1 || bad "anonymise copyB"
"$PA" restore "$T/copyB" --map "$T/private/b.json" --in-place >"$T/r.out" 2>&1 || bad "restore --in-place"
check "manual: restore --in-place warns" grep -q "must not be opened" "$T/r.out"
set +e
"$PA" verify "$T/copyB" >"$T/v.out" 2>/dev/null
rc=$?
set -e
check "manual: verify finds real values after an in-place restore (status 5)" test "$rc" = 5
check "manual: verify names the file, not the value" sh -c 'grep -q "^umowa.txt" "$1" && ! grep -q 44051401359 "$1"' _ "$T/v.out"
CIB="${CLAUDE_IDE_BOX_SRC:-}"
if [ -n "$CIB" ] && [ -f "$CIB/lib/claude-ide-box/pii.sh" ]; then
  for d in copyB outA; do
    set +e
    (cd "$T/$d" && CLAUDE_IDE_BOX_INSTANCE=piiit "$CIB/bin/claude-ide-box-exec" --version) >"$T/w.out" 2>"$T/w.err"
    rc=$?
    set -e
    check "Claude IDE Box refuses to start in $d (restored values)" sh -c '[ "$1" != 0 ] && [ ! -s "$2" ] && grep -q "refusing to start" "$3"' _ "$rc" "$T/w.out" "$T/w.err"
  done
  set +e
  (cd "$T/copyA" && CLAUDE_IDE_BOX_INSTANCE=piiit "$CIB/bin/claude-ide-box-exec" --version) >/dev/null 2>"$T/w.err"
  set -e
  # Without Claude IDE Box's images the start fails later; it must not be the PII refusal.
  check "Claude IDE Box does not refuse the tokenised copy" sh -c '! grep -q "refusing to start" "$1"' _ "$T/w.err"
else
  echo "SKIP Claude IDE Box pre-start check (set CLAUDE_IDE_BOX_SRC to a checkout with lib/claude-ide-box/pii.sh)"
fi

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
