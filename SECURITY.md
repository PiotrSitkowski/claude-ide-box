# Security policy

pii-airgap handles personal data and parses untrusted documents. Two kinds of bug matter most:
data leaving the machine, and the tool doing something unsafe with what it reads.

## Reporting

Please report privately through **GitHub's private vulnerability reporting** (Security -> Report a
vulnerability) of this repository. Do not open a public issue for anything in "in scope", and never
attach real personal data to a report - reproduce with invented values.

## In scope

| Goal | Examples |
|---|---|
| network access from a pii-airgap container | any way around `--network none` set by `bin/pii-airgap` |
| the token map reaching the agent | the map mounted, copied or printed where the agent's container or project can see it |
| detected values in reports, caches or logs | a value (not a masked preview) in `scan` output, `--json`, the cache, or wrapper messages |
| wrong restoration | a token replaced by a value other than its own; an unknown or altered token replaced at all |
| real values back in front of the agent | `restore` writing real values into the copy without `--in-place`; a recorded copy that holds values of its map and still passes the check Claude IDE Box runs before a start |
| writes outside the target | `anonymise`/`restore` writing through a symlink, outside the given directory, or a file it was not asked to touch |
| code execution on the host | through the wrapper, a crafted file name, list file or report |
| silent failure | a configured model that fails to load, or a document that cannot be read, reported as "no PII" |

## Out of scope

- **Misses.** A value the detector does not find is a quality problem, not a vulnerability. Please
  open a normal issue with an invented example (that is how the rules get better).
- Kernel and container runtime escapes - report those upstream.
- What the AI provider does with data that was sent to it.

## Known limitations

- A compromised parser in the scan container can report "no PII" or write false cache entries.
  It has no network and no map; the effect is the same as a miss.
- `--keep-unresolved` writes unknown and altered tokens into your files as they are, because you
  asked for it.
- The pre-start check in Claude IDE Box only knows copies made with `anonymise` on this machine and
  only finds exact values of the copy's map (whole words, UTF-8 or cp1250). A value the detector
  never found is not in the map, and a value inside a compressed document (DOCX, XLSX, PDF streams)
  is not seen; `anonymise` refuses such documents when the scan finds personal data in them.
- Restoration cannot tell a correct token that the agent copied to a new place from one that
  belongs there; it is restored in both. Review the diff.
