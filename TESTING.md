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
| `test_wrapper.sh` | dropping 0, 1 and 2 leading paths; subcommands and `/slash` prompts kept; stdout carries only the container's output; exit status and stdin passed through; container name and sanitisation; identical mount path; hardening flags; masks only for existing files (nested, directories, PrestaShop preset); read-only directories created with normal permissions; `GIT_WRITABLE`; recreate on a new secret file, refusal while a session is active; fail closed without daemon, without docker, without image, for `/`, `$HOME` and its parents; environment passed by name only with deny list and host-path filter; token never on a command line or in the log; host-path flags dropped, inline JSON kept, `..` escapes caught; parallel starts create one container; stale lock removal; invocation through a guard symlink; unknown config key fails closed; CPU clamping; automatic guard; paths with commas, quotes or newlines refused before `docker run` (mount-option injection); a symlinked secret is masked at the logical path when the project path itself contains a symlink; prompts that contain paths are not dropped; `~`-relative env values are not passed; invalid `MEMORY`/`CPUS`/`TMP_SIZE`/UID settings rejected; an active session is recognised for both `claude` and `claude.exe`; nested `.git` directories and files read-only, a new one triggers recreation; masks found inside `node_modules` and `vendor`; a masked file moved away (renamed parent) or replaced by a decoy stops the start until `up --recreate` |
| `test_cli.sh` | `guard` on both bundled-binary layouts and several versions, idempotence, `--undo`, six concurrent runs keeping the original binary; `allow` validation and proxy reload; presets (`php`, `github` warning, `prestashop` per project); generated allowlist; `setup` (internal network with `inhibit_ipv4`, proxy attached at its fixed IP, UID/GID and version build args, profiles, build failure, no daemon); `up`, `up --recreate`, `down`, `rm`, `rm --volume`, `shell`, `status`, `logs`; `login --token-stdin` (mode 600, rejects garbage); `doctor` (healthy host, `useTerminal: true`, wrapper unset, legacy key, commented-out key, unguarded binary, `claude` running on the host, `claude` on PATH, no daemon, non-internal network, `git.autoRepositoryDetection` warning) |
| `test_install.sh` | install, settings snippet, idempotence, refusing to overwrite foreign files, no sudo, `--uninstall` undoes guard and keeps config, `--prefix` |
| `test_integration_skip.sh` | the integration suite says SKIPPED without Docker and fails when `CLAUDE_BOX_REQUIRE_DOCKER=1` |

### Results

| Environment | Result |
|---|---|
| Ubuntu 24.04, GNU bash 5.2, GNU coreutils | 106 passed, 0 failed |
| `bash:3.2` image (bash 3.2.57, musl, busybox userland) | 106 passed, 0 failed |
| CI: ubuntu-latest, macos-latest with `/bin/bash` 3.2 forced, `bash:3.2` | see the CI badge / pull request checks |

The wrapper and the CLI were written test-first: each stage's tests were committed in the same
commit as the code, but were run red before the implementation existed (35 of 39 wrapper tests and
30 of 36 CLI tests failed; the remaining ones were refusal checks that a missing script also
"passes"), then green. The same applies to the fixes from the security review: 7 tests for mount
injection, nested repositories and mask escapes, then a decoy-replacement test, were red before the
fixes, and so were the 8 tests for the code review findings. One of them is worth noting: six
concurrent `guard` runs made one process `chmod a-x` a `.orig` that another had just turned into
a symlink, which removed the execute bit from the real wrapper.

## Integration tests

`tests/integration/run.sh` builds the images, runs `claude-box setup` in its own namespace
(`CLAUDE_BOX_INSTANCE=cbit`, subnet `172.30.98.0/24`, a throw-away `HOME`), so it never touches a
real installation, and then checks from inside real containers:

| Requirement | Checks |
|---|---|
| (a) proxy | allowed domain passes; other domain gets 403; plain HTTP, bare IPs and ports other than 443 get 403; direct connections and raw TCP fail; no default route |
| (b) DNS | external names do not resolve |
| (c) masks | `.env` empty and read-only, `.env.d/` empty, host file untouched; a `.env.local` created later is masked after the next start |
| (d) read-only | writes to `.git/hooks`, `.git/config`, `.vscode`, `.idea`, `.devcontainer`, `.agent` fail; `.git` cannot be removed, `.vscode` cannot be renamed |
| (e) ownership | writing the project works; new files belong to the host UID |
| (f) privileges | `CapEff` and `CapBnd` zero, `NoNewPrivs` 1, non-root, no `docker.sock`, read-only rootfs, no sudo, pids/memory limits and `--init`, home not mounted |
| (g) wrapper | `claude-box-exec /fake/native-binary/claude --version` prints exactly one line, the version |
| extra | host listeners unreachable on the internal gateway and `docker0` (with a positive control from the default bridge); Claude Code's API request goes through squid without DNS (tunnel count in the squid log rises, the API answers "Invalid API key" to a fake key); squid runs without capabilities as `proxy` on a read-only rootfs; `claude-box logs` shows the denial; one project's `~/.claude` and files are invisible to another; fail closed with an unreachable daemon and for `$HOME` |
| security fixes | a nested `.git` is read-only after the next start; a directory named `q,src=$HOME,dst=...` with a `.env` inside stops the container from being created |
| php profile (`CLAUDE_BOX_IT_PROFILES=php`) | PHP 8.3 with the PrestaShop extensions, MariaDB client, composer reaching packagist through the proxy without DNS |

