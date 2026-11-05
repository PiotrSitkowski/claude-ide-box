# shellcheck shell=bash
# shellcheck disable=SC2034 # ERR is set for symmetry with run_wrapper/run_cli
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
  local share="$HOME/.local/share/claude-ide-box"
  assert_file_exists "$share/bin/claude-ide-box-exec"
  assert_file_exists "$share/lib/claude-ide-box/common.sh"
  assert_file_exists "$share/image/Dockerfile"
  assert_file_exists "$share/proxy/squid.conf.in"
  [ -L "$HOME/.local/bin/claude-ide-box" ] || fail "claude-ide-box link missing"
  [ -L "$HOME/.local/bin/claude-ide-box-exec" ] || fail "claude-ide-box-exec link missing"
  "$HOME/.local/bin/claude-ide-box" version >/dev/null || fail "installed claude-ide-box does not run"
}

test_install_prints_user_settings_snippet() {
  run_install
  local share
  share="$(cd -P "$HOME/.local/share/claude-ide-box" && pwd -P)"
  assert_contains "$OUT" "\"claudeCode.claudeProcessWrapper\": \"$share/bin/claude-ide-box-exec\""
  assert_contains "$OUT" "\"claudeCode.useTerminal\": false"
  assert_contains "$OUT" "USER settings"
}

test_install_is_idempotent() {
  run_install
  run_install
  assert_status 0 "$STATUS"
  [ -L "$HOME/.local/bin/claude-ide-box" ] || fail "link missing after second install"
}

test_install_does_not_touch_foreign_files() {
  mkdir -p "$HOME/.local/bin"
  echo "mine" >"$HOME/.local/bin/claude-ide-box"
  run_install
  assert_nonzero "$STATUS"
  assert_eq "mine" "$(cat "$HOME/.local/bin/claude-ide-box")"
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
  "$HOME/.local/bin/claude-ide-box" guard >/dev/null
  [ -L "$ext/claude" ] || fail "guard did not run"
  run_install --uninstall
  assert_status 0 "$STATUS"
  [ ! -L "$ext/claude" ] || fail "guard was not undone"
  assert_file_missing "$HOME/.local/bin/claude-ide-box"
  assert_file_missing "$HOME/.local/bin/claude-ide-box-exec"
  assert_file_missing "$HOME/.local/share/claude-ide-box"
}

test_uninstall_keeps_config() {
  run_install
  mkdir -p "$HOME/.config/claude-ide-box"
  echo 'MEMORY=2g' >"$HOME/.config/claude-ide-box/config"
  run_install --uninstall
  assert_file_exists "$HOME/.config/claude-ide-box/config"
}

test_install_prefix() {
  run_install --prefix "$SANDBOX/opt"
  assert_status 0 "$STATUS"
  assert_file_exists "$SANDBOX/opt/bin/claude-ide-box"
  assert_file_exists "$SANDBOX/opt/share/claude-ide-box/bin/claude-ide-box-exec"
}
