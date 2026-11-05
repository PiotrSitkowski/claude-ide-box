# Testing

What is verified automatically, where, and what still needs a person at a real machine.

| Layer | Command | Runs on | Needs |
|---|---|---|---|
| Static analysis | `shellcheck -x ...` (see CI) | CI, locally | shellcheck |
| Unit | `tests/run-unit.sh [filter]` | Linux, macOS, bash 3.2 and 5 | nothing but bash |
| Integration | `tests/integration/run.sh` | anywhere with a Docker daemon | Docker, network to build images |
| Manual | [checklist below](#manual-checklist) | a real desktop with an IDE | a Claude subscription |

## Unit tests

Plain bash, no framework: `tests/run-unit.sh` runs every `test_*` function in
`tests/unit/test_*.sh`, each in a fresh subshell with a private `HOME`, XDG directories and a fake
`docker` first on `PATH` (`tests/unit/fake-bin/docker`). The fake records every call, emulates
`inspect`/`run`/`exec`/`build`/`network`/`logs`, and deliberately prints noise on stdout so the
stdout-cleanliness tests mean something. A `claude` on `PATH` records if anything ever executes it
on the "host".

**Why not bats-core.** The scripts must run on the bash 3.2 that ships with macOS, and the tests
must prove it. A 100-line harness runs on stock `/bin/bash` 3.2 with BSD tools and on busybox
without installing anything, so the macOS CI job tests exactly what users run. bats would add a
dependency to install on every runner for no extra coverage.

| File | Covers |
|---|---|
| `test_wrapper.sh` | dropping 0, 1 and 2 leading paths; subcommands and `/slash` prompts kept; stdout carries only the container's output; exit status and stdin passed through; container name and sanitisation; identical mount path; hardening flags; masks only for existing files (nested, directories, PrestaShop preset); read-only directories created with normal permissions; `GIT_WRITABLE`; recreate on a new secret file, refusal while a session is active; fail closed without daemon, without docker, without image, for `/`, `$HOME` and its parents; environment passed by name only with deny list and host-path filter; token never on a command line or in the log; host-path flags dropped, inline JSON kept, `..` escapes caught; parallel starts create one container; stale lock removal; invocation through a guard symlink; unknown config key fails closed; CPU clamping; automatic guard; paths with commas, quotes or newlines refused before `docker run` (mount-option injection); a symlinked secret is masked at the logical path when the project path itself contains a symlink; prompts that contain paths are not dropped; `~`-relative env values are not passed; invalid `MEMORY`/`CPUS`/`TMP_SIZE`/UID settings rejected; an active session is recognised for both `claude` and `claude.exe`; nested `.git` directories and files read-only, a new one triggers recreation; masks found inside `node_modules` and `vendor`; a masked file moved away (renamed parent) or replaced by a decoy stops the start until `up --recreate`; `.env` templates (`.env.example`, `.env.sample`, `.env.template`, `.env.dist`) not masked by default, masked again through `MASK` or an empty `MASK_EXCEPT`, exceptions never unmask `MASK` or preset entries, a template masked by an older version does not trip the mask record while a moved `.env` still does |
| `test_cli.sh` | `guard` on both bundled-binary layouts and several versions, idempotence, `--undo`, six concurrent runs keeping the original binary; `allow` validation and proxy reload; presets (`php`, `github` warning, `prestashop` per project); generated allowlist; `setup` (internal network with `inhibit_ipv4`, proxy attached at its fixed IP, UID/GID and version build args, profiles, build failure, no daemon); `up`, `up --recreate`, `down`, `rm`, `rm --volume`, `shell`, `status`, `logs` (denied-domain summary sorted by count, `allow` or `preset` hint including the user's presets, "allowed now" for domains allowed since, explanations for IPs, plain HTTP and other ports, no colour codes off a terminal); `login --token-stdin` (mode 600, rejects garbage); `doctor` (healthy host, `useTerminal: true`, wrapper unset, legacy key, commented-out key, unguarded binary, `claude` running on the host, `claude` on PATH, no daemon, non-internal network, `git.autoRepositoryDetection` warning); modules: profile chains (`env:a.b`), user profiles and presets in `~/.config`, `profile`/`profiles`/`presets` commands, the current project's profiles built by `setup`, an unknown profile failing closed, a profile image with root-owned files in `/home/claude` rejected; `forward`: port validation, a TCP connection relayed through `docker exec ... socat`, loopback-only listener; `quickstart`: all six steps with a chosen profile (built and set for the project), a pasted token, guard, a settings file created only where none existed, doctor last; a second run that rebuilds nothing and changes nothing; no Docker daemon, a failing build or closed stdin stop the run before anything later happens; an unknown profile is asked again; an existing JSONC settings file is never modified and can be opened in `$EDITOR`; the API-key choice stores nothing |
| `test_engines.sh` | Docker's run options unchanged; Podman: DNS-less internal network instead of `inhibit_ipv4`, `--read-only-tmpfs=false`, `/dev/shm` tmpfs, `--http-proxy=false`, `notmpcopyup` on masked directories (and not on Docker), CPU count from `.Host.CPUs`, doctor's network check; rootless Podman gets `--userns=keep-id` (also for setup's image check); refused without fail-open: rootless Podman on cgroup v1, a missing `pids` controller, the CNI backend, rootless Docker, a Docker engine that does not enforce limits - no container is created and stdout stays empty; an engine name without a path; every image reference fully qualified |
| `test_try.sh` | `up --try`: copy mounted at the project's own path in a separate `-try` container and home volume, masks and read-only mounts applied to the copy, secrets (also those reached through an absolute symlink) emptied in the copy, the wrapper switching to the session and resuming it; `try diff`; `try apply`: modifications, additions in new directories, deletions, executable bit, container removed before anything is read, session cleaned up; never writes masked, read-only or nested `.git` paths; conflicts block everything, `--skip-conflicts` applies the rest and keeps Claude's version; identical changes are not conflicts; symlinks applied as links and never followed, also when a directory of the copy is replaced by a link to a host directory; no writes through a symlinked project directory; FIFOs skipped; a deleted directory keeps files the user added; `try discard`, `try end`; no session, no Docker daemon and a copy path with a comma all fail closed; a symlinked cache path works |
| `test_install.sh` | install, settings snippet, idempotence, refusing to overwrite foreign files, no sudo, `--uninstall` undoes guard and keeps config, `--prefix` |
| `test_integration_skip.sh` | the integration suite says SKIPPED without Docker and fails when `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` |

### Results

| Environment | Result |
|---|---|
| Ubuntu 24.04, GNU bash 5.2, GNU coreutils | 123 passed, 0 failed |
| `bash:3.2` image (bash 3.2.57, musl, busybox userland) | 123 passed, 0 failed (the `forward` test reports SKIPPED: no perl in that image) |
| CI: ubuntu-latest, macos-latest with `/bin/bash` 3.2 forced, `bash:3.2` | 123 passed, 0 failed in each (run 22, commit `49e5465`) |

The wrapper and the CLI were written test-first: each stage's tests were committed in the same
commit as the code, but were run red before the implementation existed (35 of 39 wrapper tests and
30 of 36 CLI tests failed; the remaining ones were refusal checks that a missing script also
"passes"), then green. The same applies to the fixes from the security review: 7 tests for mount
injection, nested repositories and mask escapes, then a decoy-replacement test, were red before the
fixes, and so were the 8 tests for the code review findings. One of them is worth noting: six
concurrent `guard` runs made one process `chmod a-x` a `.orig` that another had just turned into
a symlink, which removed the execute bit from the real wrapper.

## Integration tests

`tests/integration/run.sh` builds the images, runs `claude-ide-box setup` in its own namespace
(`CLAUDE_IDE_BOX_INSTANCE=cbit`, subnet `172.30.98.0/24`, a throw-away `HOME`), so it never touches a
real installation, and then checks from inside real containers:

| Requirement | Checks |
|---|---|
| (a) proxy | allowed domain passes; other domain gets 403; plain HTTP, bare IPs and ports other than 443 get 403; direct connections and raw TCP fail; no default route |
| (b) DNS | external names do not resolve |
| (c) masks | `.env` empty and read-only, `.env.d/` empty, host file untouched, `.env.example` readable; a `.env.local` created later is masked after the next start |
| (d) read-only | writes to `.git/hooks`, `.git/config`, `.vscode`, `.idea`, `.devcontainer`, `.agent` fail; `.git` cannot be removed, `.vscode` cannot be renamed |
| (e) ownership | writing the project works; new files belong to the host UID |
| (f) privileges | `CapEff` and `CapBnd` zero, `NoNewPrivs` 1, non-root, no `docker.sock`, read-only rootfs, no sudo, pids/memory limits and `--init`, home not mounted |
| (g) wrapper | `claude-ide-box-exec /fake/native-binary/claude --version` prints exactly one line, the version |
| extra | host listeners unreachable on the internal gateway and `docker0` (with a positive control from the default bridge); Claude Code's API request goes through squid without DNS (tunnel count in the squid log rises, the API answers "Invalid API key" to a fake key); squid runs without capabilities as `proxy` on a read-only rootfs; `claude-ide-box logs` shows the denial and suggests `claude-ide-box allow example.com`; one project's `~/.claude` and files are invisible to another; fail closed with an unreachable daemon and for `$HOME` |
| allowlist reload | a domain is refused before `claude-ide-box allow` and passes right after it, and squid confirms the reload (it is signalled with SIGHUP; `squid -k reconfigure` depends on a PID file that `squid -N` does not always write, which made the reload fail on Debian's squid 5.7 in CI) |
| ephemeral mode | `up --try`: `.env` empty and `.git` read-only in the copy's container, no direct network, the project untouched while the container writes the copy, `try diff` shows the change on the host, `try apply` writes it without touching `.env` and removes the container |
| security fixes | a nested `.git` is read-only after the next start; a directory named `q,src=$HOME,dst=...` with a `.env` inside stops the container from being created |
| dev servers | `claude-ide-box forward` serves a server running in the container on `127.0.0.1` of the host; the container still publishes no ports |
| base image | a native npm module compiles with node-gyp (no header download); Python 3 with venv |
| profiles (`CLAUDE_IDE_BOX_IT_PROFILES`) | `php`: PHP 8.3 with the PrestaShop extensions, MariaDB client, composer via packagist; `python`: uv installs from PyPI; `go`: a module from proxy.golang.org; `rust`: `cargo add` + `cargo build` from crates.io; `java`: Maven fetches from Maven Central through the proxy settings; `office`: Markdown -> DOCX -> PDF -> text, an `.xlsx` formula recalculated by LibreOffice, a `.docx` edited in place, Polish OCR; `go` + `python` combined in one container. All package downloads go through the proxy without DNS, each with only its own preset enabled |

Without a Docker daemon the script prints a banner saying **INTEGRATION TESTS SKIPPED** and that
nothing was verified; with `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` (as in CI) that is a failure.

### Where they ran

**Development sandbox - 69 passed, 0 failed, 0 skipped** with `CLAUDE_IDE_BOX_IT_PROFILES="python go
java office"`, and 64 passed with `"python go"` after the combined-profile check was fixed (see
below). Native Docker Engine 29.9.2 on Linux
(cgroup v1, containerd snapshotter), tests run as an unprivileged user (UID 30033) in the `docker`
group. That sandbox's network policy differs from a normal machine, so three settings were used,
all through regular configuration keys rather than test-only code paths:

| Setting | Why |
|---|---|
| `BASE_IMAGE` = Ubuntu 24.04 + Node 22 from `node:22-bookworm-slim` + the sandbox's TLS CA | Debian mirrors (`deb.debian.org`) are blocked there; only `archive.ubuntu.com` is reachable. The Dockerfile is unchanged; this also exercised the UID-collision path (Ubuntu ships a `ubuntu` user with UID 1000). |
| `PROXY_BASE_IMAGE=ubuntu:24.04`, `BUILD_NETWORK=host` | same reason |
| `UPSTREAM_PROXY=172.17.0.1:3129` | the sandbox has no direct egress; squid forwarded to the sandbox's own egress proxy (which re-terminates TLS, hence the CA above) |

The `php` and `rust` profiles were **not** built there: `php` needs Debian packages from mirrors
the sandbox cannot reach, and `rustup` in the rust build stage does not trust the sandbox's TLS
interception CA.

**CI (ubuntu-latest) - 77 passed, 0 failed, 0 skipped** (run 22, commit `49e5465`): the same suite
with the real Debian-based images, direct egress and all six profiles - `php` (PHP 8.3.36),
`python`, `go`, `rust`, `java`, `office` - each downloading its packages through the proxy without
DNS, plus `go` and `python` combined in one container through the user's flow (`profile python go`,
`setup`, start). An earlier run (75 passed) had silently skipped that combined check because of a
`case` pattern with overlapping spaces; it now runs.

Earlier CI runs caught things this sandbox could not: the IDE settings path on macOS in the doctor
tests, the squid reload failing on Debian's squid 5.7, a shellcheck 0.11 warning, the `forward`
message appearing before its socket listened, and a lock race in which a waiter could remove a live
lock whose holder had not written its pid yet (now reproduced deterministically by a unit test).

### Running them yourself

```bash
tests/integration/run.sh
```

Optional environment: `CLAUDE_IDE_BOX_IT_PROFILES=php`, `CLAUDE_IDE_BOX_IT_KEEP=1` (keep containers for
inspection), `CLAUDE_IDE_BOX_IT_BASE_IMAGE`, `CLAUDE_IDE_BOX_IT_PROXY_BASE_IMAGE`,
`CLAUDE_IDE_BOX_IT_BUILD_NETWORK`, `CLAUDE_IDE_BOX_IT_UPSTREAM_PROXY`, `CLAUDE_IDE_BOX_IT_SUBNET`.

## Not verified automatically

| Item | Why |
|---|---|
| Subscription login (`claude-ide-box login`) | needs a real account and a browser |
| The IDE extension driving the wrapper | needs a desktop IDE; only the wrapper's contract (argv, stdout, exit codes, stdin) is tested |
| Docker Desktop (macOS, Windows/WSL2) | no Docker Desktop in CI. Its VM, file sharing, ownership mapping and DNS layer differ from native Linux; in particular `inhibit_ipv4`, `--dns 127.0.0.1` on an internal network and bind-mounting a file over a project path need checking there |
| Apple Silicon | images are multi-arch by construction (all bases are), not built on arm64 in CI |
| macOS `ps`, `/bin/bash` 3.2 against real IDE settings paths | unit tests run on macOS but with fake extension and settings directories |

## Manual checklist

Run after installing on a new machine, and after every extension update that changes launch
behaviour. Tick per platform.

| # | Check | Linux | WSL2 | macOS |
|---|---|:-:|:-:|:-:|
| 1 | `claude-ide-box doctor` passes | ☐ | ☐ | ☐ |
| 2 | After the first message from the panel, `~/.local/state/claude-ide-box/wrapper.log` shows the argv the extension passed (one leading bundled-binary path with 2.1.318) and env names | ☐ | ☐ | ☐ |
| 3 | `ps -A -o pid,args \| grep -i claude` on the host shows only `docker exec ... claude ...`, no native `claude` | ☐ | ☐ | ☐ |
| 4 | Asking Claude to "read ~/.ssh/id_rsa" fails (no such file in the container) | ☐ | ☐ | ☐ |
| 5 | Asking Claude to "curl example.com" fails with a proxy 403; `claude-ide-box logs` shows `TCP_DENIED` | ☐ | ☐ | ☐ |
| 6 | Asking Claude to print `.env` shows an empty file | ☐ | ☐ | ☐ |
| 7 | A file edit from the panel appears in the editor | ☐ | ☐ | ☐ |
| 8 | Diffs and permission prompts work in the panel | ☐ | ☐ | ☐ |
| 9 | Resuming a previous conversation works (history lives in the container volume) | ☐ | ☐ | ☐ |
| 10 | With `claudeProcessWrapper` removed but `guard` applied, the panel still lands in the container (check 3) | ☐ | ☐ | ☐ |
| 11 | Compare panel behaviour with and without the wrapper: with it, the extension treats sessions as "programmatic" and skips a permission-mode migration (PLATFORM-NOTES) - note anything visible | ☐ | ☐ | ☐ |
| 12 | Files created by Claude are owned by you on the host | ☐ | ☐ | ☐ |
| 13 | Quitting Docker: the panel shows an error, nothing runs on the host | ☐ | ☐ | ☐ |
| 14 | Antigravity and "Antigravity IDE" both use the wrapper (separate settings and extension dirs) | - | - | ☐ |
