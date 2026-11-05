# shellcheck shell=bash
# Unit tests for bin/claude-box (management CLI) against the fake docker.

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }
cfg() { cat "$HOME/.config/claude-box/config" 2>/dev/null || true; }
generated_allowlist() { cat "$HOME/.local/state/claude-box/proxy/allowlist" 2>/dev/null || true; }

# Fake extension installs in both bundled-binary layouts, several versions.
make_extensions() {
  local base
  for base in "$HOME/.vscode/extensions/anthropic.claude-code-2.1.300-linux-x64" \
    "$HOME/.antigravity/extensions/anthropic.claude-code-2.1.318-darwin-x64"; do
    mkdir -p "$base/resources/native-binary"
    printf '#!/bin/sh\necho real-claude\n' >"$base/resources/native-binary/claude"
    chmod 755 "$base/resources/native-binary/claude"
  done
  base="$HOME/.cursor/extensions/anthropic.claude-code-2.1.318-linux-arm64/resources/native-binaries/linux-arm64-musl"
  mkdir -p "$base"
  printf '#!/bin/sh\necho real-claude\n' >"$base/claude"
  chmod 755 "$base/claude"
}

all_bundled() {
  find "$HOME" -path '*anthropic.claude-code-*' -name claude
}

test_help() {
  run_cli help
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "setup"
  assert_contains "$OUT" "doctor"
  run_cli
  assert_status 0 "$STATUS"
}

test_unknown_command() {
  run_cli frobnicate
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "unknown command"
}

test_guard_replaces_all_versions_and_layouts() {
  make_extensions
  run_cli guard
  assert_status 0 "$STATUS"
  local b n=0
  for b in $(all_bundled); do
    n=$((n + 1))
    [ -L "$b" ] || fail "$b is not a symlink"
    assert_eq "$(cd -P "$REPO_DIR/bin" && pwd -P)/claude-box-exec" "$(readlink "$b")"
    assert_file_exists "$b.orig"
    [ ! -x "$b.orig" ] || fail "$b.orig must not be executable"
  done
  assert_eq 3 "$n"
}

test_guard_is_idempotent() {
  make_extensions
  run_cli guard
  run_cli guard
  assert_status 0 "$STATUS"
  assert_eq "#!/bin/sh" "$(head -1 "$HOME/.vscode/extensions/anthropic.claude-code-2.1.300-linux-x64/resources/native-binary/claude.orig")"
}

test_guard_undo_restores_originals() {
  make_extensions
  run_cli guard
  run_cli guard --undo
  assert_status 0 "$STATUS"
  local b
  for b in $(all_bundled); do
    [ ! -L "$b" ] || fail "$b is still a symlink"
    [ -x "$b" ] || fail "$b is not executable after undo"
    assert_file_missing "$b.orig"
  done
}

test_allow_adds_domain_and_reloads_proxy() {
  echo "true" >"$FAKE_DOCKER_DIR/state"
  run_cli allow Example.ORG
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$HOME/.config/claude-box/allowlist")" "example.org"
  assert_contains "$(generated_allowlist)" "example.org"
  assert_contains "$(generated_allowlist)" "api.anthropic.com"
  assert_contains "$(calls)" "exec claude-box-proxy squid -k reconfigure"
}

test_allow_without_running_proxy_says_so() {
  run_cli allow example.org
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "not running"
}

test_allow_rejects_invalid_domains() {
  local d
  for d in "http://x.com" "a b.com" "*" "10.0.0.1" "x" "-bad.com" "a..com"; do
    run_cli allow "$d"
    assert_nonzero "$STATUS" "allow '$d' must fail"
  done
  assert_file_missing "$HOME/.config/claude-box/allowlist"
}

test_allow_accepts_subdomain_wildcard() {
  run_cli allow .githubusercontent.com
  assert_status 0 "$STATUS"
  assert_contains "$(generated_allowlist)" ".githubusercontent.com"
}

test_preset_php_on_off() {
  run_cli preset php on
  assert_status 0 "$STATUS"
  assert_contains "$(cfg)" 'PROXY_PRESETS="php"'
  assert_contains "$(generated_allowlist)" "repo.packagist.org"
  run_cli preset php off
  assert_status 0 "$STATUS"
  assert_not_contains "$(generated_allowlist)" "packagist"
}

