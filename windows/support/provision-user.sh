#!/usr/bin/env bash
# Run by windows/support/install.ps1 as the default user inside the
# ClaudeIDEBox WSL distribution. Safe to run again: it replaces the installed
# copy, applies the current selection and keeps the token and the projects.
#
#   provision-user.sh --src DIR --profile "docs ocr python" --ocr "eng pol"
#                     --projects NAME --first NAME
#                     [--preset-on NAME]... [--preset-off NAME]...
#                     [--vscode-commit SHA --vscode-profile ID]
#
#   --src             the claude-ide-box files (on /mnt/c, possibly with CRLF)
#   --profile         image profiles for all projects ("base" for none)
#   --ocr             Tesseract languages for the ocr profile
#   --projects/first  projects folder in $HOME and a first, empty project in it
#   --preset-on/off   proxy presets the installer manages (one per language)
#   --vscode-commit   commit of the Windows VS Code; its server is installed here
#                     with the Claude Code extension
#   --vscode-profile  the VS Code profile's id; on the WSL side every profile
#                     has its own extension list, so Claude Code is added to it
set -euo pipefail

src="" profile="base" ocr="eng" projects="" first="" commit="" vsprofile=""
presets_on="" presets_off=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) src="$2" ;;
    --profile) profile="$2" ;;
    --ocr) ocr="$2" ;;
    --projects) projects="$2" ;;
    --first) first="$2" ;;
    --preset-on) presets_on="$presets_on $2" ;;
    --preset-off) presets_off="$presets_off $2" ;;
    --vscode-commit) commit="$2" ;;
    --vscode-profile) vsprofile="$2" ;;
    *) echo "provision-user.sh: unknown option $1" >&2; exit 1 ;;
  esac
  shift 2
done
if [ -z "$src" ] || [ -z "$projects" ] || [ -z "$first" ]; then
  echo "provision-user.sh: --src, --projects and --first are required" >&2
  exit 1
fi

say() { printf '%s\n' "$*"; }
cib="$HOME/.local/bin/claude-ide-box"

# 1. Copy the sources to the Linux file system and drop CR line endings: a
#    Windows checkout or ZIP tool may have converted them.
dest="$HOME/.local/src/claude-ide-box"
rm -rf "$dest.new"
mkdir -p "$dest.new"
(cd "$src" && tar cf - bin lib image proxy install.sh LICENSE NOTICE 2>/dev/null) | (cd "$dest.new" && tar xf -)
find "$dest.new" -type f -print0 | while IFS= read -r -d '' f; do
  if grep -Iq . "$f" && grep -q $'\r' "$f"; then
    sed -i 's/\r$//' "$f"
  fi
done
rm -rf "$dest"
mv "$dest.new" "$dest"
bash "$dest/install.sh" >/dev/null
say "claude-ide-box installed"

# 2. Configuration: the installer owns PROFILE and OCR_LANGUAGES (what the
#    person chose on the choice screen); everything else is kept.
cfg="$HOME/.config/claude-ide-box/config"
mkdir -p "${cfg%/*}"
touch "$cfg"
set_cfg() {
  local key="$1" value="$2"
  grep -v "^$key=" "$cfg" >"$cfg.tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
}
set_cfg PROFILE "$profile"
set_cfg OCR_LANGUAGES "$ocr"
say "profile: $profile; OCR languages: $ocr"

# 3. Images, networks and the proxy (the slow part: several minutes).
docker info >/dev/null 2>&1 || { echo "provision-user.sh: Docker is not running" >&2; exit 1; }
"$cib" setup

# 4. Proxy presets for the chosen programming languages (package registries).
for p in $presets_on; do "$cib" preset "$p" on; done
for p in $presets_off; do "$cib" preset "$p" off; done

# 5. Projects folder.
mkdir -p "$HOME/$projects/$first"

# 6. VS Code server and the Claude Code extension on the WSL side (the IDE
#    runs the extension here, next to the files).
if [ -n "$commit" ] && [ "$commit" != - ]; then
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

  if [ -n "$vsprofile" ]; then
    case "$vsprofile" in
      *[!A-Za-z0-9_-]*) echo "provision-user.sh: invalid VS Code profile id '$vsprofile'" >&2; exit 1 ;;
    esac
    # Add the extension's entry from the default list to the profile's list,
    # keeping whatever else the profile has.
    python3 - "$HOME/.vscode-server/extensions/extensions.json" \
      "$HOME/.vscode-server/data/User/profiles/$vsprofile/extensions.json" <<'PY'
import json, os, sys
default, target = sys.argv[1], sys.argv[2]
with open(default) as f:
    entries = [e for e in json.load(f) if e.get("identifier", {}).get("id", "").lower() == "anthropic.claude-code"]
if not entries:
    sys.exit("anthropic.claude-code is not in " + default)
current = []
if os.path.exists(target):
    with open(target) as f:
        current = json.load(f)
current = [e for e in current if e.get("identifier", {}).get("id", "").lower() != "anthropic.claude-code"] + entries
os.makedirs(os.path.dirname(target), exist_ok=True)
with open(target + ".tmp", "w") as f:
    json.dump(current, f)
os.replace(target + ".tmp", target)
PY
    say "Claude Code enabled in the VS Code profile $vsprofile on the WSL side"
  fi
fi

# 7. Guard the extension's bundled binary in this distribution, so a window
#    from any IDE profile that opens a folder here still lands in the box.
#    It only touches extension directories under this distribution's $HOME;
#    IDEs on the Windows side (Antigravity, other VS Code profiles opening
#    Windows folders) are not affected.
"$cib" guard

say "provision-user.sh: done"
