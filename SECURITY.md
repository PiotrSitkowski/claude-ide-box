# Security policy

Claude IDE Box is a sandbox. A way out of it is the most serious bug it can have, and reports are very
welcome.

## Reporting a sandbox escape

Please report privately through **GitHub's private vulnerability reporting**:
[Security → Report a vulnerability](https://github.com/PiotrSitkowski/claude-ide-box/security/advisories/new).
Do not open a public issue for anything in the "in scope" list below.

A useful report contains:

- host OS, Docker flavour and version (`docker version`), IDE and extension version;
- `claude-ide-box doctor` output;
- the steps, run from inside the project container (`claude-ide-box shell`) or as a prompt to Claude,
  that reach something they should not;
- what you expected and what happened.

You will get an acknowledgement within a week. Fixes are released as soon as they are ready, and
the advisory credits you unless you prefer otherwise.

## In scope

Anything that lets a process **inside a project container**, or a file in the project directory,
do one of these:

| Goal | Examples |
|---|---|
| execute code on the host | through the wrapper, the CLI, `guard`, `install.sh`, or anything Claude IDE Box itself runs on the host |
| read host data outside the project | home directory, `~/.ssh`, other projects, the token file |
| read a masked file | `.env`, `.env.*`, the other default masks, an `.mcp.json` holding a secret, configured masks |
| write a read-only path | `.git`, `.vscode`, `.idea`, `.agent`, `.agents`, `.devcontainer`, configured entries |
| reach the network beyond the allowlist | other domains, other ports, bare IPs, DNS, host or LAN services |
| change the sandbox configuration | anything under `~/.config/claude-ide-box`, the proxy allowlist |
| make the wrapper run `claude` on the host | any fail-open path |
| start in a folder holding restored personal data | a container starting in, above or below a copy or restored folder recorded by pii-airgap whose check reports values of its token map, whose map is missing or replaced, or whose check fails; the map reaching the project container |

## Out of scope

- What the host does with project files afterwards. Claude can edit the project by design; running
  its `Makefile`, `composer` or `npm` scripts, `.envrc` or a test suite on the host is outside the
  sandbox (see the threat model in the README).
- Data sent to an allowlisted domain. Allowlisted domains are deliberate exits; that includes the
  project content Claude reads, which goes to the Anthropic API. To reduce the personal data in it,
  see [pii-airgap](https://github.com/PiotrSitkowski/pii-airgap).
- Container escapes through kernel or container runtime bugs - report those upstream (Docker,
  runc, containerd, the kernel). Known ones are refused: claude-ide-box will not set up or start a
  container on a Docker Desktop, Docker Engine or runc version listed in
  `lib/claude-ide-box/engine-versions.txt` (unless `ALLOW_VULNERABLE_DOCKER=1`); a way around that
  check *is* in scope. A Claude IDE Box configuration that makes such a bug reachable when it
  otherwise would not be *is* in scope.
- The IDE extension itself.

## Known limitations

These are documented trade-offs, not vulnerabilities. Proposals to close them are welcome.

- **Shared internal network.** All project containers sit on one internal network, so a process in
  one project's container can connect to a port another project's container listens on (nothing
  listens by default). Docker's `enable_icc=false` would also cut containers off from the proxy, so
  closing this needs one internal network per project with the proxy attached to each.
- **Docker-managed DNS stub.** Containers keep Docker's embedded resolver at `127.0.0.11`; it
  resolves names of containers on the same network but forwards nothing upstream
  (`--dns 127.0.0.1`).
- **The secret scan is a heuristic.** It reports values that look like secrets in config-like
  files and masks `.mcp.json` when it finds one; a secret in an unusual format or file is missed.
  The default masks and your own `MASK` entries are what guarantees a file is hidden.
- **Masks are applied when a container is created.** A secret file that appears while a session is
  running is visible to that session until the container is recreated; the next start recreates it
  or refuses to run.
- **Repositories created during a session.** A `.git` that Claude creates while the container runs
  is writable until the next start (then it is mounted read-only). The host only runs git in it if
  the IDE auto-detects sub-repositories, hence `"git.autoRepositoryDetection": false` in the
  recommended settings; `doctor` warns without it.
- **guard depends on the extension layout.** A new extension version is unguarded until the next
  wrapper start or `claude-ide-box guard`; `doctor` reports it.
- **Session history is not visible in the IDE panel.** The extension lists past conversations from
  `~/.claude/projects` on the host and reads them there directly, without asking the wrapper; they
  live in the project's container volume. Resume them inside the box (`claude-ide-box shell`, then
  `claude --resume`). Bind-mounting the project's transcript directory from the host into the
  container was considered and rejected for now, because it would give the boxed process write
  access to a host directory that unboxed tools read:
  - a Claude Code started on the host in the same project (`claude --continue`, another IDE
    profile) would load transcripts written in the box - prompt injection carried into an
    unsandboxed session, with the host's tools and network;
  - the host's `memory/` directory there is loaded into the context of host sessions; it would
    have to be covered by a separate volume, and any other file Claude Code starts reading from
    that directory in a later version would be a new channel;
  - the extension on the host would read files the container controls: symlinks to host files,
    FIFOs or very large files can hang or mislead it.
  A narrower alternative under consideration: after a session, copy only regular `*.jsonl` files
  with session-id names and a size limit from the volume to the host (never `memory/`, never
  links), so the panel can list them; resuming from the panel still runs in the box. That removes
  the file-system risks and keeps `memory/` out, but a host session that resumes a copied
  transcript would still read text written in the box, so it would be opt-in.