test_preset_github_warns_about_exfiltration() {
  run_cli preset github on
  assert_status 0 "$STATUS"
  assert_contains "$ERR" "exfiltration"
  assert_contains "$(generated_allowlist)" "codeload.github.com"
}

test_preset_unknown() {
  run_cli preset nope on
  assert_nonzero "$STATUS"
}

test_preset_prestashop_is_per_project() {
  run_cli preset prestashop on
  assert_status 0 "$STATUS"
  local f
  f="$(ls "$HOME/.config/claude-box/projects/"*.conf)"
  assert_contains "$(cat "$f")" 'MASK_PRESETS="prestashop"'
}

test_generated_allowlist_has_no_comments_or_duplicates() {
  run_cli allow api.anthropic.com
  local dups
  dups="$(generated_allowlist | sort | uniq -d)"
  assert_eq "" "$dups"
  assert_not_contains "$(generated_allowlist)" "#"
}

test_setup_creates_internal_network_and_proxy() {
  FAKE_NO_NETWORK=1 run_cli setup
  assert_status 0 "$STATUS"
  local c
  c="$(calls)"
  assert_contains "$c" "build"
  assert_contains "$c" "-t claude-box/base:latest"
  assert_contains "$c" "-t claude-box/proxy:latest"
  assert_contains "$c" "network create"
  assert_contains "$c" "--internal"
  assert_contains "$c" "com.docker.network.bridge.inhibit_ipv4=true"
  assert_contains "$c" "--subnet 172.30.99.0/24"
  assert_contains "$c" "network connect --ip 172.30.99.2 claude-box-internal claude-box-proxy"
  assert_contains "$c" "--name claude-box-proxy"
  assert_not_contains "$c" "docker.sock"
  assert_contains "$(generated_allowlist)" "platform.claude.com"
}

test_setup_passes_uid_gid_and_version() {
  run_cli setup
  local c
  c="$(calls)"
  assert_contains "$c" "USER_UID="
  assert_contains "$c" "USER_GID="
  assert_contains "$c" "CLAUDE_CODE_VERSION=2.1.318"
}

test_setup_profile_builds_on_base() {
  run_cli setup --profile php
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "-t claude-box/php:latest"
  assert_contains "$(calls)" "BASE_IMAGE=claude-box/base:latest"
}

test_setup_fails_when_build_fails() {
  FAKE_BUILD_STATUS=1 run_cli setup
  assert_nonzero "$STATUS"
}

test_setup_fails_closed_without_daemon() {
  FAKE_DOCKER_DOWN=1 run_cli setup
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "Docker"
}

test_up_creates_container_without_running_claude() {
  run_cli up
  assert_status 0 "$STATUS"
  assert_file_exists "$FAKE_DOCKER_DIR/run.args"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.args"
}

test_up_recreate() {
  run_cli up
  run_cli up --recreate
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "rm -f claude-box-my-project-"
}

test_down_and_rm() {
  run_cli up
  run_cli down
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "stop"
  run_cli rm
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "rm -f claude-box-my-project-"
  assert_not_contains "$(calls)" "volume rm"
  run_cli rm --volume
  assert_contains "$(calls)" "volume rm claude-box-my-project-"
}

test_shell_runs_bash_in_project_container() {
  run_cli shell
  assert_status 0 "$STATUS"
  assert_eq "bash" "$(exec_args)"
  assert_eq "$PROJECT" "$(cat "$FAKE_DOCKER_DIR/exec.workdir")"
}

test_status_names_container() {
  run_cli status
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "claude-box-my-project-"
  assert_contains "$OUT" "$PROJECT"
}

test_logs_show_wrapper_log_and_denied_requests() {
  run_wrapper --version
  run_cli logs
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "claude-box-exec"
  assert_contains "$OUT" "TCP_DENIED/403"
  assert_not_contains "$OUT" "TCP_TUNNEL/200"
}

