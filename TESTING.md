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
| `test_wrapper.sh` | dropping 0, 1 and 2 leading paths; subcommands and `/slash` prompts kept; stdout carries only the container's output; exit status and stdin passed through; container name and sanitisation; identical mount path; hardening flags; masks only for existing files (nested, directories, PrestaShop preset); read-only directories created with normal permissions; `GIT_WRITABLE`; recreate on a new secret file, refusal while a session is active; fail closed without daemon, without docker, without image, for `/`, `$HOME` and its parents; environment passed by name only with deny list and host-path filter; token never on a command line or in the log; host-path flags dropped, inline JSON kept, `..` escapes caught; parallel starts create one container; stale lock removal; a live lock kept however long its holder is paused, and respected until released; a lock directory of an older version does not block; invocation through a guard symlink; unknown config key fails closed; CPU clamping; automatic guard; paths with commas, quotes or newlines refused before `docker run` (mount-option injection); a symlinked secret is masked at the logical path when the project path itself contains a symlink; prompts that contain paths are not dropped; `~`-relative env values are not passed; invalid `MEMORY`/`CPUS`/`TMP_SIZE`/UID settings rejected; an active session is recognised for both `claude` and `claude.exe`; nested `.git` directories and files read-only, a new one triggers recreation; masks found inside `node_modules` and `vendor`; a masked file moved away (renamed parent) or replaced by a decoy stops the start until `up --recreate`; the inode probe survives a path that vanishes under it |
| `test_cli.sh` | `guard` on both bundled-binary layouts and several versions, idempotence, `--undo`, six concurrent runs keeping the original binary; `allow` validation and proxy reload; presets (`php`, `github` warning, `prestashop` per project); generated allowlist; `setup` (internal network with `inhibit_ipv4`, proxy attached at its fixed IP, UID/GID and version build args, profiles, build failure, no daemon); `up`, `up --recreate`, `down`, `rm`, `rm --volume`, `shell`, `status`, `logs`; `login --token-stdin` (mode 600, rejects garbage); `doctor` (healthy host, `useTerminal: true`, wrapper unset, legacy key, commented-out key, unguarded binary, `claude` running on the host, `claude` on PATH, no daemon, non-internal network, `git.autoRepositoryDetection` warning); modules: profile chains (`env:a.b`), user profiles and presets in `~/.config`, `profile`/`profiles`/`presets` commands, the current project's profiles built by `setup`, an unknown profile failing closed, a profile image with root-owned files in `/home/claude` rejected; `forward`: port validation, a TCP connection relayed through `docker exec ... socat`, loopback-only listener; fixes from the first manual test: `cb_basename`/`cb_dirname` on names starting with `-` (`-zsh`, `-n`, `--`), `doctor` with login shells in `ps`, wrapper set only in an IDE profile (`User/profiles/<id>/settings.json`: ok there, warning elsewhere), `useTerminal` checked in profiles, failure when no file sets the wrapper, unguarded binaries only a warning with `AUTO_GUARD=0`; `login` (in a pseudo-terminal, Linux): the token is stored from the capture directory and never shown, the directory is mounted into a read-only, capability-free container and removed afterwards, pasting is the fallback; the token filter (node) masks tokens split across reads and wrapped in colour codes |
| `test_pii.sh` | folders recorded by pii-airgap: no record, no check; the case from a manual test (a copy restored in place) refused before any container exists, stdout empty, the files named; a clean copy starts after a check with `--rm`, no network, read-only root, no capabilities, the copy and the map read-only, and the map never reaches the project container; a project inside a copy and a copy inside the project are checked; unrelated and vanished copies are ignored; a missing or replaced map refuses without running the check; a failed check refuses; control characters in file names from the copy never reach the terminal; `up` refuses too; a folder written by `restore --out` is refused with its own message |
| `test_engine_versions.sh` | minimum engine versions: thresholds only in the data file, with CVE and source; Docker Desktop 4.44.2 fails, 4.44.3 warns, 4.97.0 and 4.98.0 pass; Docker Engine 25.0.1, 24.0.8, 23.0.6, 20.10.27 fail, 25.0.2, 24.0.9, 26.1.0, 29.9.2 pass; runc 1.1.11 and 1.0.0-rc95 fail, 1.1.12 passes; suffixes (`29.9.2-rd`, `28.0.4+azure-1`, `1.1.12-0ubuntu2~22.04.1`, `v1.1.14`, `(12345)`) and numeric comparison (4.9.0, 4.100.0); an empty, `unknown`, `dev` or `<no value>` engine version, a missing runc and a Docker Desktop without a readable version (also one recognised only by its linuxkit kernel) fail; `setup` refuses before building, warns below 4.97.0; the wrapper refuses with nothing on stdout and no container, `up` too; `ALLOW_VULNERABLE_DOCKER=1` (global only, 0/1) lets setup and the wrapper run while every `doctor` prints `[RISK]` and still fails; no colour codes off a terminal; Podman reported as not checked |
| `test_install.sh` | install, settings snippet, idempotence, refusing to overwrite foreign files, no sudo, `--uninstall` undoes guard and keeps config, `--prefix` |
| `test_integration_skip.sh` | the integration suite says SKIPPED without Docker and fails when `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` |

