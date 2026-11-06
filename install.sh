#!/usr/bin/env bash
# Install claude-ide-box for the current user. No root, no system files.
#
#   ./install.sh                  install to ~/.local (share/claude-ide-box + bin links)
#   ./install.sh --prefix DIR     install to DIR/share/claude-ide-box and DIR/bin
#   ./install.sh --uninstall      undo `claude-ide-box guard`, remove the files
#
# Re-running is safe: it replaces the installed copy in place.
set -euo pipefail

prefix="$HOME/.local"
action=install
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 1; }; prefix="$2"; shift 2 ;;
    --prefix=*) prefix="${1#--prefix=}"; shift ;;
    --uninstall) action=uninstall; shift ;;
    -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 1 ;;
  esac
done
case "$prefix" in
  /*) ;;
  *) prefix="$(pwd -P)/$prefix" ;;
esac

# No dirname: a path starting with "-" would be read as an option.
case "$0" in */*) src_dir="${0%/*}" ;; *) src_dir=. ;; esac
src="$(cd -P "${src_dir:-/}" && pwd -P)"
share="$prefix/share/claude-ide-box"
bindir="$prefix/bin"
commands="claude-ide-box claude-ide-box-exec"

# A link we own points into $share; anything else is left alone.
our_link() {
  [ -L "$1" ] && case "$(readlink "$1")" in "$share"/*) true ;; *) false ;; esac
}

do_install() {
  local c
  for c in $commands; do
    if { [ -e "$bindir/$c" ] || [ -L "$bindir/$c" ]; } && ! our_link "$bindir/$c"; then
      echo "install.sh: $bindir/$c exists and was not installed by claude-ide-box; remove it first" >&2
      exit 1
    fi
  done

  mkdir -p "$prefix/share" "$bindir"
  rm -rf "$share.new"
  mkdir -p "$share.new"
  cp -R "$src/bin" "$src/lib" "$src/image" "$src/proxy" "$share.new/"
  cp "$src/LICENSE" "$src/NOTICE" "$share.new/" 2>/dev/null || true
  chmod 755 "$share.new/bin/"* "$share.new/proxy/entrypoint.sh" "$share.new/image/create-user.sh"
  # Swap directories; a wrapper that is running keeps reading the old inode.
  rm -rf "$share.old"
  if [ -d "$share" ]; then
    mv "$share" "$share.old"
  fi
  mv "$share.new" "$share"
  rm -rf "$share.old"

  for c in $commands; do
    ln -sfn "$share/bin/$c" "$bindir/$c"
  done

  local wrapper
  wrapper="$(cd -P "$share/bin" && pwd -P)/claude-ide-box-exec"
  cat <<EOF
claude-ide-box installed:
  $bindir/claude-ide-box
  $bindir/claude-ide-box-exec  ->  $wrapper

Add this to the USER settings.json of each IDE (Antigravity, VS Code, Cursor).
Never put it in workspace settings: those live in the project, which Claude can edit.
The last line stops the IDE from running git in repositories Claude creates in
the project (git hooks and core.fsmonitor would run on the host).

    "claudeCode.claudeProcessWrapper": "$wrapper",
    "claudeCode.useTerminal": false,
    "git.autoRepositoryDetection": false

Then:
    claude-ide-box setup     # build images, networks, proxy
    claude-ide-box login     # subscription token (or export ANTHROPIC_API_KEY)
    claude-ide-box guard     # route the extension's bundled binary to the wrapper
    claude-ide-box doctor
EOF
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) printf '\nNote: %s is not on your PATH.\n' "$bindir" ;;
  esac
}

do_uninstall() {
  local c
  if [ -x "$share/bin/claude-ide-box" ]; then
    "$share/bin/claude-ide-box" guard --undo || echo "install.sh: 'claude-ide-box guard --undo' failed; check your extension directories" >&2
  fi
  for c in $commands; do
    if our_link "$bindir/$c"; then
      rm -f "$bindir/$c"
    fi
  done
  rm -rf "$share"
  cat <<EOF
claude-ide-box uninstalled. Left in place (remove by hand if you want them gone):
  ${XDG_CONFIG_HOME:-$HOME/.config}/claude-ide-box       config and token
  ${XDG_STATE_HOME:-$HOME/.local/state}/claude-ide-box  logs
  Docker resources:  docker ps -a --filter label=io.claude-ide-box.managed=1
                     docker volume ls --filter name=claude-ide-box-
                     docker network rm claude-ide-box-internal claude-ide-box-egress
Remove "claudeCode.claudeProcessWrapper" from your IDE user settings.
EOF
}

"do_$action"
