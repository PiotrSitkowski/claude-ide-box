"""Generate docs/assets/architecture-{light,dark}.svg from one template.

    python3 tools/make-diagrams.py

The palette matches Claude IDE Box's diagrams (GitHub's light and dark
colours), so both READMEs look like one family.
"""

import os

LIGHT_TO_DARK = {
    "#0f766e": "#2dd4bf", "#1f2328": "#e6edf3", "#4338ca": "#a5b4fc", "#59636e": "#9198a1",
    "#b42318": "#f87171", "#d0d7de": "#30363d", "#e6f4f1": "#0f2a27", "#eef0fb": "#1b1f3a",
    "#eef2f6": "#10161d", "#f6f8fa": "#151b23", "#fdecea": "#2a1414", "#ffffff": "#0d1117",
}

FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans',Helvetica,Arial,sans-serif"


def box(x, y, w, h, title, lines=(), fill="#ffffff", stroke="#d0d7de", title_fill="#1f2328", sw="1", dash=""):
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    out = ['<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s" stroke="%s" stroke-width="%s"%s/>'
           % (x, y, w, h, fill, stroke, sw, d)]
    ty = y + 24
    if title:
        out.append('<text x="%d" y="%d" font-size="14" font-weight="600" fill="%s">%s</text>' % (x + 16, ty, title_fill, title))
        ty += 20
    for line in lines:
        out.append('<text x="%d" y="%d" font-size="12" fill="#59636e">%s</text>' % (x + 16, ty, line))
        ty += 17
    return "\n".join(out)


def panel(x, y, w, h, label, fill="#f6f8fa", dash=""):
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    return ('<rect x="%d" y="%d" width="%d" height="%d" rx="12" fill="%s" stroke="#d0d7de"%s/>\n'
            '<text x="%d" y="%d" font-size="13" font-weight="600" letter-spacing="1.2" fill="#59636e">%s</text>'
            % (x, y, w, h, fill, d, x + 20, y + 30, label))


def arrow(x1, y1, x2, y2, color="#59636e", marker="arrow", both=False, dash=""):
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    s = ' marker-start="url(#%s)"' % marker if both else ""
    return ('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="2"%s%s marker-end="url(#%s)"/>'
            % (x1, y1, x2, y2, color, d, s, marker))


def label(x, y, text, color="#59636e", weight="400", anchor="start", size=12):
    return ('<text x="%d" y="%d" font-size="%d" font-weight="%s" fill="%s" text-anchor="%s">%s</text>'
            % (x, y, size, weight, color, anchor, text))


def svg():
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1110" height="540" viewBox="0 0 1110 540" '
        'font-family="%s" role="img" aria-labelledby="title desc">' % FONT,
        '<title id="title">pii-airgap architecture</title>',
        '<desc id="desc">On the host, the pii-airgap wrapper starts throw-away containers with no network: '
        'one scans the project read-only and reports which files hold personal data, without the values; '
        'another replaces the values in the try copy with tokens and later puts them back, using a token map '
        'that stays on the host. The AI agent in Claude IDE Box works on the copy and sees only tokens.</desc>',
        '<defs>',
    ]
    for mid, col in (("arrow", "#59636e"), ("arrowA", "#0f766e"), ("arrowP", "#4338ca"), ("arrowR", "#b42318")):
        parts.append('  <marker id="%s" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                     'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="%s"/></marker>' % (mid, col))
    parts.append('</defs>')
    parts.append('<rect width="1110" height="540" rx="14" fill="#ffffff"/>')

    # HOST
    parts.append(panel(20, 20, 300, 500, "HOST"))
    parts.append(box(40, 68, 260, 74, "Your project", ["real names, IBANs, PESELs ...", "never written by a scan"]))
    parts.append(box(40, 172, 260, 92, "pii-airgap", ["paths, checks and mounts only", "never reads file contents",
                                                      "fails closed"], fill="#e6f4f1", stroke="#0f766e",
                     title_fill="#0f766e", sw="1.5"))
    parts.append(arrow(170, 142, 170, 170))
    parts.append(box(40, 294, 260, 74, "Token map", ["~/.local/state/pii-airgap", "mode 600, host only"],
                     fill="#eef0fb", stroke="#4338ca", title_fill="#4338ca", sw="1.5"))
    parts.append(box(40, 388, 260, 56, "Your lists", ["~/.config/pii-airgap/lists"], dash="4 3"))
    parts.append(label(40, 474, "Never in a container the agent can see:", weight="600"))
    parts.append(label(40, 494, "the token map · your lists · the scan cache"))

    # AIR-GAPPED CONTAINERS
    parts.append(panel(360, 20, 380, 500, "THROW-AWAY CONTAINERS"))
    parts.append('<rect x="378" y="62" width="344" height="24" rx="6" fill="#fdecea" stroke="#b42318"/>')
    parts.append(label(550, 79, "--network none · read-only · no capabilities · your UID", color="#b42318",
                       weight="600", anchor="middle"))
    parts.append(box(378, 100, 344, 186, "scan", [
        "project mounted read-only, no token map",
        "text: DOCX · XLSX · PDF · OCR · LibreOffice",
        "", "1  checksums: IBAN, cards, PESEL, NIP, ...",
        "2  patterns with context words",
        "3  your lists",
        "4  local NER model, baked into the image"]))
    parts.append(label(394, 270, "report: types, lines, confidence - no values", color="#0f766e", weight="600"))
    parts.append(box(378, 304, 344, 130, "pseudonymise · restore", [
        "plain UTF-8 text only, no document parsers",
        "Jan Kowalski  →  [PERSON_1]",
        "restore: exact known tokens only;",
        "unknown or altered ones stop it"]))
    parts.append(label(394, 466, "Nothing can be downloaded or sent:", weight="600"))
    parts.append(label(394, 486, "the model is part of the image."))
    parts.append(arrow(300, 210, 376, 190, "#0f766e", "arrowA"))
    parts.append(arrow(300, 330, 376, 360, "#4338ca", "arrowP", both=True))

    # CLAUDE IDE BOX
    parts.append(panel(780, 20, 310, 500, "CLAUDE IDE BOX (optional)", fill="#f6f8fa"))
    parts.append(box(798, 84, 274, 92, "try copy", ["[PERSON_1], [IBAN_1], [PESEL_1]", "documents with PII masked",
                                                   ".git removed"]))
    parts.append(arrow(722, 370, 796, 140, "#4338ca", "arrowP"))
    parts.append(arrow(935, 176, 935, 214))
    parts.append(box(798, 216, 274, 92, "Claude Code container", ["sees tokens, not values",
                                                                  "told to keep tokens intact"]))
    parts.append(arrow(935, 308, 935, 346, "#b42318", "arrowR"))
    parts.append(box(798, 348, 274, 74, "AI provider", ["receives tokens - and anything", "the detectors missed"],
                     fill="#fdecea", stroke="#b42318", title_fill="#b42318", sw="1.5"))
    parts.append(label(798, 456, "try apply: values restored on the host,", weight="600"))
    parts.append(label(798, 476, "then the changes reach your files"))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "assets")
    light = svg()
    dark = light
    for i, a in enumerate(LIGHT_TO_DARK):
        dark = dark.replace(a, "@%d@" % i)
    for i, b in enumerate(LIGHT_TO_DARK.values()):
        dark = dark.replace("@%d@" % i, b)
    with open(os.path.join(here, "architecture-light.svg"), "w") as f:
        f.write(light)
    with open(os.path.join(here, "architecture-dark.svg"), "w") as f:
        f.write(dark)


if __name__ == "__main__":
    main()
