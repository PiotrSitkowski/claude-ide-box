# Native Windows isolation - design proposal

Status: **proposal, nothing built.** This document decides whether a second Windows backend is
worth building, next to the WSL2 + Docker backend that ships today.

**Feasibility test, 2026-11-09 ([results](#feasibility-results-2026-11-09)): network and DNS
isolation - go, with a simpler design than proposed below; Claude Code itself - go; git and a
shell inside the sandbox - stop.** Without git and a shell a programmer cannot work, so the
backend is not built in this form.

## Why

Programmers on Windows keep their repositories on `C:`. The WSL2 backend reaches them through 9p
(or experimental virtiofs), which is far too slow for a repository of real size. The same four
operations were measured on `quanti-platform` (14,020 files, 13,350 outside `.git`) on the same
machine: Windows 10 Pro 19045, Xeon E5-2673 v3, NVMe SSD, Defender real-time protection on.

| Operation | `C:` from a WSL container, 9p | `C:` from a WSL container, virtiofs | Linux file system in WSL | **Native Windows** |
|---|---|---|---|---|
| List files | 3.5-4.8 s (`find`) | 4.0 s (`find`) | 0.03-0.05 s | **0.10-0.16 s** (`rg --files`); 0.74-0.86 s (`find`, Git Bash) |
| Search contents | 53-163 s (`grep -r`) | 23-30 s (`grep -r`) | 0.2 s | **0.19 s** (`rg`, respects `.gitignore`, as Claude Code's search does); 0.36-0.41 s (`rg`, every file); 6.2-7.0 s (`grep -r`, Git Bash) |
| `git status` | 130-152 s | 74 s | 3.5 s | **0.12-0.14 s** (Git for Windows defaults); 0.34-0.48 s with `core.fscache` and the untracked cache off |
| Read 200 source files (1.5 MB) | - | 0.66-0.92 s | - | **0.09-0.12 s** |

Notes on the numbers:

- All native runs are warm (three runs, the files had been read before). A cold cache needs a
  reboot to reproduce; the WSL columns include cold first runs, which is where their upper bounds
  come from.
- The earlier "read 200 files" figures (3.5-4.4 s through WSL, 0.05 s on the Linux file system)
  measured mostly a full directory listing: the command picked `*.cs`, `*.php` and `*.js` files
  and this repository has only a handful. The table uses 200 tracked `.ts` files instead.
- Search compares different tools across columns. With the same tool (GNU `grep -r`), native
  Windows under Git Bash is still 4-5x faster than virtiofs and 10-25x faster than 9p; Claude Code
  itself searches with ripgrep, which is the 0.19 s figure.
- `git status` is the decisive row: 0.13 s natively against more than a minute through WSL, for
  the same tool and the same files.

### Claude Code's own search (ripgrep), measured 2026-11-09

Claude Code searches with ripgrep, not GNU grep, so the search row above overstates the gap. The
same repository, from inside a project container on the folder on `C:`, warm cache:

| | Files searched | `C:` from WSL, **9p (default)** | `C:` from WSL, virtiofs | Native Windows |
|---|---:|---:|---:|---:|
| `rg -l TODO .` (ignores hidden and `.gitignore`d files) | 4,629 | 2.0-2.6 s | 4.7 s | 0.19 s |
| `rg -l --hidden TODO .` | 14,056 | 8.1-8.4 s | 15.0-16.6 s | 0.49-0.60 s |
| **Claude Code's Grep tool** (pattern `TODO`, files with matches; time from the tool call to its result in a `claude -p` session) | as `--hidden` | **9.0 s** | 14.6-15.0 s | - |

- The folder holds 14,066 files (13,350 outside `.git`). ripgrep searches 4,629 of them by default;
  Claude Code's Grep tool includes hidden files (64 matches against 26), here mostly a hidden
  `.agent` folder of 8,692 files, so its time matches `rg --hidden`.
- **The default 9p is the reference: about 9 s per Claude search** on a repository of this size,
  about 15 times native. GNU grep took 53-163 s there, so ripgrep helps a lot, but reading files
  across the Windows/WSL boundary stays the bottleneck; on a Mac the same kind of
  repository took 0.86 s with ripgrep.
- **virtiofs is not recommended**: slower than 9p for this workload (and experimental).

Native Windows is as fast as the Linux file system or faster, with the files where they already
are and a single copy of them. The cost is a different isolation model, described below.

## What the container gives today

The README's threat model lists what Claude cannot do inside the container. The native backend
has to answer each row. In short: only the project directory is visible; `.env` files are masked;
`.git`, `.vscode`, `.idea`, `.agent`, `.agents`, `.devcontainer` are read-only; there is no route
out except an allowlisting proxy; there is no DNS resolver; the host and LAN are unreachable; the
process is unprivileged; nothing of the IDE's connection is bridged in; each project has its own
container and home volume.

Claude Code has no sandbox of its own on native Windows (its documentation: "On native Windows,
Claude Code runs commands unsandboxed" and it recommends WSL2 or a container for Windows users).
Whatever we build here is the only boundary.

## Proposed architecture

```
VS Code (Windows, profile "Claude IDE Box")
  Claude Code extension
    claudeCode.claudeProcessWrapper = %LOCALAPPDATA%\ClaudeIDEBox\bin\claude-ide-box-exec.exe
      launcher (runs as the user, outside the sandbox)
        - checks the project folder, drops host-path flags (as the Linux wrapper does)
        - prepares ACLs, starts the proxy if needed, checks that isolation is in force
        - CreateProcess(claude.exe) in the project's AppContainer (LPAC), inside a Job object
          stdin/stdout = the extension's stream-json, nothing else is shared
      proxy (runs as the user): CONNECT :443 to allowlisted domains only, on 127.0.0.1
```

### The building blocks

- **AppContainer** is the Windows sandbox used by Edge, Chrome and Office for untrusted code. A
  process in it gets a token with a package SID and Low integrity. An access check succeeds only
  if the object's ACL grants that SID (or the group "ALL APPLICATION PACKAGES") on top of the
  normal user check. The user's own files carry no such entry, so they are denied by default.
- **Less Privileged AppContainer (LPAC)** removes the "ALL APPLICATION PACKAGES" group as well. Only
  objects that name the SID, or "ALL RESTRICTED APPLICATION PACKAGES", are reachable. That is
  closer to "only the project is mounted".
- **One AppContainer profile per project** (name derived from the project path hash, as the
  container name is today). Each project has its own SID and its own storage folder
  (`%LOCALAPPDATA%\Packages\<profile>\AC`), which becomes its `HOME` and its `~/.claude`. Projects
  cannot read each other.
- **Job object** around the process tree: all children inherit the AppContainer token (it cannot
  be shed), the tree dies with the session, and process count and memory are limited.
- **Windows Defender Firewall** rules can target an AppContainer SID (`New-NetFirewallRule
  -Package <SID>`, present on this machine), and network access of an AppContainer is denied
  unless granted by capabilities.

### A separate Windows account: considered, not the default

A separate local account ("ClaudeIDEBox") with access to the project folder only was the first
idea. It is not proposed as the default because:

- Starting a process as another user needs that user's password (`CreateProcessWithLogonW`) or a
  service/scheduled task acting for it. Storing a password, or installing a service that starts
  processes on request, adds a privileged component and its own attack surface.
- Files Claude creates would belong to the other account. Git for Windows then refuses the
  repository ("dubious ownership") until `safe.directory` is relaxed, and the user's tools meet
  files they do not own.
- Creating the account needs administrator rights and leaves a visible account on the sign-in
  screen and in company audits.
- It does not restrict the network at all.

AppContainer gives the same "deny everything but the project" without a second account. A
separate account remains an optional hardening for managed environments (AppContainer *inside* a
dedicated account), not part of the first version.

## Disk

| Container today | Native proposal |
|---|---|
| only the project directory is mounted | the launcher grants the project's SID *Modify* on the project folder (inherited ACE); everything else is denied by the AppContainer check |
| `.env`, `.env.*` masked by an empty read-only file | an explicit *Deny read/write* ACE for the SID on each matching file, applied at every start |
| `.git` (any depth), `.vscode`, `.idea`, `.agent`, `.agents`, `.devcontainer` read-only | *Deny write/delete/change-permissions* ACE for the SID, inherited inside those folders; missing ones are created first, as today |
| swapped or renamed masked file stops the start | the ACE travels with the file on rename within the volume; the launcher re-scans and records file IDs (NTFS file ID instead of inode) and stops on a mismatch |
| paths with commas or quotes are refused | same rule; plus refuse folders the current checks refuse (drive root, `C:\Users`, the profile itself, `AppData`, `Windows`, `Program Files`) |
| - | refuse volumes without ACLs (FAT32/exFAT, many network shares), because nothing can be enforced there |

Tools Claude needs (`claude.exe`, Git for Windows, Node, Python, ripgrep) must be readable and
executable by the SID. `C:\Windows` and, for regular AppContainers, `C:\Program Files` are; tools
installed per user (`%LOCALAPPDATA%\Programs`, nvm, pyenv, `~\.dotnet\tools`) are not and would
need explicit grants. Grants go to the tool's folder only, never to a folder that also holds
configuration (`%USERPROFILE%\.npmrc` holds registry tokens, for instance). The first version
should ship its own pinned toolchain under `%LOCALAPPDATA%\ClaudeIDEBox\tools` and grant only that.

## Network

> Tested on 2026-11-09: the loopback exemption + firewall approach below does **not** work,
> because the firewall does not filter loopback. See
> [results, question 3](#3-can-the-network-proxy-be-bypassed---original-plan-stop-new-variant-go)
> for the in-container relay and named pipe that replace it.

- The AppContainer gets **no network capabilities** (`internetClient`, `privateNetworkClientServer`
  and the rest), so it has no direct route to the internet or the LAN.
- To reach the proxy on `127.0.0.1`, the SID needs a **loopback exemption** (`CheckNetIsolation
  LoopbackExempt -a -p=<SID>` or `NetworkIsolationSetAppContainerConfig`). That exemption opens
  *every* loopback port, including dev databases and the VS Code server's ports, so it is paired
  with firewall rules for the SID: block all loopback ports except the proxy's.
- The proxy reuses today's allowlist and presets (`proxy/`): CONNECT to port 443 of listed domains,
  everything denied is logged. It runs outside the sandbox as a small native program (a Windows
  build of squid is possible, a purpose-built CONNECT proxy is simpler to ship and audit).
- **DNS**: the container has no resolver. Whether an AppContainer without network capabilities can
  make the DNS Client service resolve arbitrary names (a classic exfiltration channel) has to be
  tested; if it can, the gap must be closed or documented.
- Exemptions and firewall rules need **administrator rights**. Per-project SIDs would mean an
  elevation prompt for every new project. Proposal: the installer (already elevated once for WSL
  today) creates a **pool of profiles** (for example 32) with their exemptions and rules, and
  projects are assigned to free slots. No privileged service stays running.
- **Fail closed**: before every start the launcher probes from inside the sandbox that a
  non-allowlisted host, a LAN address and a loopback port other than the proxy's are unreachable.
  If the firewall is off, replaced by a third-party product, or a company policy ignores local
  rules ("Apply local firewall rules: No"), the probe fails and Claude does not start.

## Secrets and other channels

- **Environment**: the launcher builds the environment from an allowlist (as the Linux wrapper
  passes variables by name); nothing like `GITHUB_TOKEN` or `AWS_*` leaks in by inheritance.
- **User's secret stores**: `%USERPROFILE%\.ssh`, `.aws`, `.azure`, `.kube`, `.gitconfig`,
  browser profiles, `%APPDATA%` are denied by the AppContainer check. Credential Manager and DPAPI
  are per user and broker-mediated; denial from an AppContainer must be verified, not assumed.
- **Claude's own token** lives in the AppContainer's storage of each project (like the home volume
  today); the sign-in URL is opened by the launcher, outside the sandbox, with today's host
  allowlist.
- **Clipboard, windows, keystrokes**: an AppContainer process shares the user's window station.
  UIPI stops it from sending input to normal windows, but clipboard reading must be checked.
  Claude needs no UI, so the launcher should start it on a separate window station and desktop,
  which removes the clipboard and window channel entirely.
- **Win32k**: the process mitigation that disallows win32k system calls (used by Chrome renderers)
  removes a large kernel surface, if `claude.exe`, Git Bash and Node run without it. To be tested.

## What is weaker than the container

1. **The boundary is the Windows kernel and its services.** A container shares the Linux kernel of
   the WSL VM; an AppContainer shares the Windows kernel and can talk to RPC/COM services that
   are designed to accept AppContainer callers. AppContainer is heavily used and patched, but its
   escapes are found every year, and the browsers that rely on it also tune and test their use of
   it. (WSL is not a perfect wall either: an escape from the container to root in the WSL VM
   reaches `C:` as the user through `/mnt/c` and interop.)
2. **Masks are ACLs on the real files, not mounts.** A new `.env` created by the user between two
   starts is unprotected until the next start (the container has the same window for files
   created mid-session, but there the mask set is fixed at start). The deny entries are visible to
   the user's own tools and can be lost by tools that rewrite ACLs or copy without them.
3. **The network relies on configuration we do not own.** Firewall policy, third-party security
   products and Windows updates can change the outcome; the container's network is a property of
   the container itself. The start-time probe turns this into a failed start instead of a silent
   leak, but the outcome depends on the machine.
   (After the test: the relay + named pipe variant does not depend on the firewall, so this point
   largely goes away.)
4. **DNS isolation** was unknown before the test; it holds as long as no network capability is
   granted (see the results).
5. **No immutable image.** In the container the system is read-only and rebuilt from the image;
   here the toolchain is files on disk, protected by ACLs only.
6. **Tool parity.** Claude's Bash tool needs Git Bash (Cygwin/MSYS), which may not work in an
   AppContainer; Claude Code falls back to PowerShell since 2.1.120. Office modules (pandoc,
   Tesseract, LibreOffice) would need Windows builds that run sandboxed; LibreOffice in an
   AppContainer is doubtful.
7. **Administrator rights at install time** for exemptions and firewall rules (WSL needs them
   once too, so the user experience is similar).
8. **Clean-up** must remove ACEs from every project folder ever used, including folders the user
   moved.

What stays the same: Claude can change every project file and the host may later run them;
every allowlisted domain is an exfiltration channel; the extension is trusted.

## Recommendation

Build the native backend **for programmers only**, and keep WSL2 + Docker for office work, where
files are few and small and the Linux document tools (OCR, LibreOffice) are needed. The choice
screen already separates the two purposes; "both" would install both backends and pick per
project (a folder under `Projects` in WSL for documents, a repository on `C:` natively).

Do not build anything until the spike below passes.

## Feasibility results (2026-11-09)

Throwaway test tool (C# compiled with the .NET Framework compiler that ships with Windows, about
250 lines): it starts a process in an AppContainer or LPAC, runs a CONNECT proxy with
`proxy/allowlist.txt`, and probes network, DNS, devices and named pipes. Machine: Windows 10 Pro
22H2 19045.6466, Git for Windows 2.35.1, Claude Code 2.1.318 (`claude.exe` from
downloads.claude.ai, SHA256 checked against the manifest, signature valid). The project was a
copy of `quanti-platform`; the real repository was not touched. Everything was removed afterwards:
profiles, ACL entries, the loopback exemption, firewall rules, and the change to the `NUL` device.

### 1. Can DNS be blocked? - GO

| Probe from the AppContainer (no capabilities) | Result |
|---|---|
| TCP to 1.1.1.1:443, to the LAN gateway | blocked, `AccessDenied` |
| UDP DNS query straight to 8.8.8.8 | no answer (time-out) |
| system resolver (`getaddrinfo`) for `example.com` | fails, even though the host has it cached |
| system resolver for a unique random name | fails, and **the name never reaches the Windows DNS cache**; the same query from outside the sandbox is cached as an upstream NXDOMAIN (status 9501). The query does not leave the machine. |

The same holds with the loopback exemption and firewall rules in place.

**Condition:** the AppContainer must never get a network capability. With `internetClient`
granted and firewall rules blocking all of its traffic, a unique name *was* resolved upstream:
the DNS Client service sends the query on the sandbox's behalf, and the firewall rules for the
package do not apply to that service.

### 2. Does Claude Code with git and search work in an AppContainer? - Claude Code: GO; git and shell: STOP

| Tool | AppContainer | LPAC |
|---|---|---|
| `claude.exe --version` | works | works |
| a real `claude -p` session (Grep, Glob, Read tools, through the proxy) | works: 27 s with the model's answer, only `api.anthropic.com` in the proxy log | not tried |
| ripgrep (14k-file project) | `--files` 0.12-0.25 s, search 0.46-0.66 s; outside the sandbox 0.44 s | works, same speed |
| reading `~\.gitconfig`, listing `source\repos` | denied (as intended) | denied |
| writing in the project | works after the project is labelled Low integrity (`icacls /setintegritylevel (OI)(CI)low`); without the label every write is denied | - |
| Git for Windows | **fails at start**: `could not open '/dev/null'` | fails: `Program Files` is not readable |
| Git Bash (MSYS2/Cygwin) | **fails**: `NtCreateDirectoryObject` fatal error (Cygwin cannot create its object directory in the AppContainer's namespace) | fails |
| Windows PowerShell 5.1 (Claude Code's shell when Git Bash is missing) | starts, but its file system provider cannot initialise (`C:\` not readable), so no paths work | - |
| .NET Framework programs | work | do not start |

Why git fails:

1. The `NUL` device on this build has the DACL
   `D:(A;;0x1201bf;;;WD)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;RC)`: no entry for "ALL APPLICATION
   PACKAGES", so `CreateFile("NUL")` returns error 5 in any AppContainer. Git opens `/dev/null`
   on every start. With an `AC` entry added to the device (administrator, system-wide, lost at
   every reboot) `git --version` works.
2. Even then `git status` stops with `Unable to read current working directory: Permission
   denied`. Granting traverse and read-attributes on every parent folder inside the profile did
   not help; most likely the path normalisation lists every parent up to `C:\`, which would mean
   granting directory listings of `C:\`, `C:\Users` and the profile (administrator for the first
   two). Not pursued further.

Open: Claude Code's Grep tool reported hitting its time limit inside the sandbox, although
ripgrep run directly took 0.5 s. Unexplained.

Claude Code itself works. Its file tools (Read, Edit, Write, Grep, Glob) run inside its own
process. Git, the shell, and everything a programmer runs through it (tests, builds, package
managers) do not, unless the system is changed globally or each tool gets a broker outside the
sandbox. Node, npm and Python were not tested.

### 3. Can the network proxy be bypassed? - original plan: STOP; new variant: GO

| Setup | Proxy | Other local port (a "dev database") | Internet, LAN, UDP |
|---|---|---|---|
| no exemption | unreachable | unreachable | blocked |
| loopback exemption (admin) | reachable, allowlist enforced (`api.anthropic.com` 200, `example.com` 403) | **reachable** | blocked |
| exemption + firewall rules for the SID blocking every TCP port but the proxy's | reachable | **still reachable** | blocked |

**Windows Firewall does not filter loopback traffic.** A loopback exemption therefore opens every
local service to the sandbox, and firewall rules cannot narrow it. The firewall rules do apply to
the package off loopback: even with `internetClient` granted, 1.1.1.1:443 stayed blocked.

A variant without exemption, firewall rules or administrator rights, whose two halves were each
verified (not built end to end):

- **Loopback inside one AppContainer works without an exemption.** A listener in container B was
  reachable from another process in B, but not from container A or from outside. Host ports
  stayed unreachable from B.
- **A named pipe with a DACL for one SID** is reachable from that AppContainer and refused to
  another one (no Low integrity label needed).

So: a small relay inside the sandbox listens on `127.0.0.1` (`HTTPS_PROXY` points to it) and
forwards over a named pipe, open only to this project's SID, to the allowlisting proxy on the
Windows side. Nothing else on the machine is reachable, and none of it depends on the firewall
configuration or on company policy.

### Verdict

Network and DNS isolation are feasible and simpler than proposed above: no administrator rights,
no firewall rules. The toolchain is the blocker. Git for Windows, Git Bash and Windows PowerShell
are not built to run in an AppContainer, and making them work means system-wide changes (the `NUL`
device ACL on every boot, listings of `C:\` and `C:\Users`), or brokers that run tools outside
the sandbox and weaken it. **Stop** the native backend in this form.

Worth one more check before closing it for good: the same tests on Windows 11 (the `NUL` device
ACL and git's start-up may differ) and with Node and Python.

## Spike plan (done; results above)

Each is a small test program, thrown away afterwards.

1. `claude.exe` (pinned version) runs in an LPAC with a stream-json session from the extension,
   reads and edits the project, and cannot open `%USERPROFILE%\.ssh\*`, another project, or a
   denied `.env`.
2. Git for Windows (`git status`, `git diff`), ripgrep and Node work in the LPAC; Git Bash either
   works or the PowerShell fallback is acceptable.
3. Network: with only a loopback exemption plus firewall rules, the process reaches the proxy and
   nothing else (internet, LAN, other loopback ports); arbitrary DNS lookups fail.
4. The same with "Apply local firewall rules: No" set by local policy: the probe detects it.
5. Clipboard and window access from the sandbox, with and without a separate window station; the
   win32k lockdown.
6. Speed inside the sandbox: the four operations above again (ACL checks and Defender should not
   change them much, but it must be measured).

Go if 1-3 and 6 pass and 4-5 are either solved or acceptable as documented limits.

## Effort (one person, after a successful spike)

| Part | Days |
|---|---|
| Launcher `claude-ide-box-exec.exe` (must be an `.exe`: the extension spawns the wrapper without a shell): AppContainer/LPAC, Job object, separate desktop, env allowlist, argument filtering, logging | 6-9 |
| ACL manager: project grant, masks, read-only folders, file-ID records, re-scan, refusals, clean-up | 4-6 |
| Network: Windows proxy with today's allowlist and presets, profile pool with exemptions and firewall rules, start-time probe | 6-9 |
| Toolchain: pinned Claude Code, Git, ripgrep, Node under `ClaudeIDEBox\tools`, updates | 3-5 |
| Installer, settings shortcut, `doctor`, uninstall, i18n | 4-6 |
| Tests: unit tests and an attack suite run in CI on Windows (read secrets, write `.git`, reach hosts, DNS, loopback, clipboard) | 5-8 |
| Security review and hardening, documentation (README, SECURITY.md, threat model rows) | 4-6 |
| **Total** | **32-49 days, about 7-10 weeks** |

Not included: code signing of the launcher and the installer (needed anyway against SmartScreen),
and Windows ARM64 builds.

## Appendix: how the native numbers were taken

Git Bash, in the repository root, three runs each:

```sh
find . -type f
grep -rI --exclude-dir=.git -l TODO .
git -c core.fsmonitor=false --no-optional-locks status --porcelain
rg --files --hidden --no-ignore -g '!.git'
rg -l --hidden --no-ignore -g '!.git' TODO
rg -l TODO
```

PowerShell, 200 tracked `.ts` files (the same list was read through WSL for the virtiofs column):

```powershell
$list = git ls-files -- '*.ts' | Select-Object -First 200
foreach ($x in $list) { [IO.File]::ReadAllBytes((Join-Path $PWD $x)) | Out-Null }
```
