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
| `test_cli.sh` | `guard` on both bundled-binary layouts and several versions, idempotence, `--undo`, six concurrent runs keeping the original binary; `allow` validation and proxy reload; presets (`php`, `github` warning, `prestashop` per project); generated allowlist; `setup` (internal network with `inhibit_ipv4`, proxy attached at its fixed IP, UID/GID and version build args, profiles, build failure, no daemon); `up`, `up --recreate`, `down`, `rm`, `rm --volume`, `shell`, `status`, `logs`; `login --token-stdin` (mode 600, rejects garbage); `doctor` (healthy host, `useTerminal: true`, wrapper unset, legacy key, commented-out key, unguarded binary, `claude` running on the host, `claude` on PATH, no daemon, non-internal network, `git.autoRepositoryDetection` warning); modules: profile chains (`env:a.b`), user profiles and presets in `~/.config`, `profile`/`profiles`/`presets` commands, the current project's profiles built by `setup`, an unknown profile failing closed, a profile image with root-owned files in `/home/claude` rejected; `forward`: port validation, a TCP connection relayed through `docker exec ... socat`, loopback-only listener |
| `test_deps.sh` | `DEPS_VOLUMES`: a volume over `node_modules` (none by default); missing root directories created on the host; a name matches nested workspaces but not inside itself, a path is anchored; masks and nested `.git` inside a dependency directory not mounted (still mounted without volumes); a new volume labelled and handed to the container user by a one-off container with no network, only `CAP_CHOWN` and no project mount, not touched again; a changed setting recreates the container; a symlink, a file, absolute, `..`, `.`, `.git`, `.vscode` and comma paths fail closed; stdout clean; an empty new volume announced; `deps on/off/status`; `deps install` per lockfile (npm, pnpm, Yarn classic and Berry), once per workspace, Python venv (requirements, uv), no lockfile refused before anything runs, install failure reported; `rm --volume` removes the volumes; binaries of another platform (`@esbuild/darwin-*`, `rollup-darwin-*`, pnpm store, `workerd-windows-*`, `sharp-win32-*`, a macOS `.venv`) reported on the first start and by `doctor`, `is-windows` and Linux ones not, nothing reported when hidden by a volume or when the container already exists |
| `test_secrets.sh` | the new default masks (`.dev.vars*`, `.npmrc`, `.netrc`, `.envrc`, `*.pem`, `*.key`, `credentials*.json`, `service-account*.json`) and ordinary files left alone, narrowing `MASK_DEFAULTS` per project; `.mcp.json` masked with a key in a URL query, a literal `env` value or an `Authorization` header, visible without secrets or with `${VAR}` placeholders, masked once a secret appears; the scan on container creation finds a secret in a URL query string, in JSON, in `.npmrc`, known token formats and private keys, reports file, line and the `mask` command, never the value (stdout, stderr, log), ignores placeholders, version ranges, `author`, masked files, `node_modules` and lockfiles, runs only on creation, `SECRET_SCAN=0`; `scan` and `mask` (add, list, `--remove`, refusing `..`, absolute and spaced patterns); `doctor` reports findings |
| `test_install.sh` | install, settings snippet, idempotence, refusing to overwrite foreign files, no sudo, `--uninstall` undoes guard and keeps config, `--prefix` |
| `test_integration_skip.sh` | the integration suite says SKIPPED without Docker and fails when `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` |

### Results

| Environment | Result |
|---|---|
| Ubuntu 24.04, GNU bash 5.2, GNU coreutils | 180 passed, 0 failed |
| `bash:3.2` image (bash 3.2.57, musl, busybox userland) | 180 passed, 0 failed (the `forward` test reports SKIPPED: no perl in that image) |
| CI: ubuntu-latest, macos-latest with `/bin/bash` 3.2 forced, `bash:3.2` | 123 passed, 0 failed in each (run 22, commit `49e5465`) |

The wrapper and the CLI were written test-first: each stage's tests were committed in the same
commit as the code, but were run red before the implementation existed (35 of 39 wrapper tests and
30 of 36 CLI tests failed; the remaining ones were refusal checks that a missing script also
"passes"), then green. The same applies to the fixes from the security review: 7 tests for mount
injection, nested repositories and mask escapes, then a decoy-replacement test, were red before the
fixes, and so were the 8 tests for the code review findings. One of them is worth noting: six
concurrent `guard` runs made one process `chmod a-x` a `.orig` that another had just turned into
a symlink, which removed the execute bit from the real wrapper.

Dependency volumes and the secret checks were written the same way. Before the implementation 38
of the 57 new tests failed (19 of 27 in `test_deps.sh`, 19 of 30 in `test_secrets.sh`); the ones
that passed check refusals or the absence of something (no volume by default, no warning for
placeholders, a symlink refused), which a missing feature also satisfies. Getting them green
caught a `.vscode` entry that was not refused because the validation split words with `IFS=/`,
and `is-windows` (a common npm package) reported as a Windows binary.

## Integration tests

`tests/integration/run.sh` builds the images, runs `claude-ide-box setup` in its own namespace
(`CLAUDE_IDE_BOX_INSTANCE=cbit`, subnet `172.30.98.0/24`, a throw-away `HOME`), so it never touches a
real installation, and then checks from inside real containers:

