<h1 align="center">claude-box</h1>

<p align="center">
  <b>The Claude Code IDE extension, with Claude Code itself locked in a container.</b><br>
  It sees only the current project and reaches only the domains you allow.
</p>

<p align="center">
  <a href="https://github.com/PiotrSitkowski/claude-box/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/PiotrSitkowski/claude-box/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-0f766e"></a>
  <img alt="Platforms" src="https://img.shields.io/badge/hosts-macOS%20%C2%B7%20Linux%20%C2%B7%20WSL2-4338ca">
  <img alt="Shell" src="https://img.shields.io/badge/bash-3.2%2B-59636e">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/architecture-dark.svg">
    <img alt="Architecture: the IDE extension starts claude-box-exec on the host, which runs claude in a project container on an internal Docker network. The only way out is a squid proxy that allows HTTPS to allowlisted domains." src="docs/assets/architecture-light.svg" width="100%">
  </picture>
</p>

---

**What it is.** A small set of shell scripts that sit between the official Claude Code extension
(`anthropic.claude-code`, in Antigravity, VS Code or Cursor) and the `claude` process it starts.
You keep using the extension panel as usual - chat, diffs, permission prompts, resumed
conversations - but `claude` runs inside a per-project Docker container with no capabilities, a
read-only root filesystem, no DNS and no route to the internet except an allowlisting proxy.
The container sees the project directory and nothing else of your machine.