Without a Docker daemon the script prints a banner saying **INTEGRATION TESTS SKIPPED** and that
nothing was verified; with `CLAUDE_BOX_REQUIRE_DOCKER=1` (as in CI) that is a failure.

### Where they ran

**Development sandbox - 52 passed, 0 failed, 0 skipped.** Native Docker Engine 29.9.2 on Linux
(cgroup v1, containerd snapshotter), tests run as an unprivileged user (UID 30033) in the `docker`
group. That sandbox's network policy differs from a normal machine, so three settings were used,
all through regular configuration keys rather than test-only code paths:

| Setting | Why |
|---|---|
| `BASE_IMAGE` = Ubuntu 24.04 + Node 22 from `node:22-bookworm-slim` + the sandbox's TLS CA | Debian mirrors (`deb.debian.org`) are blocked there; only `archive.ubuntu.com` is reachable. The Dockerfile is unchanged; this also exercised the UID-collision path (Ubuntu ships a `ubuntu` user with UID 1000). |
| `PROXY_BASE_IMAGE=ubuntu:24.04`, `BUILD_NETWORK=host` | same reason |
| `UPSTREAM_PROXY=172.17.0.1:3129` | the sandbox has no direct egress; squid forwarded to the sandbox's own egress proxy (which re-terminates TLS, hence the CA above) |

The php profile was **not** built there: it needs `php:8.3-cli-bookworm` plus Debian packages,
and Debian mirrors are unreachable from that sandbox.

**CI (ubuntu-latest)** runs the same suite with the real Debian-based images, direct egress and the
php profile. See the pull request checks for its result.

### Running them yourself

```bash
tests/integration/run.sh
```

Optional environment: `CLAUDE_BOX_IT_PROFILES=php`, `CLAUDE_BOX_IT_KEEP=1` (keep containers for
inspection), `CLAUDE_BOX_IT_BASE_IMAGE`, `CLAUDE_BOX_IT_PROXY_BASE_IMAGE`,
`CLAUDE_BOX_IT_BUILD_NETWORK`, `CLAUDE_BOX_IT_UPSTREAM_PROXY`, `CLAUDE_BOX_IT_SUBNET`.

## Not verified automatically

| Item | Why |
|---|---|
| Subscription login (`claude-box login`) | needs a real account and a browser |
| The IDE extension driving the wrapper | needs a desktop IDE; only the wrapper's contract (argv, stdout, exit codes, stdin) is tested |
| Docker Desktop (macOS, Windows/WSL2) | no Docker Desktop in CI. Its VM, file sharing, ownership mapping and DNS layer differ from native Linux; in particular `inhibit_ipv4`, `--dns 127.0.0.1` on an internal network and bind-mounting a file over a project path need checking there |
| Apple Silicon | images are multi-arch by construction (all bases are), not built on arm64 in CI |
| macOS `ps`, `/bin/bash` 3.2 against real IDE settings paths | unit tests run on macOS but with fake extension and settings directories |

## Manual checklist

Run after installing on a new machine, and after every extension update that changes launch
behaviour. Tick per platform.

| # | Check | Linux | WSL2 | macOS |
|---|---|:-:|:-:|:-:|
| 1 | `claude-box doctor` passes | ☐ | ☐ | ☐ |
| 2 | After the first message from the panel, `~/.local/state/claude-box/wrapper.log` shows the argv the extension passed (one leading bundled-binary path with 2.1.318) and env names | ☐ | ☐ | ☐ |
| 3 | `ps -A -o pid,args \| grep -i claude` on the host shows only `docker exec ... claude ...`, no native `claude` | ☐ | ☐ | ☐ |
| 4 | Asking Claude to "read ~/.ssh/id_rsa" fails (no such file in the container) | ☐ | ☐ | ☐ |
| 5 | Asking Claude to "curl example.com" fails with a proxy 403; `claude-box logs` shows `TCP_DENIED` | ☐ | ☐ | ☐ |
| 6 | Asking Claude to print `.env` shows an empty file | ☐ | ☐ | ☐ |
| 7 | A file edit from the panel appears in the editor | ☐ | ☐ | ☐ |
| 8 | Diffs and permission prompts work in the panel | ☐ | ☐ | ☐ |
| 9 | Resuming a previous conversation works (history lives in the container volume) | ☐ | ☐ | ☐ |
| 10 | With `claudeProcessWrapper` removed but `guard` applied, the panel still lands in the container (check 3) | ☐ | ☐ | ☐ |
| 11 | Compare panel behaviour with and without the wrapper: with it, the extension treats sessions as "programmatic" and skips a permission-mode migration (PLATFORM-NOTES) - note anything visible | ☐ | ☐ | ☐ |
| 12 | Files created by Claude are owned by you on the host | ☐ | ☐ | ☐ |
| 13 | Quitting Docker: the panel shows an error, nothing runs on the host | ☐ | ☐ | ☐ |
| 14 | Antigravity and "Antigravity IDE" both use the wrapper (separate settings and extension dirs) | - | - | ☐ |