### Results

| Environment | Result |
|---|---|
| Ubuntu 24.04, GNU bash 5.2, GNU coreutils | 182 passed, 0 failed |
| `bash:3.2` image (bash 3.2.57, musl, busybox userland) | 182 passed, 0 failed (inside passing tests: the `forward` test skips, no perl in that image; the three `login` tests need util-linux `script` for a pseudo-terminal and pass without checking); the first run of the pii-airgap check there caught busybox `tr` mangling `-c '[:print:]'`, which turned file names in the refusal message into question marks |
| CI: ubuntu-latest, macos-latest with `/bin/bash` 3.2 forced, `bash:3.2` | 123 passed, 0 failed in each (run 22, commit `49e5465`) |

The wrapper and the CLI were written test-first: each stage's tests were committed in the same
commit as the code, but were run red before the implementation existed (35 of 39 wrapper tests and
30 of 36 CLI tests failed; the remaining ones were refusal checks that a missing script also
"passes"), then green. The same applies to the fixes from the security review: 7 tests for mount
injection, nested repositories and mask escapes, then a decoy-replacement test, were red before the
fixes, and so were the 8 tests for the code review findings. One of them is worth noting: six
concurrent `guard` runs made one process `chmod a-x` a `.orig` that another had just turned into
a symlink, which removed the execute bit from the real wrapper.

The intermittent failure of `test_live_lock_is_not_broken_while_its_pid_file_flickers` (status 2)
was traced to the inode probe of `cb_lock`: a holder can remove its lock directory between `[ -e ]`
and `ls -di`, and `ls` failing under `set -euo pipefail` ended the wrapper. A test with an `ls`
that fails the same way was red (status 2) before the probe tolerated it.

