# Security policy

claude-box is a sandbox. A way out of it is the most serious bug it can have, and reports are very
welcome.

## Reporting a sandbox escape

Please report privately through **GitHub's private vulnerability reporting**:
[Security → Report a vulnerability](https://github.com/PiotrSitkowski/claude-box/security/advisories/new).
Do not open a public issue for anything in the "in scope" list below.

A useful report contains:

- host OS, Docker flavour and version (`docker version`), IDE and extension version;
- `claude-box doctor` output;
- the steps, run from inside the project container (`claude-box shell`) or as a prompt to Claude,
  that reach something they should not;
- what you expected and what happened.

You will get an acknowledgement within a week. Fixes are released as soon as they are ready, and
the advisory credits you unless you prefer otherwise.

## In scope

Anything that lets a process **inside a project container**, or a file in the project directory,
do one of these:

| Goal | Examples |
|---|---|
| execute code on the host | through the wrapper, the CLI, `guard`, `install.sh`, or anything claude-box itself runs on the host |
| read host data outside the project | home directory, `~/.ssh`, other projects, the token file |
| read a masked file | `.env`, `.env.*`, configured masks |
| write a read-only path | `.git`, `.vscode`, `.idea`, `.agent`, `.agents`, `.devcontainer`, configured entries |
| reach the network beyond the allowlist | other domains, other ports, bare IPs, DNS, host or LAN services |
| change the sandbox configuration | anything under `~/.config/claude-box`, the proxy allowlist |
| make the wrapper run `claude` on the host | any fail-open path |

## Out of scope

- What the host does with project files afterwards. Claude can edit the project by design; running
  its `Makefile`, `composer` or `npm` scripts, `.envrc` or a test suite on the host is outside the
  sandbox (see the threat model in the README).
- Data sent to an allowlisted domain. Allowlisted domains are deliberate exits.
- Container escapes through kernel or container runtime bugs - report those upstream (Docker,
  runc, containerd, the kernel). A claude-box configuration that makes such a bug reachable when it
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
- **Masks are applied when a container is created.** A secret file that appears while a session is
  running is visible to that session until the container is recreated; the next start recreates it
  or refuses to run.
- **guard depends on the extension layout.** A new extension version is unguarded until the next
  wrapper start or `claude-box guard`; `doctor` reports it.
