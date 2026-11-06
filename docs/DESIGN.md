# claude-ide-box - design

Claude Code locked in a container, driven from the IDE extension on the host.

This is the design specification. Conventions for contributors are in `CONTRIBUTING.md`; facts
measured on real hosts and in the shipped extension code are in `docs/PLATFORM-NOTES.md`. Where
this document and PLATFORM-NOTES disagree, PLATFORM-NOTES wins - it was measured, parts of this
document were inferred.

## Target users and platforms

- **Hosts:** Linux, Windows + WSL2, macOS (Intel and Apple Silicon). The maintainer's own machine is
  macOS 15 on Intel with Docker Desktop - the one platform that will be tested by hand, so it must
  not be second-class.
- **IDEs:** Google Antigravity (VS Code fork, extensions from Open VSX; ships as two apps on macOS,
  "Antigravity" and "Antigravity IDE", each with its own extension and settings directory), VS Code,
  Cursor - all with the official Anthropic extension "Claude Code" (`anthropic.claude-code`).
- **Account:** Claude subscription (Pro/Max), not an API key. API-key users should also work
  (`ANTHROPIC_API_KEY` passed through), but subscription is the primary path.

## Goal

Use the Claude Code extension panel in the IDE as usual, but the Claude Code process must run
EXCLUSIVELY inside a Docker container that sees only the current project directory and has network
access limited to an allowlist. Claude must not be able to do anything outside the container.

## Architecture (decisions already made - do not change without justification)

- In graphical (non-terminal) mode the extension spawns the `claude` binary as a child process and
  talks to it over stdin/stdout (stream-json). Observed arguments:
  `--output-format stream-json --verbose --input-format stream-json --max-thinking-tokens N
  --permission-prompt-tool stdio --resume <id> --setting-sources=user,project,local
  --permission-mode default`.