| Requirement | Checks |
|---|---|
| (a) proxy | allowed domain passes; other domain gets 403; plain HTTP, bare IPs and ports other than 443 get 403; direct connections and raw TCP fail; no default route |
| (b) DNS | external names do not resolve |
| (c) masks | `.env` empty and read-only, `.env.d/` empty, host file untouched; a `.env.local` created later is masked after the next start |
| (d) read-only | writes to `.git/hooks`, `.git/config`, `.vscode`, `.idea`, `.devcontainer`, `.agent` fail; `.git` cannot be removed, `.vscode` cannot be renamed |
| (e) ownership | writing the project works; new files belong to the host UID |
| (f) privileges | `CapEff` and `CapBnd` zero, `NoNewPrivs` 1, non-root, no `docker.sock`, read-only rootfs, no sudo, pids/memory limits and `--init`, home not mounted |
| (g) wrapper | `claude-ide-box-exec /fake/native-binary/claude --version` prints exactly one line, the version |
| extra | host listeners unreachable on the internal gateway and `docker0` (with a positive control from the default bridge); Claude Code's API request goes through squid without DNS (tunnel count in the squid log rises, the API answers "Invalid API key" to a fake key); squid runs without capabilities as `proxy` on a read-only rootfs; `claude-ide-box logs` shows the denial; one project's `~/.claude` and files are invisible to another; fail closed with an unreachable daemon and for `$HOME` |
| allowlist reload | a domain is refused before `claude-ide-box allow` and passes right after it, and squid confirms the reload (it is signalled with SIGHUP; `squid -k reconfigure` depends on a PID file that `squid -N` does not always write, which made the reload fail on Debian's squid 5.7 in CI) |
| dependency volumes and secrets | in a project with `@esbuild/darwin-x64` in `node_modules` and secrets in `.mcp.json`, `.npmrc` and a YAML URL: the first start reports the foreign binaries and the YAML secret with the `mask` command, the value appears nowhere (stderr, log); `.mcp.json` and `.npmrc` are empty in the container; `deps on` + `deps install` runs `npm ci` in the container through the proxy; the package is in the container's `node_modules`, owned by the container user; the host's `node_modules` is untouched and its darwin binaries are hidden in the container; what the container writes to `node_modules` does not reach the host; no report on the next start; `rm --volume` removes the volume |
| security fixes | a nested `.git` is read-only after the next start; a directory named `q,src=$HOME,dst=...` with a `.env` inside stops the container from being created |
| dev servers | `claude-ide-box forward` serves a server running in the container on `127.0.0.1` of the host; the container still publishes no ports |
| base image | a native npm module compiles with node-gyp (no header download); Python 3 with venv |
| profiles (`CLAUDE_IDE_BOX_IT_PROFILES`) | `php`: PHP 8.3 with the PrestaShop extensions, MariaDB client, composer via packagist; `python`: uv installs from PyPI; `go`: a module from proxy.golang.org; `rust`: `cargo add` + `cargo build` from crates.io; `java`: Maven fetches from Maven Central through the proxy settings; `office`: Markdown -> DOCX -> PDF -> text, an `.xlsx` formula recalculated by LibreOffice, a `.docx` edited in place, Polish OCR; `go` + `python` combined in one container. All package downloads go through the proxy without DNS, each with only its own preset enabled |

Without a Docker daemon the script prints a banner saying **INTEGRATION TESTS SKIPPED** and that
nothing was verified; with `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` (as in CI) that is a failure.

### Where they ran

**Development sandbox - 69 passed, 0 failed, 0 skipped** with `CLAUDE_IDE_BOX_IT_PROFILES="python go
java office"`, and 64 passed with `"python go"` after the combined-profile check was fixed (see
below). With the dependency-volume and secret checks, **71 passed, 0 failed, 0 skipped** without
profiles (13 of them new; 58 on `main` in the same setup). That run used a base image with Ubuntu's
own `ubuntu` user (UID 1000) removed, because it ran as UID 30033 and the UID-collision path is not
what it tested, and an apt/npm proxy setting in that base image: the suite runs `setup` with a
throw-away `HOME`, so the Docker client's own proxy configuration does not reach the builds.
Native Docker Engine 29.9.2 on Linux
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

### Dependency volumes, measured

`tests/perf/deps-bench.sh [RUNS]` builds a TypeScript project with 300 vitest test files (vitest
2.1.9, esbuild and rollup native, zod), then times `npm ci` (with a warm npm cache on its own
volume) and `vitest run` with `node_modules` on the bind-mounted project and on a named volume, in a
plain `node` container.

| Host | Mode | `npm ci` | `vitest run` |
|---|---|---|---|
| Linux x86_64, native Docker Engine 29.9.2, 4 CPUs (development sandbox) | bind mount | 1.5 s | 23.7 s |
| same | named volume | 1.6 s | 24.2 s |
| macOS + Docker Desktop | both | **not measured yet** | **not measured yet** |

Medians of 3 runs. On native Linux both are the same filesystem, so no difference was expected and
none was found: the measurement shows the volume costs nothing there. The speed-up on Docker
Desktop for macOS, where a bind mount crosses the VM's file sharing on every file access, is the
reason it is mentioned in the README, but it was **not measured**; it is an estimate until someone
runs the script on a Mac.

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
