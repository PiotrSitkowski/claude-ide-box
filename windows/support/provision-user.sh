#!/usr/bin/env bash
# Run by windows/install.ps1 as the default user inside the ClaudeIDEBox WSL
# distribution:
#
#   provision-user.sh SRC PROFILE PROJECTS FIRST VSCODE_COMMIT
#
#   SRC            the claude-ide-box sources (on /mnt/c, possibly with CRLF)
#   PROFILE        image profile for all projects (e.g. office), or "base"
#   PROJECTS       name of the projects folder in $HOME (e.g. Projekty)
#   FIRST          name of a first, empty project folder inside it
#   VSCODE_COMMIT  commit of the Windows VS Code; its server is installed here
#                  with the Claude Code extension, so the panel works on the
#                  first start. "-" skips this.
#
# Safe to run again: it replaces the installed copy and keeps configuration,
# the token and the projects.
set -euo pipefail

src="${1:?usage: provision-user.sh SRC PROFILE PROJECTS FIRST VSCODE_COMMIT}"
profile="${2:?}"
projects="${3:?}"
first="${4:?}"
commit="${5:?}"

say() { printf '%s\n' "$*"; }

# 1. Copy the sources to the Linux file system and drop CR line endings: a
#    Windows checkout or ZIP tool may have converted them.
dest="$HOME/.local/src/claude-ide-box"
rm -rf "$dest.new"
mkdir -p "$dest.new"
(cd "$src" && tar cf - bin lib image proxy install.sh LICENSE NOTICE) | (cd "$dest.new" && tar xf -)
find "$dest.new" -type f -print0 | while IFS= read -r -d '' f; do
  if grep -Iq . "$f" && grep -q $'\r' "$f"; then
    sed -i 's/\r$//' "$f"
  fi
done
rm -rf "$dest"
mv "$dest.new" "$dest"
bash "$dest/install.sh" >/dev/null
say "claude-ide-box installed"

# 2. Configuration: the profile every project uses, unless already chosen.
cfg="$HOME/.config/claude-ide-box/config"
mkdir -p "${cfg%/*}"
touch "$cfg"
if [ "$profile" != base ] && ! grep -q '^PROFILE=' "$cfg"; then
  printf 'PROFILE=%s\n' "$profile" >>"$cfg"
fi

# 3. Images, networks and the proxy (the slow part: several minutes).
docker info >/dev/null 2>&1 || { echo "provision-user.sh: Docker is not running" >&2; exit 1; }
if [ "$profile" = base ]; then
  "$HOME/.local/bin/claude-ide-box" setup
else
  "$HOME/.local/bin/claude-ide-box" setup --profile "$profile"
fi

# 4. Projects folder.
mkdir -p "$HOME/$projects/$first"

# 5. VS Code server and the Claude Code extension on the WSL side (the IDE
#    runs the extension here, next to the files).
if [ "$commit" != - ]; then
  case "$commit" in
    *[!0-9a-f]*) echo "provision-user.sh: invalid VS Code commit '$commit'" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) echo "provision-user.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  server="$HOME/.vscode-server/bin/$commit"
  if [ ! -x "$server/bin/code-server" ]; then
    say "downloading the VS Code server ($commit)"
    mkdir -p "$server.tmp"
    curl -fsSL --retry 3 "https://update.code.visualstudio.com/commit:$commit/server-linux-$arch/stable" |
      tar xz -C "$server.tmp" --strip-components=1
    rm -rf "$server"
    mv "$server.tmp" "$server"
  fi
  "$server/bin/code-server" --install-extension anthropic.claude-code --force >/dev/null
  say "Claude Code extension installed in WSL"
fi

# 6. Guard the extension's bundled binary in this distribution, so a window
#    from any IDE profile that opens a folder here still lands in the box.
#    It only touches extension directories under this distribution's $HOME;
#    IDEs on the Windows side (Antigravity, other VS Code profiles opening
#    Windows folders) are not affected.
"$HOME/.local/bin/claude-ide-box" guard

say "provision-user.sh: done"