`test_parallel_starts_create_container_once` then failed twice on CI (ubuntu, after #15): four
parallel starts created the container twice. It did not fail in 240 local runs, also under CPU load
and with eight suites in parallel. One way it can happen was reproduced deterministically: a lock was
a directory and the holder wrote its pid into it afterwards, so a holder paused for more than 5 s
right after taking the lock (25 polls without a pid) was taken for one that died, and a waiter
removed its lock and created the container while the holder still held it. The test for that case
(the holder's `mkdir`/`ln` paused for 7 s by a stand-in on `PATH`) was red on `main`: the waiter
logged "removing lock ... without a pid file" and created the container. The lock is now a symlink
whose target names the holder's pid, created by one `ln -s`, so a live lock always carries its pid.
Whether that pause was CI's cause is not confirmed; the parallel test now prints the wrapper log
(process ids, lock messages, container creation) when it fails.

Tests that took the first line of a pipeline with `head` inside a command substitution could
end early on their own: when `head` leaves while `grep` is still writing, `grep` dies of SIGPIPE
(status 141) and `pipefail` with `set -e` stops the test without a message - seen in the
`bash:3.2` CI job for another test of this kind (4 of 120 runs there, 0 of 300 with `sed -n 1p`).
The tests here use `sed -n 1p`, which reads all of its input.

The check of pseudonymised copies came from a manual test in which a copy restored in place was
opened again and Claude sent a contract with a PESEL to the API. Its tests were red first: 9 of the
first 11 failed (no record and an unrelated record pass without the feature), the `restore --out`
test was added red afterwards. End to end, pii-airgap's integration suite (with
`CLAUDE_IDE_BOX_SRC` pointing here) anonymises, restores and starts this wrapper in the restored
copy and in the `--out` folder - both refused - and in the tokenised copy - not refused.

The fixes from the first manual test on macOS were written the same way: 8 of the 10 new tests
were red first (the two others guard behaviour that was already right: failing when no settings
file sets the wrapper, and pasting the token by hand). One "passed" for the wrong reason at
first: the token filter test looked for `node` on the sandbox's minimal `PATH`, did not find it and
skipped; `run-unit.sh` now records `node` before the sandbox narrows `PATH`. Checked outside the
unit tests, in real containers:

- the login pipeline in `node:22-bookworm-slim` (the base image) on a real pseudo-terminal, with
  a stand-in `claude` that prints a token the way `setup-token` does: the screen shows
  `[token captured - not shown]`, the prompt for the code is visible before input, the token file
  is mode 600, and the stand-in sees a 4096-column terminal (no wrapped token). The real
  `claude setup-token` has not been run through it - that needs a Claude account;
- `image/create-user.sh` in `node:22-bookworm-slim` and `ubuntu:24.04` for UID:GID 501:20,
  1000:1000, 1000:20 and 1001:100: the user is `claude`, its group `claude` with the host GID, and
  the home directory `claude:claude` in every case (before: `dialout` for GID 20).

The minimum engine versions were written the same way: before the implementation 16 of the 19
tests failed; the 3 that passed were the refusal of a bad `ALLOW_VULNERABLE_DOCKER` value, "no
colour codes off a terminal" and "the wrapper runs on a current Docker", which code without the
check also satisfies. A twentieth test, a Docker Desktop recognised only by its linuxkit kernel,
was added afterwards and run red before its implementation.

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
| minimum engine versions | `doctor` reads the real engine's Engine and runc versions and finds no known escape |
| security fixes | a nested `.git` is read-only after the next start; a directory named `q,src=$HOME,dst=...` with a `.env` inside stops the container from being created |
| dev servers | `claude-ide-box forward` serves a server running in the container on `127.0.0.1` of the host; the container still publishes no ports |
| base image | a native npm module compiles with node-gyp (no header download); Python 3 with venv |
| profiles (`CLAUDE_IDE_BOX_IT_PROFILES`) | `php`: PHP 8.3 with the PrestaShop extensions, MariaDB client, composer via packagist; `python`: uv installs from PyPI; `go`: a module from proxy.golang.org; `rust`: `cargo add` + `cargo build` from crates.io; `java`: Maven fetches from Maven Central through the proxy settings; `office`: Markdown -> DOCX -> PDF -> text, an `.xlsx` formula recalculated by LibreOffice, a `.docx` edited in place, Polish OCR; `go` + `python` combined in one container. All package downloads go through the proxy without DNS, each with only its own preset enabled |

Without a Docker daemon the script prints a banner saying **INTEGRATION TESTS SKIPPED** and that
nothing was verified; with `CLAUDE_IDE_BOX_REQUIRE_DOCKER=1` (as in CI) that is a failure.

### Where they ran

**Development sandbox - 69 passed, 0 failed, 0 skipped** with `CLAUDE_IDE_BOX_IT_PROFILES="python go
java office"`, and 64 passed with `"python go"` after the combined-profile check was fixed (see
below). With the fixes from the first manual test, rebased on the pii-airgap check: **58 passed, 0
failed, 0 skipped** without profiles, run as UID 30033 with a base image that has Ubuntu's own
`ubuntu` user removed and an apt/npm proxy setting baked in (the suite runs `setup` with a
throw-away `HOME`, so the Docker client's own proxy configuration does not reach the builds).
With the minimum-version check: **59 passed, 0 failed, 0 skipped** without profiles (58 on `main` at
`550788b` in the same setup).
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
lock whose holder had not written its pid yet (since then the lock carries its pid from the start).

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
| Docker Desktop (macOS, Windows/WSL2) | no Docker Desktop in CI. The minimum-version check reads the Desktop version from `Platform.Name` of `docker version`, which was not seen on a real Desktop here. Its VM, file sharing, ownership mapping and DNS layer differ from native Linux; in particular `inhibit_ipv4`, `--dns 127.0.0.1` on an internal network and bind-mounting a file over a project path need checking there |
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
| 9 | Resuming a previous conversation works (history lives in the container volume; from the panel it does not yet - use `claude-ide-box shell`, `claude --resume`) | ☐ | ☐ | ☐ |
| 10 | With `claudeProcessWrapper` removed but `guard` applied, the panel still lands in the container (check 3) | ☐ | ☐ | ☐ |
| 11 | Compare panel behaviour with and without the wrapper: with it, the extension treats sessions as "programmatic" and skips a permission-mode migration (PLATFORM-NOTES) - note anything visible | ☐ | ☐ | ☐ |
| 12 | Files created by Claude are owned by you on the host | ☐ | ☐ | ☐ |
| 13 | Quitting Docker: the panel shows an error, nothing runs on the host | ☐ | ☐ | ☐ |
| 14 | Antigravity and "Antigravity IDE" both use the wrapper (separate settings and extension dirs) | - | - | ☐ |

### Results: macOS 15 (Intel), first full run

Docker Desktop 4.98.0 (engine 29.9.2), VS Code 1.143.1, extension 2.1.319, installed as the README
says, in a separate VS Code profile with `AUTO_GUARD=0` (no guard), commit `9ef342c`.

Passed: Claude runs in the container and the host shows only `docker exec`; `~/.ssh` and
`/Users/<you>/.ssh` are not visible, and of `/Users` only the project folder is; `.env` is empty in
the container and untouched on the host; `curl example.com` gets a 403 from squid, listed by
`logs`; no DNS; `.vscode` and `.git` are read-only (EROFS); writing the project works, files are
owned by the user (`staff`); `CapEff`, `CapPrm` and `CapBnd` are 0; no `docker.sock`;
`CLAUDE_CODE_MESSAGING_SOCKET`, `SSH_AUTH_SOCK` and `VSCODE_IPC_HOOK` do not reach the container.
The extension passes one leading binary path, and also calls the wrapper for `auth status --json`.

Found, and what happened to each:

| Finding | Status |
|---|---|
| The panel's session history is empty and resuming from the panel does not work: the extension reads `~/.claude/projects` on the host | not fixed: a bind mount of the transcript directory would let the box write files that unboxed Claude Code reads (see [SECURITY.md](SECURITY.md#known-limitations)); workaround `claude-ide-box shell` + `claude --resume` |
| `doctor`: `basename: illegal option -- z` for login shells (`-zsh`) | fixed for every `basename`/`dirname` on outside data |
| `doctor` does not know IDE profiles | fixed |
| `login` shows the token, which then has to be retyped | fixed: captured without being shown, pasting is the fallback |
| Container group `dialout` (GID 20) | renamed to `claude` |