test_login_token_stdin() {
  set +e
  OUT="$(cd "$PROJECT" && printf 'sk-ant-oat01-abc\n' | "$CLI" login --token-stdin 2>"$SANDBOX/stderr")"
  STATUS=$?
  set -e
  assert_status 0 "$STATUS"
  local f="$HOME/.config/claude-box/token"
  assert_eq "sk-ant-oat01-abc" "$(cat "$f")"
  # shellcheck disable=SC2012 # ls is the portable way to read a mode string
  assert_eq "-rw-------" "$(ls -l "$f" | cut -c1-10)"
  assert_not_contains "$OUT" "sk-ant-oat01-abc"
}

test_login_rejects_garbage_token() {
  set +e
  (cd "$PROJECT" && printf 'not a token\n' | "$CLI" login --token-stdin >/dev/null 2>&1)
  STATUS=$?
  set -e
  assert_nonzero "$STATUS"
  assert_file_missing "$HOME/.config/claude-box/token"
}

# --- doctor -----------------------------------------------------------------

fake_ps() {
  cat >"$SANDBOX/bin/ps" <<EOS
#!/bin/sh
cat <<'EOP'
$1
EOP
EOS
  chmod +x "$SANDBOX/bin/ps"
}

linux_settings() {
  local app="$1" content="$2"
  mkdir -p "$HOME/.config/$app/User"
  printf '%s\n' "$content" >"$HOME/.config/$app/User/settings.json"
}

wrapper_real() {
  printf '%s/claude-box-exec\n' "$(cd -P "$REPO_DIR/bin" && pwd -P)"
}

healthy_host() {
  fake_ps "  1 /sbin/init
  200 /usr/bin/docker exec -i -w /p claude-box-p-1234 claude --verbose"
  mkdir -p "$HOME/.config/claude-box"
  printf 'sk-ant-oat01-x\n' >"$HOME/.config/claude-box/token"
  chmod 600 "$HOME/.config/claude-box/token"
  echo "true" >"$FAKE_DOCKER_DIR/state"
  make_extensions
  run_cli guard
  rm -f "$SANDBOX/bin/claude"
}

test_doctor_healthy() {
  healthy_host
  linux_settings Code "{
  // comment
  \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\",
  \"claudeCode.useTerminal\": false,
}"
  run_cli doctor
  assert_status 0 "$STATUS"
  assert_not_contains "$OUT" "FAIL"
}

test_doctor_fails_on_use_terminal() {
  healthy_host
  linux_settings Cursor "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\", \"claudeCode.useTerminal\": true }"
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "useTerminal"
}

test_doctor_fails_when_wrapper_not_set() {
  healthy_host
  linux_settings Antigravity '{ "editor.fontSize": 12 }'
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "claudeProcessWrapper"
}

test_doctor_reads_legacy_key() {
  healthy_host
  linux_settings Code "{ \"claude-code.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  run_cli doctor
  assert_status 0 "$STATUS"
}

test_doctor_ignores_commented_out_setting() {
  healthy_host
  linux_settings Code "{
  // \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\",
}"
  run_cli doctor
  assert_nonzero "$STATUS"
}

test_doctor_fails_on_unguarded_binary() {
  healthy_host
  linux_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  mkdir -p "$HOME/.vscode/extensions/anthropic.claude-code-2.1.400-linux-x64/resources/native-binary"
  : >"$HOME/.vscode/extensions/anthropic.claude-code-2.1.400-linux-x64/resources/native-binary/claude"
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "2.1.400"
}

test_doctor_fails_on_host_claude_process() {
  healthy_host
  linux_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  fake_ps "  1 /sbin/init
  4242 /home/u/.vscode/extensions/anthropic.claude-code-2.1.318-linux-x64/resources/native-binary/claude.orig --verbose
  4243 /usr/local/bin/claude --resume x"
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "4242"
  assert_contains "$OUT" "4243"
}

test_doctor_warns_on_claude_in_path() {
  healthy_host
  linux_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  printf '#!/bin/sh\n' >"$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/claude"
  run_cli doctor
  assert_contains "$OUT" "warn"
  assert_contains "$OUT" "$SANDBOX/bin/claude"
}

test_doctor_fails_without_daemon() {
  healthy_host
  FAKE_DOCKER_DOWN=1 run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "FAIL"
}

test_doctor_fails_when_network_not_internal() {
  healthy_host
  linux_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  FAKE_NETWORK_INFO="false map[] 172.30.99.0/24" run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "internal"
}
