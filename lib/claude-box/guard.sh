# shellcheck shell=bash
# guard: replace the Claude Code binary bundled with the IDE extension by a
# symlink to claude-box-exec, so the extension reaches the container even if it
# ignores claudeCode.claudeProcessWrapper (as 2.1.131 did) or runs the binary
# directly. The original is kept as "<binary>.orig" with its execute bits
# removed; nothing in claude-box ever executes it.

# Extension directories of every IDE claude-box knows about (see
# docs/PLATFORM-NOTES.md). EXTENSION_DIRS in the config adds more.
cb_extension_roots() {
  local d
  for d in .antigravity .antigravity-ide .vscode .vscode-insiders .cursor \
    .vscode-server .vscode-server-insiders .cursor-server .antigravity-server; do
    printf '%s\n' "$HOME/$d/extensions"
  done
  for d in ${CFG_EXTENSION_DIRS:-}; do
    printf '%s\n' "$d"
  done
}

# Print every bundled binary (both layouts) of every installed version.
#   resources/native-binaries/<platform>-<arch>[-musl]/claude
#   resources/native-binary/claude
cb_bundled_binaries() {
  local root ext b
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    for ext in "$root"/anthropic.claude-code-*; do
      [ -d "$ext" ] || continue
      for b in "$ext"/resources/native-binary/claude "$ext"/resources/native-binaries/*/claude; do
        if [ -e "$b" ] || [ -L "$b" ]; then
          printf '%s\n' "$b"
        fi
      done
    done
  done <<EOF
$(cb_extension_roots)
EOF
}

# cb_guard_state BINARY WRAPPER -> prints guarded | unguarded | foreign
cb_guard_state() {
  local b="$1" wrapper="$2" target
  if [ -L "$b" ]; then
    target="$(readlink "$b")"
    if [ "$target" = "$wrapper" ]; then
      echo guarded
    else
      echo foreign
    fi
  else
    echo unguarded
  fi
}

# True when every bundled binary already points at WRAPPER.
cb_guard_all_done() {
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ -L "$b" ] && [ "$(readlink "$b")" = "$1" ] || return 1
  done <<EOF
$(cb_bundled_binaries)
EOF
}

# cb_guard_apply WRAPPER [quiet] - serialised with a lock: two wrappers
# starting at once must not both move the same binary to .orig.
cb_guard_apply() {
  # Fast path for every wrapper start: nothing to do, no lock needed.
  if [ -n "${2:-}" ] && cb_guard_all_done "$1"; then
    return 0
  fi
  cb_lock guard
  cb_guard_apply_locked "$@"
  cb_unlock
}

cb_guard_apply_locked() {
  local wrapper="$1" quiet="${2:-}" b state count=0
  [ -x "$wrapper" ] || { echo "guard: wrapper $wrapper is not executable" >&2; return 1; }
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    state="$(cb_guard_state "$b" "$wrapper")"
    case "$state" in
      guarded)
        [ -n "$quiet" ] || printf 'ok        %s\n' "$b"
        continue
        ;;
      foreign)
        # A symlink to something else, e.g. an older claude-box location.
        ln -sfn "$wrapper" "$b"
        ;;
      unguarded)
        mv -f "$b" "$b.orig"
        # Never chmod through a symlink: that would hit the wrapper itself.
        if [ ! -L "$b.orig" ]; then
          chmod a-x "$b.orig" 2>/dev/null || true
        fi
        ln -s "$wrapper" "$b"
        ;;
    esac
    count=$((count + 1))
    printf 'guarded   %s\n' "$b"
    cb_log "guard: $b -> $wrapper"
  done <<EOF
$(cb_bundled_binaries)
EOF
  if [ -z "$quiet" ] && [ "$count" -eq 0 ]; then
    printf 'nothing to do\n'
  fi
}

# cb_guard_undo WRAPPER
cb_guard_undo() {
  cb_lock guard
  cb_guard_undo_locked "$@"
  cb_unlock
}

cb_guard_undo_locked() {
  local wrapper="$1" b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ "$(cb_guard_state "$b" "$wrapper")" = guarded ]; then
      if [ -f "$b.orig" ] && [ ! -L "$b.orig" ]; then
        rm -f "$b"
        mv "$b.orig" "$b"
        chmod 755 "$b"
        printf 'restored  %s\n' "$b"
      else
        printf 'skipped   %s (no .orig copy; reinstall the extension)\n' "$b" >&2
      fi
    fi
  done <<EOF
$(cb_bundled_binaries)
EOF
}
