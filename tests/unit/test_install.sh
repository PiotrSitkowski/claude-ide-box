# shellcheck shell=bash
# Unit tests for install.sh.

run_install() {
  set +e
  OUT="$(cd "$SANDBOX" && "$REPO_DIR/install.sh" "$@" 2>"$SANDBOX/stderr" </dev/null)"
  STATUS=$?
  set -e
  ERR="$(cat "$SANDBOX/stderr")"
}

test_install_copies_and_links() {
  run_install
  assert_status 0 "$STATUS"
  local share="$HOME/.local/share/claude-box"
  assert_file_exists "$share/bin/claude-box-exec"
  assert_file_exists "$share/lib/claude-box/common.sh"
  assert_file_exists "$share/image/Dockerfile"
  assert_file_exists "$share/proxy/squid.conf.in"
  [ -L "$HOME/.local/bin/claude-box" ] || fail "claude-box link missing"
  [ -L "$HOME/.local/bin/claude-box-exec" ] || fail "claude-box-exec link missing"
  "$HOME/.local/bin/claude-box" version >/dev/null || fail "installed claude-box does not run"
}

test_install_prints_user_settings_snippet() {
  run_install
  local share
  share="$(cd -P "$HOME/.local/share/claude-box" && pwd -P)"
  assert_contains "$OUT" "\"claudeCode.claudeProcessWrapper\": \"$share/bin/claude-box-exec\""
  assert_contains "$OUT" "\"claudeCode.useTerminal\": false"
  assert_contains "$OUT" "USER settings"
}

test_install_is_idempotent() {
  run_install
  run_install
  assert_status 0 "$STATUS"
  [ -L "$HOME/.local/bin/claude-box" ] || fail "link missing after second install"
}

test_install_does_not_touch_foreign_files() {
  mkdir -p "$HOME/.local/bin"
  echo "mine" >"$HOME/.local/bin/claude-box"
  run_install
  assert_nonzero "$STATUS"
  assert_eq "mine" "$(cat "$HOME/.local/bin/claude-box")"
}

test_install_uses_no_sudo() {
  assert_not_contains "$(cat "$REPO_DIR/install.sh")" "sudo "
}

test_uninstall_removes_and_undoes_guard() {
  run_install
  local ext="$HOME/.vscode/extensions/anthropic.claude-code-2.1.318-linux-x64/resources/native-binary"
  mkdir -p "$ext"
  printf '#!/bin/sh\n' >"$ext/claude"
  chmod 755 "$ext/claude"
  "$HOME/.local/bin/claude-box" guard >/dev/null
  [ -L "$ext/claude" ] || fail "guard did not run"
  run_install --uninstall
  assert_status 0 "$STATUS"
  [ ! -L "$ext/claude" ] || fail "guard was not undone"
  assert_file_missing "$HOME/.local/bin/claude-box"
  assert_file_missing "$HOME/.local/bin/claude-box-exec"
  assert_file_missing "$HOME/.local/share/claude-box"
}

test_uninstall_keeps_config() {
  run_install
  mkdir -p "$HOME/.config/claude-box"
  echo 'MEMORY=2g' >"$HOME/.config/claude-box/config"
  run_install --uninstall
  assert_file_exists "$HOME/.config/claude-box/config"
}

test_install_prefix() {
  run_install --prefix "$SANDBOX/opt"
  assert_status 0 "$STATUS"
  assert_file_exists "$SANDBOX/opt/bin/claude-box"
  assert_file_exists "$SANDBOX/opt/share/claude-box/bin/claude-box-exec"
}
