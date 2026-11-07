"""Source code: where its free text is. The NER model reads only string
literals and comments of a code file; identifiers, keywords and the rest are
code, and a model reading them finds "people" in class names.

The comment and string syntax of each language is data (SYNTAX below), chosen
by file extension."""

_C_BLOCK = (("/*", "*/"),)

# line: line-comment markers; block: (open, close) pairs; quotes: string
# delimiters that end at the line end; multiline: delimiters that may span
# lines (triple quotes, template literals, raw strings).
SYNTAX = {
    "python": {"line": ("#",), "block": (), "quotes": ('"', "'"), "multiline": ('"""', "'''")},
    "shell": {"line": ("#",), "block": (), "quotes": ('"', "'"), "multiline": ()},
    "c": {"line": ("//",), "block": _C_BLOCK, "quotes": ('"', "'"), "multiline": ()},
    "js": {"line": ("//",), "block": _C_BLOCK + (("<!--", "-->"),), "quotes": ('"', "'"), "multiline": ("`",)},
    "go": {"line": ("//",), "block": _C_BLOCK, "quotes": ('"',), "multiline": ("`",)},
    # ' starts a character literal or a lifetime ('a): no free text in either.
    "rust": {"line": ("//",), "block": _C_BLOCK, "quotes": ('"',), "multiline": ()},
    "php": {"line": ("//", "#"), "block": _C_BLOCK, "quotes": ('"', "'"), "multiline": ()},
    "sql": {"line": ("--",), "block": _C_BLOCK, "quotes": ("'", '"'), "multiline": ()},
    "lua": {"line": ("--",), "block": (("--[[", "]]"),), "quotes": ('"', "'"), "multiline": ()},
    "haskell": {"line": ("--",), "block": (("{-", "-}"),), "quotes": ('"',), "multiline": ()},
    "erlang": {"line": ("%",), "block": (), "quotes": ('"',), "multiline": ()},
    "powershell": {"line": ("#",), "block": (("<#", "#>"),), "quotes": ('"', "'"), "multiline": ()},
}

EXTENSIONS = {
    ".py": "python", ".pyi": "python",
    ".sh": "shell", ".bash": "shell", ".zsh": "shell", ".rb": "shell", ".pl": "shell", ".r": "shell",
    ".ex": "shell", ".exs": "shell", ".yaml": None, ".yml": None,
    ".c": "c", ".h": "c", ".cc": "c", ".cpp": "c", ".hpp": "c", ".cs": "c", ".java": "c", ".kt": "c",
    ".kts": "c", ".scala": "c", ".swift": "c", ".dart": "c", ".m": "c",
    ".js": "js", ".mjs": "js", ".cjs": "js", ".jsx": "js", ".ts": "js", ".tsx": "js", ".vue": "js",
    ".svelte": "js",
    ".go": "go", ".rs": "rust", ".php": "php", ".sql": "sql", ".lua": "lua", ".hs": "haskell",
    ".erl": "erlang", ".ps1": "powershell",
}


def syntax_for(ext):
    """The syntax name for a file extension, or None for text."""
    return EXTENSIONS.get(ext.lower())


def resolve(code):
    """A syntax name from a syntax name or a file extension."""
    if code in SYNTAX:
        return code
    syntax = syntax_for(code)
    if syntax is None:
        raise ValueError("no source-code syntax for %r" % code)
    return syntax


def code_spans(text, syntax):
    """(start, end) of the string literals and comments of TEXT, in order."""
    s = SYNTAX[syntax]
    line, block, quotes, multi = s["line"], s["block"], s["quotes"], s["multiline"]
    spans = []
    i, n = 0, len(text)
    while i < n:
        for open_, close in block:
            if text.startswith(open_, i):
                j = text.find(close, i + len(open_))
                j = n if j < 0 else j + len(close)
                spans.append((i, j))
                i = j
                break
        else:
            hit = next((m for m in line if text.startswith(m, i)), None)
            if hit is not None:
                j = text.find("\n", i)
                j = n if j < 0 else j
                spans.append((i, j))
                i = j
                continue
            q = next((m for m in multi if text.startswith(m, i)), None)
            if q is not None:
                j = i + len(q)
                while j < n and not text.startswith(q, j):
                    j += 2 if text[j] == "\\" else 1
                j = min(n, j + len(q))
                spans.append((i, j))
                i = j
                continue
            c = text[i]
            if c in quotes:
                j = i + 1
                while j < n and text[j] != c and text[j] != "\n":
                    j += 2 if text[j] == "\\" else 1
                j = min(n, j + 1)
                spans.append((i, j))
                i = j
                continue
            i += 1
    return spans


class Projection(object):
    """The strings and comments of a file joined into one text (separated by
    blank lines), so a model runs once per file, with a way back to the
    original offsets."""

    def __init__(self, text, syntax):
        parts, self.pieces = [], []  # (projection start, original start, length)
        pos = 0
        for a, b in code_spans(text, syntax):
            if not any(ch.isalpha() for ch in text[a:b]):
                continue
            self.pieces.append((pos, a, b - a))
            parts.append(text[a:b])
            pos += b - a + 2
        self.text = "\n\n".join(parts)

    def to_original(self, start, end):
        """(start, end) in the original text, or None when the range does not
        lie inside one piece."""
        for p, o, length in self.pieces:
            if p <= start < p + length:
                return o + start - p, o + min(end, p + length) - p
        return None
