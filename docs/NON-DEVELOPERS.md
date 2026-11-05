# Claude IDE Box for non-developers - roadmap

Lawyers, HR, marketing teams, estate agents and other people who work with documents rather than
code have the same need as developers - "Claude may work on *this* folder and nothing else, and
client data must not leave" - often more urgently (contracts, CVs, personal data under GDPR). This
document records what is possible today, what the Claude apps allow according to their
documentation, and the proposed next steps.

> [!IMPORTANT]
> The findings below come from the documentation as of 2026-11-05 (links in each section). None of
> the stage 2 ideas has been tried on a real Claude Desktop installation yet. Where the documentation
> is silent, this page says so instead of guessing.

## Today: works, with an IDE

Claude IDE Box works with the Claude Code extension in VS Code, Cursor and Antigravity. Those are
programmers' editors, but nothing in the workflow requires programming:

1. Someone technical installs Docker, VS Code with the Claude Code extension, and Claude IDE Box,
   and runs `claude-ide-box setup --profile office`.
2. The user opens a folder of documents (a case, a recruitment round, a campaign) in VS Code and
   talks to Claude in the panel.
3. Inside the box Claude can read and edit `.docx`, `.xlsx`, `.pptx`, OpenDocument files and PDFs,
   convert between them and OCR scans in Polish and English (see
   [Office documents](../README.md#office-documents)). It sees only that folder, `.env`-style secrets
   are masked, and the network is limited to the Anthropic API.

The user keeps opening the same files in Word, Excel or LibreOffice on their computer.

What is missing for this audience: an installation without a terminal, and mask presets for typical
sensitive folders (ID scans, medical certificates, payroll), which can already be added per project
with `MASK`.

## What the Claude apps allow

### Claude Desktop, Code tab - no wrapper hook

- Local Code-tab sessions run "its own copy of Claude Code", downloaded and updated by the app,
  separate from any `claude` on the `PATH`. No setting for a custom executable or wrapper is
  documented. ([desktop](https://code.claude.com/docs/en/desktop))
- Managed settings apply to Desktop sessions; `disableDesktopLocalSessions: true` turns local
  sessions off. ([desktop](https://code.claude.com/docs/en/desktop))

So the mechanism Claude IDE Box uses in the IDE (`claudeCode.claudeProcessWrapper`) has no
documented equivalent in the Code tab.

### Corporate launcher (`processWrapper`) - not a fit

Claude Code has a launcher setting (`processWrapper` / `CLAUDE_CODE_PROCESS_WRAPPER`, macOS and
Linux only). The launcher must end with `exec "$@"` - run the real binary unchanged, with the same
arguments, environment and working directory. It wraps Claude Code on the host; it is not meant to
move Claude Code into a container. Whether the Desktop Code tab honours it is not documented.
([corporate-launcher](https://code.claude.com/docs/en/corporate-launcher),
[settings-reference](https://code.claude.com/docs/en/settings-reference))

### Claude Desktop SSH sessions - a documented path into a container

Desktop can run a Code-tab session on another machine over SSH. It installs its own Claude Code
under `~/.claude/remote/` on the remote side, and documents reaching a container with an SSH
`ProxyCommand` such as `ssh host docker exec -i <container> /usr/sbin/sshd -i`. It needs sshd with
SFTP in the container, a non-`noexec` install folder and about 1 GB free in the home directory;
`sshHostAllowlist` in managed settings restricts the hosts.
([desktop](https://code.claude.com/docs/en/desktop))

This is the most promising route: `docker exec -i ... sshd -i` speaks SSH over stdin/stdout, so it
keeps the design rule that stdin/stdout is the only channel between host and container - no port
is published and the container gains no network access.

### Cowork - already sandboxed

Cowork's local sessions run shell and code in a dedicated Linux VM (Virtualization.framework on
macOS, Hyper-V on Windows) that "enforces its own network egress filtering, syscall restrictions,
and per-session user isolation"; local file access is limited to folders the user connects.
([Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview))

For many non-developers Cowork may already be enough. Claude IDE Box would add value where an
organisation wants its own, auditable allowlist and masks, or one setup shared with its developers.
That needs a hands-on comparison before building anything.

### Built-in `/sandbox` - partial

Claude Code's own sandbox covers Bash commands only, not the built-in Read/Edit/Write/WebFetch
tools or MCP servers, on macOS, Linux and WSL2; whether it applies to Code-tab sessions is not
documented. ([sandboxing](https://code.claude.com/docs/en/sandboxing))

## Proposed stages

| Stage | Content | State |
|---|---|---|
| 1 | `office` profile; README section on documents; mask examples for personal data | done (this release), mask examples to do |
| 2 | **SSH mode prototype**: an `ssh` profile with sshd + SFTP that listens on nothing; `claude-ide-box ssh-config` prints the `ProxyCommand` entry for Desktop; allowlist entries for whatever Desktop downloads when it installs Claude Code remotely | to be tested by hand first |
| 3 | Installer without a terminal (macOS package, Windows installer driving WSL2/Docker Desktop), guided `doctor` | after stage 2 works |
| 4 | Comparison with Cowork for the same tasks: what each isolates, what an organisation can configure | research |

## Open questions for a hands-on test

1. Does a Code-tab local session honour `CLAUDE_CODE_PROCESS_WRAPPER` from `~/.claude/settings.json`
   (check the Self-exec entry in `/status`)?
2. Does Desktop's SSH session work through `ProxyCommand docker exec -i <container> /usr/sbin/sshd -i`
   with the container's read-only root filesystem, no capabilities and its internal network? Which
   hosts does it need to download Claude Code into the container, and can that be avoided by
   pre-installing it in the image?
3. Does the Code tab's remote session use the container's Claude Code version or force its own?
4. Does `/sandbox` apply to Code-tab sessions?
5. For document work, what does Claude IDE Box give that Cowork's VM does not, and the reverse?
6. Is the extension's `claudeCode.claudeProcessWrapper` contract the same as the launcher's
   (`exec "$@"`)? Claude IDE Box deliberately does not satisfy that contract - it replaces the
   binary instead of executing it.
