# Platform notes

Measured on 2026-11-05 on a real macOS host and in the shipped extension code. These take
precedence over anything inferred in `docs/DESIGN.md`. The extension is updated often - re-verify
against the newest version when changing launch or guard logic.

## How the extension launches the wrapper (extension 2.1.318, `extension.js`)

Deobfuscated from the minified source:

```js
function PB(ctx, env) {
  const wrapper = setting("claudeProcessWrapper");
  const bundled = findBundledBinary(ctx);            // may be undefined
  if (wrapper)
    return { pathToClaudeCodeExecutable: wrapper,
             executableArgs: bundled ? [bundled] : [],
             env, viaProcessWrapper: true };
  ...
}

function findBundledBinary(ctx) {
  const name = process.platform === "win32" ? "claude.exe" : "claude";
  const arch = isMusl() ? `${process.arch}-musl` : process.arch;
  // 1st layout: resources/native-binaries/<platform>-<arch>/claude
  // (win32-arm64 falls back to win32-x64)
  // 2nd layout: resources/native-binary/claude
  ...
}
```

Consequences:

- The wrapper gets **exactly one** leading path (the bundled binary) when one exists, **zero** when
  none is found. The "two leading paths (interpreter + script)" case is not produced by 2.1.318 but
  older versions or other SDK hosts may produce it - keep handling 0, 1 and 2.
- `guard` must cover **both** layouts: `resources/native-binaries/<platform>-<arch>[-musl]/claude`
  and `resources/native-binary/claude`. On the reference macOS host all installed versions
  (2.1.101 to 2.1.318) use the second layout.