**What it is not.** It is not a Dev Container, not a VM, and not a full answer to "AI agent
security". Claude can still change every file in the project, and anything you later *run on the
host* from that project runs with your privileges. Read the [threat model](#threat-model) before
relying on it.

## Contents

- [How it works](#how-it-works)
- [Threat model](#threat-model)
- [Install](#install) - [macOS](#macos) · [Linux](#linux) · [Windows with WSL2](#windows-with-wsl2)
- [Daily use](#daily-use)
- [Network allowlist](#network-allowlist)
- [Configuration](#configuration)
- [Updating Claude Code](#updating-claude-code)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Development](#development)

## How it works

The extension has a setting, `claudeCode.claudeProcessWrapper`, that names an executable to launch
instead of its bundled `claude` binary. claude-box sets it to `claude-box-exec`, which does
nothing but `docker exec -i` into the project's container and run `claude` there with the same
arguments. stdin/stdout - the extension's stream-json protocol - is the only channel between the
host and the container.

```mermaid
sequenceDiagram
    autonumber
    participant Ext as Claude Code extension
    participant W as claude-box-exec (host)
    participant D as Docker
    participant C as project container
    participant P as squid proxy
    Ext->>W: [bundled binary path] --output-format stream-json ...
    W->>W: log argv + env names, drop binary path,<br/>drop flags with host paths outside the project
    W->>D: inspect / create / start container (locked, fail closed)
    W->>C: exec claude ... (env passed by name only)
    Ext-->>C: stream-json over stdin/stdout
    C->>P: CONNECT api.anthropic.com:443
    P-->>C: tunnel (allowlisted) or 403 (logged)
```

| Piece | What it does |
|---|---|
| `bin/claude-box-exec` | The wrapper the extension runs. Writes nothing to stdout but the container's stdout, logs to `~/.local/state/claude-box/wrapper.log`, never executes anything on the host except `docker`. |
| `bin/claude-box` | Management CLI: `setup`, `login`, `up`, `down`, `rm`, `shell`, `status`, `logs`, `allow`, `preset`, `guard`, `doctor`. |
| `image/` | Debian bookworm + Node 22 + a pinned Claude Code. Non-root user with your UID/GID, no sudo. Optional language profiles (`php` ships). |
| `proxy/` | squid as an unprivileged user: CONNECT to port 443 of allowlisted domains only, no cache, every denial logged. |
| Networks | `claude-box-internal` (`--internal`, no route out, host gets no address on it) and `claude-box-egress` (only the proxy is on it). |
| `guard` | Replaces the binary bundled with every installed extension version by a symlink to the wrapper, so even an extension that ignores the wrapper setting lands in the container. |

The first start creates the read-only directories that do not exist yet (`.git`, `.vscode`,
`.idea`, `.agent`, `.agents`, `.devcontainer`) as empty directories owned by you; otherwise Claude
could create them writable. Git ignores an empty `.git` directory, and `git init` on the host
fills it normally.

One container and one home volume exist **per project** (`claude-box-<name>-<hash>`), so hooks,
settings and history in one project's `~/.claude` never touch another project.

## Threat model

claude-box assumes that whatever runs inside the container - Claude, a tool it calls, a
dependency it installs, a prompt-injected instruction - may be hostile, and keeps it away from the
rest of your machine.

| Inside the container, Claude **cannot** | How |
|---|---|
| read `~/.ssh`, `~/.aws`, `~/.gitconfig`, other projects, your home | only the project directory is mounted; home and `docker.sock` never are |
| read `.env`, `.env.*` (and PrestaShop config with the preset) | bind-mounted over with an empty read-only file / empty tmpfs |
| plant git hooks or IDE tasks | `.git` (at every depth), `.vscode`, `.idea`, `.agent`, `.agents`, `.devcontainer` are read-only |
| unmask a secret by renaming or replacing it | masked paths are recorded with their inode; a moved or swapped one stops the next start |
| smuggle mount options through file names | paths with commas, quotes or control characters stop the start instead of reaching `docker --mount` |
| reach arbitrary hosts | no route out; the proxy allows only CONNECT :443 to listed domains |
| exfiltrate over DNS | no resolver; the proxy resolves names, the container never does |
| reach services on your host or LAN | internal network; the host has no address on that bridge |
| escalate inside the container | non-root, `--cap-drop ALL`, `no-new-privileges`, read-only rootfs |
| use your IDE's connection | no IDE WebSocket, IPC socket or credential helper is bridged in |

> [!WARNING]
> **Limits - stated plainly.**
> - **Claude can modify every project file.** Anything the *host* later executes from the project
>   runs outside the sandbox: `composer`/`npm` scripts, `Makefile`, `.envrc` (direnv), Husky hooks,
>   test suites, CI after you push. Review changes before running them on the host.
> - **Every allowlisted domain is an exfiltration channel.** `api.anthropic.com` is unavoidable.
>   The `github` preset in particular lets anything with a token push data out.
> - **Conversation history lives in the container's volume**, not in your `~/.claude`. Removing it
>   (`claude-box rm --volume`) deletes that history.
> - **A repository Claude creates mid-session is writable until the next start.** Then its `.git`
>   becomes read-only. Until then, only the IDE setting `"git.autoRepositoryDetection": false`
>   keeps the host from running git (hooks, `core.fsmonitor`) in it; `doctor` warns without it.
> - **Containers of different projects share the internal network** and can reach each other's
>   listening ports. Nothing listens by default; see [SECURITY.md](SECURITY.md#known-limitations).
> - **The extension is trusted.** It runs on the host and renders what the container sends.
>   claude-box protects the host from the `claude` process, not from the extension.
> - **Docker is the boundary.** A container escape (kernel or runtime bug) defeats all of this.

## Install

Prerequisites on every platform: Docker (Desktop or Engine), `git`, and the Claude Code extension
in your IDE. A Claude subscription (Pro/Max) is the primary path; an API key works too.

```bash
git clone https://github.com/PiotrSitkowski/claude-box.git
```

```bash
cd claude-box && ./install.sh
```

`install.sh` copies the scripts to `~/.local/share/claude-box`, links `claude-box` and
`claude-box-exec` into `~/.local/bin`, needs no root, and is safe to re-run. It prints the exact
settings snippet for your machine.

### macOS

The reference platform is macOS 15 on Intel with Docker Desktop (see the manual checklist in
[TESTING.md](TESTING.md)); Apple Silicon builds the same images natively for arm64.

1. Start Docker Desktop. The default file sharing (`/Users`, `/Volumes`, `/private`, `/tmp`)
   covers usual project locations.
2. Install and build:
   ```bash
   ./install.sh && claude-box setup
   ```
3. Get a token (opens a URL you visit in your browser):
   ```bash
   claude-box login
   ```
4. Open **user** settings JSON in each IDE you use - *Antigravity*, *Antigravity IDE*, *VS Code*,
   *Cursor* (`Cmd+Shift+P` → "Preferences: Open User Settings (JSON)") and add:
   ```jsonc
   "claudeCode.claudeProcessWrapper": "/Users/you/.local/share/claude-box/bin/claude-box-exec",
   "claudeCode.useTerminal": false,
   "git.autoRepositoryDetection": false
   ```
   The last line keeps the IDE from running git in sub-repositories Claude might create inside
   the project - git hooks and `core.fsmonitor` from such a repository would run on the host.
5. Route every installed extension version to the wrapper and check everything:
   ```bash
   claude-box guard && claude-box doctor
   ```

> [!IMPORTANT]
> Use **user** settings, never workspace settings. Workspace settings live in `.vscode/` inside the
> project, which is exactly what the sandboxed process must not control.

GUI apps on macOS do not inherit your shell's `PATH`; the wrapper finds `docker` in the usual
places (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.docker/bin`, Docker.app) and respects
`docker context` / `DOCKER_HOST`.

### Linux

1. Docker Engine with your user in the `docker` group (or rootless Docker).
2. Same steps as macOS, with settings at `~/.config/<App>/User/settings.json`
   (`Code`, `Cursor`, `Antigravity`, `Antigravity IDE`).
3. On native Linux, files Claude creates belong to your UID because the container user is built
   with your UID/GID.

### Windows with WSL2

1. Docker Desktop with the WSL2 backend and integration enabled for your distro, or Docker Engine
   inside the distro.
2. Clone and install **inside WSL**; keep projects on the Linux filesystem (`~/src/...`), not
   under `/mnt/c`.
3. Open the project from the IDE with the WSL remote extension. The Claude Code extension then
   runs on the WSL side (`~/.vscode-server/extensions/...`), which is what `guard` patches.
4. Put the wrapper setting in the Windows **user** settings
   (`%APPDATA%\Code\User\settings.json`) and, if your IDE applies machine settings remotely, in
   `~/.vscode-server/data/Machine/settings.json`. `claude-box doctor` checks both.

## Daily use

Open a project folder in the IDE and use the Claude Code panel. The first message in a new project
creates its container (a few seconds); later sessions reuse it.

| Command | |
|---|---|
| `claude-box status` | proxy, network, this project's container, token |
| `claude-box shell` | bash in this project's container, e.g. to run `claude` in a terminal |
| `claude-box logs` | wrapper log and requests the proxy denied (`--all` for the full proxy log) |
| `claude-box allow example.org` | allow a domain (`.example.org` for subdomains too) |
| `claude-box up --recreate` | apply changed masks or settings now |
| `claude-box down` / `rm` | stop / remove this project's container (`rm --volume` also deletes history) |
| `claude-box doctor` | check the whole setup; non-zero exit on any failure |

> [!NOTE]
> When a new secret file (say `.env.local`) appears on the host, the next session recreates the
> container so the file is masked. If a session is still running in the old container, the wrapper
> refuses to start a new one and tells you to run `claude-box up --recreate`.

## Network allowlist

The default list ([`proxy/allowlist.txt`](proxy/allowlist.txt)) follows the
[Claude Code network requirements](https://code.claude.com/docs/en/network-config):

| Domain | Needed for |
|---|---|
| `api.anthropic.com` | the API, feature flags, WebFetch safety check |
| `claude.ai`, `claude.com`, `platform.claude.com` | subscription authentication and token refresh |
| `registry.npmjs.org` | plugins and `npx`-launched MCP servers |

Presets, off by default:

| Preset | Adds | Note |
|---|---|---|
| `php` | `packagist.org`, `repo.packagist.org`, `getcomposer.org` | composer |
| `github` | `github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com` | **exfiltration channel** - composer often needs it for dist downloads |

```bash
claude-box preset php on
```

By default the container also sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry or
error reporting) and `ENABLE_CLAUDEAI_MCP_SERVERS=false` (claude.ai connectors such as mail or
drive are not exposed inside the sandbox). Both can be turned off in the config.

## Configuration

`~/.config/claude-box/config` (outside every project, so Claude cannot edit it) holds `KEY=value`
lines; it is parsed, never sourced, and unknown keys are an error. Per-project overrides go to
`~/.config/claude-box/projects/<container-name>.conf`.

| Key | Default | |
|---|---|---|
| `SUBNET` / `PROXY_IP` | `172.30.99.0/24` / `172.30.99.2` | change if it collides with your LAN or VPN |
| `CLAUDE_CODE_VERSION` | `2.1.318` | pinned Claude Code version |
| `PROFILE` * | `base` | image profile, e.g. `php` |
| `MASK` * | | extra mask patterns; a name (`secrets.json`) matches at any depth, a path (`config/db.yml`) is anchored at the project root |
| `MASK_PRESETS` * | | `prestashop` |
| `READONLY` * | | extra read-only paths, e.g. `.husky .envrc` |
| `GIT_WRITABLE` * | `0` | `1` lets Claude commit (it can then also write `.git/hooks`) |
| `MEMORY` / `CPUS` / `PIDS_LIMIT` * | `4g` / `2` / `512` | container limits |
| `NONESSENTIAL_TRAFFIC` * | `0` | `1` allows telemetry and error reporting |
| `CLAUDEAI_CONNECTORS` * | `0` | `1` exposes claude.ai connectors (needs `mcp-proxy.anthropic.com` allowed) |
| `PROXY_PRESETS` | | `php github` |
| `UPSTREAM_PROXY` | | `host:port` of a corporate proxy squid should forward to |
| `AUTO_GUARD` | `1` | re-run `guard` on every wrapper start |

\* can be overridden per project. The full list is in [`lib/claude-box/common.sh`](lib/claude-box/common.sh)
(`cb_config_defaults`).

### Language profiles

`claude-box setup --profile php` builds `claude-box/php` on top of the base image: PHP 8.3 CLI
with intl, zip, gd, mysqli, pdo_mysql, mbstring, xml and curl, composer, and the MariaDB client -
enough for PrestaShop. Select it per project with `PROFILE=php`. To add a profile, create
`image/profiles/<name>/Dockerfile` that starts `FROM ${BASE_IMAGE}`, installs as root and ends with
`USER claude`.

## Updating Claude Code

```bash
claude-box setup
```

after changing `CLAUDE_CODE_VERSION` in the config rebuilds the images. Running containers keep the
old image until no session is active in them; the next session recreates them automatically. The
auto-updater is disabled inside the container on purpose - versions change only when you rebuild.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Panel says the process exited immediately | `claude-box logs` - the wrapper log has the reason. Most often Docker is not running. |
| `image claude-box/base:latest not found` | run `claude-box setup` |
| `refusing to mount ...: it is the home directory` | the IDE has no folder open, or you opened `~`. Open a project folder. |
| `container ... runs with an outdated configuration` | a session is still running in the old container; close it and run `claude-box up --recreate` |
| A domain Claude needs is blocked | `claude-box logs` shows `TCP_DENIED` lines; `claude-box allow <domain>` if you accept the risk |
| `network ... cannot be created` | `SUBNET` collides with an existing network; change `SUBNET` and `PROXY_IP` |
| Extension works but `doctor` reports unguarded binaries | the extension updated; run `claude-box guard` (the wrapper also does it on start) |
| `useTerminal is true` in `doctor` | terminal mode ignores the wrapper - set `"claudeCode.useTerminal": false` |
| `masked path(s) were moved, replaced or deleted` | a masked file is not the same file (inode) it was when the container was created. Editors that save by writing a temp file and renaming it cause this too. If it was you, `claude-box up --recreate`; if not, find out what moved it first |
| `... cannot be mounted safely` | a file or directory that has to be masked or made read-only has a comma, quote, tab or newline in its name; rename it |
| Files created by Claude are owned by another user | the images were built for another UID; run `claude-box setup` as yourself. On Docker Desktop ownership is mapped to you regardless. |

Set `CLAUDE_BOX_DEBUG=1` to mirror the wrapper log on stderr.

## Uninstall

```bash
./install.sh --uninstall
```

restores the extension binaries (`guard --undo`) and removes the scripts. It prints the commands to
remove the config, the Docker containers, volumes and networks, which it leaves in place on purpose.

## Development

- [`docs/DESIGN.md`](docs/DESIGN.md) - design specification
- [`docs/PLATFORM-NOTES.md`](docs/PLATFORM-NOTES.md) - facts measured on real hosts and in the extension
- [`TESTING.md`](TESTING.md) - what is verified automatically and what needs a manual check
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - conventions (bash 3.2, fail closed, security invariants)
- [`SECURITY.md`](SECURITY.md) - reporting a sandbox escape

```bash
tests/run-unit.sh
```

```bash
tests/integration/run.sh
```

## License

[Apache License 2.0](LICENSE) - free for anyone to use, modify and distribute, including
commercially. Copyright 2026 Piotr Sitkowski; see [NOTICE](NOTICE).
