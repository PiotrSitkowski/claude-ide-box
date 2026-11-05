# Contributing

Design: `docs/DESIGN.md`. Measured platform facts: `docs/PLATFORM-NOTES.md` (they win over the
design where the two differ).

## Language and style
- Everything in the repository is in English: code, comments, docs, commit messages, PRs.
- Plain hyphens (-) in prose, not em dashes.

## Shell
- Scripts must run on **bash 3.2** (macOS default) and on both GNU and BSD userlands. Not allowed:
  associative arrays, `mapfile`/`readarray`, `${var,,}`, `[[ -v ]]`, `wait -n`, `flock`, `timeout`,
  `sed -i` without a suffix argument, `stat -c`, `date -d`, `readlink -f`.
- `set -euo pipefail` in every script. `shellcheck` must pass; any disabled check carries a
  comment explaining why.
- `bin/claude-ide-box-exec` writes nothing to stdout except the stdout of the process in the
  container. Diagnostics go to the log file and stderr.
- Fail closed: every error path ends in a non-zero exit, never in running something on the host.

## Security invariants
- Never mount the Docker socket or the host home directory into a container.
- Never mount ~/.ssh, ~/.aws, ~/.gitconfig, credential helpers or IDE IPC sockets.
- Configuration that controls the sandbox lives outside the project directory.
- A change that weakens isolation needs an explicit write-up in the PR, not a workaround.

## Tests
- `shellcheck` on all scripts; unit tests with a fake `docker` on PATH; CI on ubuntu-latest and
  macos-latest.
- Integration tests need a real Docker daemon. Without one they skip and say so - they never pass
  silently.
