# Changelog

All notable changes to Claude IDE Box are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): before 1.0, a minor version may change
behaviour or configuration in ways that need attention when updating; the notes say so.

## [0.1.0] - unreleased

The first release. `claude-ide-box version` prints `0.1.0`.

### Platforms

| Platform | How it runs | Speed |
|---|---|---|
| Linux | Docker Engine on the host; the project is bind-mounted into the container directly | full speed: the container reads the project from the host's own file system |
| macOS | Docker Desktop (reference: macOS 15 on Intel; Apple Silicon builds the same images natively for arm64) | file access through Docker Desktop's file sharing is **not measured** |
| Windows | WSL2: a one-click installer that sets up its own WSL distribution with Docker Engine (Docker Desktop is not used), or a manual install inside WSL | good for office work and small projects. On a repository of about 14,000 files on drive `C:`, a search by Claude takes about 9 s against about 0.5 s natively (WSL's default 9p file sharing). WSL's experimental virtiofs is slower there and not recommended |

Requirements: Docker Desktop 4.44.3 or Docker Engine 25.0.2 (24.0.9 on the 24.0 line) with runc
1.1.12 or later - older versions are refused (see Security); `git`; the Claude Code extension
(`anthropic.claude-code`) in VS Code, Cursor or Antigravity; a Claude subscription or an API key.
The Windows installer needs Windows 10 build 19041 or later with virtualization enabled and 12 GB
free. Scripts run on bash 3.2 and on BSD, GNU and busybox tools.

What was checked on which platform is in [TESTING.md](TESTING.md): the unit and integration
suites run on Linux (and the unit suite on macOS in CI); macOS with Docker Desktop has had one full
manual run; Docker Desktop on Windows and Apple Silicon have not been checked by hand.

### Added

- **The wrapper** (`claude-ide-box-exec`), set as the extension's `claudeCode.claudeProcessWrapper`:
  it runs `claude` in a per-project container through `docker exec -i`, with stdin/stdout - the
  extension's stream-json protocol - as the only channel. The panel keeps working as usual: chat,
  diffs, permission prompts.
- **One container and one home volume per project**, so settings, hooks and history of one
  project never reach another. Containers are created on the first message and reused.
- **The management CLI** (`claude-ide-box`): `setup`, `login`, `up`, `down`, `rm`, `shell`,
  `status`, `logs`, `allow`, `preset`, `profile`, `profiles`, `presets`, `forward`, `guard`,
  `doctor`, `version`.
- **`guard`**: replaces the binary bundled with every installed extension version by a link to the
  wrapper, so an extension that ignores the wrapper setting still lands in the container
  (`guard --undo` restores the originals). `AUTO_GUARD=0` leaves the binaries alone, for trying
  Claude IDE Box in a separate IDE profile first.
- **`login`**: `claude setup-token` in a read-only, capability-free container behind the proxy;
  the token is captured and stored (mode 600) without being shown on screen. Pasting it stays as the
  fallback; `login --token-stdin` reads one from a pipe.
- **`doctor`**: checks Docker, the networks, the proxy, the token, the IDE settings (user
  settings and IDE profiles of VS Code, Cursor and Antigravity, also on the Windows side of WSL),
  guarded binaries, `claude` running or installed on the host, and `git.autoRepositoryDetection`.
  Non-zero exit on any failure.
- **Profiles** (tools in the image): `php`, `python`, `go`, `rust`, `java`, `office`, and the
  document modules `docs`, `libreoffice` and `ocr` (OCR languages chosen with `OCR_LANGUAGES`).
  Profiles compose (`profile python go`); your own go in `~/.config/claude-ide-box/profiles/`.
- **Proxy presets** (allowed domains): `php`, `python`, `go`, `rust`, `java`, `yarn`, `github`;
  your own go in `~/.config/claude-ide-box/presets/`.
- **`forward PORT`**: a dev server running in the container, opened on `127.0.0.1` of the host;
  the container still publishes no ports.
- **`logs`**: the wrapper log and the requests the proxy denied, with the command that would allow
  them.
- **Windows installer** (`windows/Install Claude IDE Box.cmd`): one double-click, no terminal.
  It checks Windows, asks what Claude is for (office work, programming or both) and what to
  install, sets up WSL and a separate `ClaudeIDEBox` distribution from Ubuntu's WSL image (SHA256
  checked) with Docker Engine inside, installs or updates VS Code for the user with a "Claude IDE
  Box" profile (other profiles and IDEs are not touched), signs in, creates shortcuts, runs
  `doctor` and opens the first project. Running it again changes the selection or repairs;
  `-Uninstall` copies the projects to Documents first. Screens and messages in English and Polish.
- **Configuration** in `~/.config/claude-ide-box/config` and per project: masks, read-only
  paths, profiles, presets, limits (`MEMORY`, `CPUS`, `PIDS_LIMIT`, `TMP_SIZE`), the pinned Claude Code
  version. An unknown key stops the start instead of being ignored.