- The extension setting `claudeCode.claudeProcessWrapper` ("Executable path used to launch the
  Claude process") points at our wrapper. See PLATFORM-NOTES for exactly what argv the wrapper receives
  (verified in extension 2.1.318: ONE leading path - the bundled binary - or none).
- The wrapper does `docker exec -i` into a long-lived per-project container and runs `claude` there
  with the same flags. stdin/stdout is the ONLY channel between host and container.
- No VS Code process runs in the container (no Dev Containers - VS Code IPC sockets,
  `VSCODE_IPC_HOOK_CLI`, SSH agent forwarding and credential helper forwarding are escape routes to
  the host). We do not bridge the extension's IDE WebSocket into the container
  (`CLAUDE_CODE_IDE_HOST_OVERRIDE` etc. - rejected; the extension is not designed for a hostile client).
- Known extension risks: version 2.1.131 silently ignored `claudeProcessWrapper` (fixed later), and
  `useTerminal: true` ignores it. The project must account for this (see `guard` and `doctor`).

## Components

1. **`image/Dockerfile`** - Debian bookworm, Node 22, Claude Code pinned via
   `ARG CLAUDE_CODE_VERSION` (npm install into /usr/local), git, ripgrep, jq. Non-root user with
   UID/GID from build args (file ownership on the bind mount). `ENV DISABLE_AUTOUPDATER=1`. No sudo.
   **Language toolchains are optional build profiles**, not baked into the base: ship a `php`
   profile (PHP 8.3 CLI with intl, zip, gd, mysqli, pdo_mysql, mbstring, xml, curl; composer;
   mariadb-client - enough for PrestaShop) and design so others can add profiles (e.g. python).
   Handle host GIDs that collide with existing Debian groups (macOS users are GID 20 = `staff`,
   which is `dialout` in Debian).
2. **`proxy/`** - egress proxy container (squid) with the domain allowlist in a separate file:
   only CONNECT to port 443 for listed domains, everything else denied and logged, no cache.
   Default allowlist: Anthropic domains needed for the API, OAuth login and token refresh (VERIFY
   the current list in the Claude Code docs on network/proxy configuration and in
   `.devcontainer/init-firewall.sh` in the anthropics/claude-code repo), registry.npmjs.org.
   Presets, off by default, switched with a flag: `php` (packagist.org, repo.packagist.org,
   getcomposer.org), `github` (github.com, api.github.com, codeload.github.com,
   objects.githubusercontent.com - composer often needs it, but it is an exfiltration channel;
   say so wherever it is enabled).
3. **Network:** `docker network create --internal` with a fixed subnet; the proxy has a fixed IP on
   the internal network and is also attached to a network with egress. Project containers are only
   on the internal network; `HTTPS_PROXY`/`HTTP_PROXY` point to the proxy IP (not a name), and DNS
   is disabled (`--dns` set to an address where nothing listens) to close DNS exfiltration. Verify
   that Claude Code and npm/composer work through the proxy without DNS; if something needs DNS,
   document the trade-off. Verify the scheme works on Docker Desktop (macOS, WSL2 backend) as well as
   native Linux Docker - Docker Desktop has its own DNS/proxy layer; document any difference.
   Make the subnet configurable (it may collide with a user's LAN/VPN).
4. **`bin/claude-ide-box-exec`** - the wrapper for the extension. Requirements:
   - NOTHING may reach stdout except the stdout of the process in the container. Logs go to a file
     (`$XDG_STATE_HOME/claude-ide-box/wrapper.log`, default `~/.local/state/claude-ide-box/wrapper.log`) and
     optionally stderr.
   - Logs date, PWD, full arguments and the NAMES (not values) of passed environment variables.
   - Drops leading non-flag arguments (paths to the binary/interpreter) up to the first one
     starting with `-`. Must handle 0, 1 and 2 leading paths. If the extension passes flags carrying
     host paths outside the project (e.g. `--mcp-config`, `--plugin-dir`, `--settings` with a file),
     log a warning; design the safe behaviour and document it.
   - The extension also runs the wrapper for one-shot subcommands, not just chat sessions (see
     PLATFORM-NOTES). These must work too, or fail with a clear message on stderr.
   - Project directory = PWD at launch. Mounted at the IDENTICAL path inside the container,
     `docker exec -w "$PWD"`.
   - Container name: `claude-ide-box-<basename>-<first 8 hex of sha256 of the absolute path>`
     (sanitise the basename for Docker's name rules). If the container does not exist or is
     stopped, the wrapper creates/starts it, with a lock against parallel starts (no `flock` on
     macOS - see PLATFORM-NOTES). Fail closed: if Docker is not running, exit with an error and never run
     anything on the host.
   - Passes `CLAUDE_CODE_*`, `CLAUDE_AGENT_SDK*`, `MCP_*` from the host into the container, except
     those holding host paths (e.g. `CLAUDE_CONFIG_DIR`). Token from file (see login).
   - Also works when invoked directly instead of the binary (see guard).
5. **`bin/claude-ide-box`** - management CLI: `setup` (build images, network, proxy), `login` (one-off
   `claude setup-token` in a temporary container behind the proxy; token saved to
   `$XDG_CONFIG_HOME/claude-ide-box/token` with mode 600 and passed as `CLAUDE_CODE_OAUTH_TOKEN`),
   `up`/`down`/`rm` for the current project, `shell` (bash in the project container), `status`,
   `logs` (wrapper + denied proxy requests), `allow <domain>` / `preset <name> on|off`, `guard`,
   `doctor`, `help`.
6. **Secret masking:** global config OUTSIDE the project (`$XDG_CONFIG_HOME/claude-ide-box/config`),
   never in the project repo, because Claude could modify it. Masked by default (only if they exist;
   files via bind of `/dev/null:ro`, directories via empty tmpfs): `.env`, `.env.*`. PrestaShop
   preset adds: `app/config/parameters.php`, `app/config/parameters.yml`, `config/settings.inc.php`.
   Mounted read-only (created on the host if missing, so Docker does not create them as root):
   `.git`, `.vscode`, `.agent`, `.agents`, `.idea`, `.devcontainer`, `.claude` - files executed or read by host
   tools (IDE, git hooks, the Antigravity agent). Per-project option (in the global config) to make
   `.git` writable. Mask list and read-only list are configurable globally and per project.
7. **Hard container settings:** `--cap-drop ALL`, `--security-opt no-new-privileges`, `--read-only`
   with tmpfs on /tmp, `--pids-limit`, memory/CPU limits, `--init`, non-root user, NO
   `/var/run/docker.sock`, no mounts of ~/.ssh, ~/.aws, ~/.gitconfig with a credential helper, etc.
   The container user's home on a named volume PER PROJECT (client isolation - a hook in one
   project's ~/.claude must not affect another). `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` by
   default, with an option to turn it off.
8. **`guard`:** defence against extension regressions. Finds the binary bundled with the extension
   in every known extension directory (see PLATFORM-NOTES for the full list and BOTH bundled-binary
   layouts) and replaces it with a symlink to `claude-ide-box-exec`, keeping the original as `.orig`.
   So even if the extension ignores `claudeProcessWrapper`, it still lands in the container. The
   wrapper silently runs guard for new extension versions on every start. Provide `guard --undo`.
   The wrapper never executes the host binary or the `.orig` copy - it only ever runs `docker`.
9. **`doctor`:** checks Docker, images, network, proxy, token, guard, presence of `claude` on the
   host PATH (warning), the `claudeProcessWrapper` and `useTerminal` settings in the user
   settings.json of every installed IDE (paths per OS in PLATFORM-NOTES), and whether any claude process
   runs outside the container. Output: one line per check with a status; non-zero exit on failure.
10. **`install.sh`** - installs to `~/.local/bin`, no sudo, idempotent, prints the user-settings
    snippet (`"claudeCode.claudeProcessWrapper": "<path>"`, `"claudeCode.useTerminal": false`) -
    USER settings, never workspace settings (a workspace setting lives in the repo Claude can edit).
    Provide an uninstall path.

## Tests (required)

- shellcheck on all scripts, plus a CI workflow (GitHub Actions) running shellcheck and the unit
  tests on ubuntu-latest and macos-latest (macOS runner = bash 3.2, BSD userland - this is what
  catches portability bugs).
- Unit tests of the wrapper with a fake `docker` on PATH: argument stripping (0, 1 and 2 leading
  paths), stdout cleanliness, container name, masks only for existing files, fail closed.
  bats-core or plain bash; the choice is justified in TESTING.md.
- Integration tests, wherever a Docker daemon is available (skipped with a clear message otherwise): build the images, start a test
  project container and confirm that: (a) an allowed domain passes through the proxy, a disallowed
  one and a direct connection without the proxy are blocked, (b) DNS does not work, (c) masked files
  are empty/inaccessible, (d) writes to .git and .vscode fail, (e) writes to the project work and
  files get the host UID, (f) no capabilities and no docker.sock, (g)
  `claude-ide-box-exec /fake/native-binary/claude --version` returns the version and nothing else on
  stdout. Subscription login is not tested automatically.
- `TESTING.md`: an honest list of what was verified automatically and what needs manual checking on
  a real machine, with a checklist: wrapper argument log after the first launch from Antigravity,
  `ps` on the host shows only `docker exec`, asking "read ~/.ssh/id_rsa" and "curl example.com"
  fails, a file edit from the extension panel appears in the editor, diffs and permission prompts
  work, resuming conversations works. Per-platform rows (Linux / WSL2 / macOS).

## Documentation

`README.md` in English, written for strangers on GitHub: what it is and what it is not (one
paragraph), architecture (simple ASCII diagram), threat model and its limits - stated plainly:
Claude can modify project files, so anything the host later executes from the project (composer/npm
scripts, Makefile, direnv, CI after push) needs review before running on the host; allowlisted
domains are potential exfiltration channels; conversation history lives in the container volume,
not in the host's ~/.claude. Step-by-step install per platform, daily use, updating the Claude Code
version, troubleshooting. Plain hyphens, not em dashes. Add `SECURITY.md` (how to report a sandbox
escape) and keep `LICENSE` (MIT, already present).

## Hard rule

Never add anything that mounts the Docker socket or the host home directory into a container, not
even "for convenience". If a requirement here can only be met by weakening isolation, the
requirement is wrong - raise it instead of working around it.