- The extension runs the binary (= the wrapper) not only for chat sessions but also for one-shot
  subcommands with structured stdin/stdout (seen: dropping worktree registrations with `--json`;
  the extension error text mentions "the Claude Code run by the claudeCode.claudeProcessWrapper
  setting is too old"). The wrapper must pass these through unchanged.
- When `claudeProcessWrapper` is set, the extension changes some behaviour (e.g. it skips a
  permission-mode migration and treats sessions as "programmatic"). Not a blocker, but note in
  TESTING.md to compare panel behaviour with and without the wrapper.
- The settings key lives under `claudeCode.*`; legacy `claude-code.*` keys are migrated to
  `claudeCode.*` once. `doctor` should read both.

## Extension directories found on a real macOS host

```
~/.antigravity/extensions/anthropic.claude-code-<ver>-darwin-x64        # "Antigravity" app
~/.antigravity-ide/extensions/anthropic.claude-code-<ver>-darwin-x64    # "Antigravity IDE" app
~/.vscode/extensions/anthropic.claude-code-<ver>-darwin-x64
~/.cursor/extensions/anthropic.claude-code-<ver>-darwin-x64
```

Several versions coexist in one directory (old ones are not cleaned up immediately) - guard must
handle all of them. Also scan `~/.vscode-server/extensions` and `~/.cursor-server/extensions`
(remote/WSL hosts) and `~/.vscode-insiders/extensions`. On Linux/WSL2 the same dotted directories
apply under `$HOME`; on WSL2 the IDE runs on Windows and the extension runs in the WSL "server"
directory (`~/.vscode-server/...`).

## User settings.json paths

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/<App>/User/settings.json` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/<App>/User/settings.json` |
| Windows (WSL2 host side) | `%APPDATA%\<App>\User\settings.json` - reachable from WSL via `/mnt/c/Users/<user>/AppData/Roaming/<App>/User/settings.json` |

`<App>` values seen on macOS: `Antigravity`, `Antigravity IDE`, `Code`, `Cursor`. Also check
`Code - Insiders`. settings.json is JSONC (comments, trailing commas) - do not parse it with plain
`jq`; a grep-level check plus a clear message is acceptable.

## macOS host toolchain (what scripts can rely on)

| Tool | State on macOS 15 | Implication |
|---|---|---|
| `/bin/bash` | **3.2.57** | No associative arrays, no `mapfile`/`readarray`, no `${var,,}`, no `[[ -v ]]`, no `wait -n`. Scripts must run on bash 3.2 - do not require Homebrew bash. |
| `flock` | **absent** | Use an atomic `mkdir` lock with stale-lock detection (PID file), or `perl -e flock` (perl ships with macOS). |
| `sha256sum` | present (`/sbin/sha256sum`) on macOS 15; older macOS only has `shasum -a 256` | Fall back to `shasum -a 256`, then `openssl dgst -sha256`. |
| `realpath` | present | `readlink -f` is not on older macOS - prefer `cd -P && pwd -P`. |
| `timeout` | **absent** | Do not use it, or fall back to `gtimeout`/perl. |
| `sed -i`, `stat`, `date` | BSD variants | No `sed -i` without a suffix argument, no `stat -c`, no `date -d`. |
| `docker` | Docker Desktop (context `desktop-linux`, socket `~/.docker/run/docker.sock`) | The default context may point at a missing `/var/run/docker.sock`; respect `docker context` / `DOCKER_HOST`. Docker Desktop may not be running - fail closed with a helpful message. |
| CPU | x86_64 (Intel). Apple Silicon users are arm64 | Images must build on both amd64 and arm64. |
| IDs | UID 501, GID 20 (`staff`) | GID 20 exists in Debian as `dialout`; UID 501 is free. On Docker Desktop bind mounts, file ownership is mapped to the host user regardless of in-container UID - the "files get the host UID" test behaves differently than on native Linux. Document both. |

## The IDE process environment

The extension inherits the IDE's environment, which on macOS is the GUI launch environment, not the
login shell. `PATH` may lack `/usr/local/bin` or `/opt/homebrew/bin`; the wrapper must locate
`docker` robustly (check common locations) and log what it used.

## Reading the engine's versions

One call gives everything the minimum-version check needs:

```bash
docker version --format '{{.Server.Version}}|{{.Server.Platform.Name}}|{{range .Server.Components}}{{.Name}}={{.Version}};{{end}}'
```

| Engine | Seen |
|---|---|
| Docker Engine 29.9.2 on Linux (development sandbox) | `29.9.2|Docker Engine - Community|Engine=29.9.2;containerd=v2.4.2;runc=1.5.2;docker-init=0.19.0;` |
| Docker Desktop | `Platform.Name` is `Docker Desktop <version> (<build>)`, e.g. `Docker Desktop 4.98.0 (...)` |
| Rancher Desktop | the engine version carries a suffix, e.g. `29.9.2-rd` |
| Podman | the components list `Podman Engine`; there is no runc component when crun is the runtime |

Versions are compared numerically per component after taking the first dotted number from each
string, so suffixes (`-rd`, `+azure`, `-0ubuntu2`, `v` prefixes, `(build)`) do not matter. An
empty or non-numeric version (`unknown`, `dev`, a missing runc component) is treated as vulnerable.
The Docker Desktop row was not re-measured for this check; it follows the format documented for
`docker version` on Docker Desktop and has to be confirmed on a Mac.

## Read-only project `.claude`

Measured with Claude Code 2.1.318 driven the way the extension drives it (stream-json, permission
prompts over stdio, `--setting-sources=user,project,local`), against a fake Messages API, with
`.claude` mounted read-only - in a container (`tests/integration/permission-probe.js`) and with a
read-only bind mount on a Linux host:

- the extension's "always allow" arrives as a permission response with
  `updatedPermissions: [{type: "addRules", destination: "localSettings", ...}]`;
- with `.claude` read-only the rule still applies for the rest of the session (the same command is
  not asked about again), `.claude/settings.local.json` is not created or changed, nothing is printed
  on stderr and no error message reaches the stream; the session ends normally;
- the next session asks again;
- with a writable `.claude` (`CLAUDE_DIR_WRITABLE=1`) the same exchange writes the rule to
  `.claude/settings.local.json`.

Claude Code also creates `.claude/worktrees/<name>` for worktree sessions; those cannot work with a
read-only `.claude`.