- **Documentation**: threat model and its limits in the README, [SECURITY.md](SECURITY.md),
  [TESTING.md](TESTING.md) with what is verified automatically and what needs a manual check,
  [docs/PLATFORM-NOTES.md](docs/PLATFORM-NOTES.md) with facts measured in the extension and on real
  hosts, and [docs/NON-DEVELOPERS.md](docs/NON-DEVELOPERS.md) for document work. For projects
  with personal data the README recommends [pii-airgap](https://github.com/PiotrSitkowski/pii-airgap)
  (`pii-airgap scan`, `pii-airgap mask-add`), and says plainly that what Claude reads is sent to the
  API.

### Security

What a process inside a project container - Claude, a tool it runs, a dependency, a
prompt-injected instruction - cannot do:

- **Read the rest of the machine.** Only the project directory is mounted, at its own path; the
  home directory and `docker.sock` never are. The wrapper refuses `/`, the home directory and its
  parents, and folders inside `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/.kube`, `~/.config`,
  `~/.local` and `~/Library`. On WSL it also refuses whole Windows drives, the Windows user folder
  and Windows system folders.
- **Read secrets in the project.** `.env` and `.env.*` (and configured masks, such as the
  PrestaShop preset) are covered by an empty read-only file or an empty tmpfs. Masked paths are
  recorded with their inode: a renamed, moved or swapped secret stops the next start until
  `up --recreate`. A new secret file recreates the container at the next start, or the start is
  refused while a session still runs in the old one.
- **Plant code the host runs.** `.git` (at every depth, also nested repositories), `.vscode`,
  `.idea`, `.agent`, `.agents` and `.devcontainer` are read-only; missing ones are created empty
  first so Claude cannot create them writable. `doctor` warns without
  `"git.autoRepositoryDetection": false`, which keeps the IDE from running git in a repository
  created during a session.
- **Reach the network.** The container sits on an internal network with no route out and no DNS;
  the host has no address on that bridge, so host and LAN services are unreachable. The only exit
  is squid, running unprivileged on a read-only root: CONNECT to port 443 of allowlisted domains,
  no cache, every denial logged. Plain HTTP, bare IPs and other ports are refused.
- **Escalate.** Non-root user with your UID/GID, `--cap-drop ALL`, `no-new-privileges`, read-only
  root file system, no sudo, memory, CPU and pids limits, `--init`.
- **Use the host's connections.** No IDE WebSocket, IPC socket, SSH agent or credential helper is
  bridged in; environment variables are passed by name only, with a deny list and a filter for
  values that are host paths, so the token never appears on a command line or in the log.
- **Smuggle mount options through file names.** Paths with commas, quotes or control characters
  stop the start before `docker run`.
- **Start in a folder holding restored personal data.** Before any container starts (wrapper,
  `up`, `shell`), every folder recorded by pii-airgap that is the project, contains it or lies
  inside it is checked in a throw-away container without network; if it holds values of its token
  map in clear text, if the map is missing or replaced, or if the check fails, nothing starts. The
  map never reaches the project container.
- **Run on an engine with a known container escape.** `setup`, every container start (wrapper,
  `up`, `shell`, `login`) and `doctor` refuse Docker Desktop below 4.44.3 (CVE-2025-9074: a
  container can reach the Docker Engine API without the socket), Docker Engine below 25.0.2 (24.0.9
  on the 24.0 line) and runc below 1.1.12 (CVE-2024-21626, "Leaky Vessels"). Below Docker Desktop
  4.97.0, the release with the most recent container isolation fix in Docker's security
  announcements, `setup` and `doctor` warn. A version that cannot be read counts as vulnerable. The
  thresholds and their sources are data in `lib/claude-ide-box/engine-versions.txt`.
  `ALLOW_VULNERABLE_DOCKER=1` in the global config runs anyway, and every `doctor` then prints a
  `[RISK]` line and fails.
- **Fail open.** Without Docker, without the daemon, without the image, with an unknown
  configuration key or an invalid limit, the wrapper stops; it never runs `claude` on the host.

Known limitations, stated in the README and in [SECURITY.md](SECURITY.md#known-limitations):
Claude can change every project file, and what the host later runs from the project runs outside
the box; every allowlisted domain is an exit, and what Claude reads goes to the API; containers
of different projects share the internal network; a repository created during a session is
writable until the next start; session history lives in the container volume and is not listed in
the IDE panel; the extension is trusted; Docker is the boundary.

### Fixed

Fixes made before the release, found by the CI, by a manual run on macOS and by the Windows
installer's tests:

- The wrapper no longer aborts when a lock directory disappears between the check and the inode
  probe of the lock; this was the intermittent failure of
  `test_live_lock_is_not_broken_while_its_pid_file_flickers`.
- A waiter could remove a live lock whose holder had not yet written its pid.
- `doctor` failed with `basename: illegal option -- z` for login shells (`-zsh`) on macOS; names
  from outside are no longer passed to `basename`/`dirname`.
- `doctor` did not know IDE profiles; `login` printed the token for retyping.
- The container user's group was `dialout` for macOS users (GID 20); it is now `claude`. Creating
  the user no longer fails for UID/GID 1000 on images that ship their own user.
- The proxy allowlist reload failed on Debian's squid 5.7; it is now signalled with SIGHUP.
- `forward` announced the port before its socket was listening.
- The Windows installer took the profile settings that VS Code saves back with its own line
  endings for a manual edit and stopped updating them.
- A stopped proxy is now started before the session: after a restart of WSL or Windows it did
  not come back by itself, and the session started without network (#15).

[0.1.0]: https://github.com/PiotrSitkowski/claude-ide-box/releases/tag/v0.1.0
