# shellcheck shell=bash
# Unit tests for bin/claude-ide-box (management CLI) against the fake docker.

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }
cfg() { cat "$HOME/.config/claude-ide-box/config" 2>/dev/null || true; }
generated_allowlist() { cat "$HOME/.local/state/claude-ide-box/proxy/allowlist" 2>/dev/null || true; }

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
    assert_eq "$(cd -P "$REPO_DIR/bin" && pwd -P)/claude-ide-box-exec" "$(readlink "$b")"
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
  assert_contains "$(cat "$HOME/.config/claude-ide-box/allowlist")" "example.org"
  assert_contains "$(generated_allowlist)" "example.org"
  assert_contains "$(generated_allowlist)" "api.anthropic.com"
  assert_contains "$(calls)" "kill --signal HUP claude-ide-box-proxy"
}

test_allow_waits_for_proxy_reconfiguration() {
  echo "true" >"$FAKE_DOCKER_DIR/state"
  run_cli allow example.org
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "logs --since"
  assert_contains "$OUT" "proxy reloaded"
}

test_allow_warns_when_proxy_does_not_come_back() {
  echo "true" >"$FAKE_DOCKER_DIR/state"
  FAKE_PROXY_STUCK=1 CLAUDE_IDE_BOX_RELOAD_TIMEOUT=1 run_cli allow example.org
  assert_status 0 "$STATUS"
  assert_contains "$ERR" "did not confirm"
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
  assert_file_missing "$HOME/.config/claude-ide-box/allowlist"
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
  f="$(ls "$HOME/.config/claude-ide-box/projects/"*.conf)"
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
  assert_contains "$c" "-t claude-ide-box/base:latest"
  assert_contains "$c" "-t claude-ide-box/proxy:latest"
  assert_contains "$c" "network create"
  assert_contains "$c" "--internal"
  assert_contains "$c" "com.docker.network.bridge.inhibit_ipv4=true"
  assert_contains "$c" "--subnet 172.30.99.0/24"
  assert_contains "$c" "network connect --ip 172.30.99.2 claude-ide-box-internal claude-ide-box-proxy"
  assert_contains "$c" "--name claude-ide-box-proxy"
  assert_not_contains "$c" "docker.sock"
  assert_contains "$(generated_allowlist)" "platform.claude.com"
}

test_setup_passes_uid_gid_and_version() {
  run_cli setup
  local c
  c="$(calls)"
  assert_contains "$c" "USER_UID=$(id -u | sed 's/^0$/1000/') "
  assert_contains "$c" "USER_GID=$(id -g | sed 's/^0$/1000/') "
  assert_contains "$c" "CLAUDE_CODE_VERSION=2.1.318"
}

test_setup_profile_builds_on_base() {
  run_cli setup --profile php
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "-t claude-ide-box/env:php "
  assert_contains "$(calls)" "BASE_IMAGE=claude-ide-box/base:latest"
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
  assert_contains "$(calls)" "rm -f claude-ide-box-my-project-"
}

test_down_and_rm() {
  run_cli up
  run_cli down
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "stop"
  run_cli rm
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "rm -f claude-ide-box-my-project-"
  assert_not_contains "$(calls)" "volume rm"
  run_cli rm --volume
  assert_contains "$(calls)" "volume rm claude-ide-box-my-project-"
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
  assert_contains "$OUT" "claude-ide-box-my-project-"
  assert_contains "$OUT" "$PROJECT"
}

test_logs_show_wrapper_log_and_denied_requests() {
  run_wrapper --version
  run_cli logs
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "claude-ide-box-exec"
  assert_contains "$OUT" "TCP_DENIED/403"
  assert_not_contains "$OUT" "TCP_TUNNEL/200"
}

test_login_token_stdin() {
  set +e
  OUT="$(cd "$PROJECT" && printf 'sk-ant-oat01-abc\n' | "$CLI" login --token-stdin 2>"$SANDBOX/stderr")"
  STATUS=$?
  set -e
  assert_status 0 "$STATUS"
  local f="$HOME/.config/claude-ide-box/token"
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
  assert_file_missing "$HOME/.config/claude-ide-box/token"
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

# Write an IDE user settings.json where doctor looks for it on this OS.
ide_settings() {
  local app="$1" content="$2" base="$HOME/.config"
  if [ "$(uname -s)" = Darwin ]; then
    base="$HOME/Library/Application Support"
  fi
  mkdir -p "$base/$app/User"
  printf '%s\n' "$content" >"$base/$app/User/settings.json"
}

wrapper_real() {
  printf '%s/claude-ide-box-exec\n' "$(cd -P "$REPO_DIR/bin" && pwd -P)"
}

healthy_host() {
  fake_ps "  1 /sbin/init
  200 /usr/bin/docker exec -i -w /p claude-ide-box-p-1234 claude --verbose"
  mkdir -p "$HOME/.config/claude-ide-box"
  printf 'sk-ant-oat01-x\n' >"$HOME/.config/claude-ide-box/token"
  chmod 600 "$HOME/.config/claude-ide-box/token"
  echo "true" >"$FAKE_DOCKER_DIR/state"
  make_extensions
  run_cli guard
  rm -f "$SANDBOX/bin/claude"
}

test_doctor_healthy() {
  healthy_host
  ide_settings Code "{
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
  ide_settings Cursor "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\", \"claudeCode.useTerminal\": true }"
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "useTerminal"
}

test_doctor_fails_when_wrapper_not_set() {
  healthy_host
  ide_settings Antigravity '{ "editor.fontSize": 12 }'
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "claudeProcessWrapper"
}

test_doctor_reads_legacy_key() {
  healthy_host
  ide_settings Code "{ \"claude-code.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  run_cli doctor
  assert_status 0 "$STATUS"
}

test_doctor_ignores_commented_out_setting() {
  healthy_host
  ide_settings Code "{
  // \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\",
}"
  run_cli doctor
  assert_nonzero "$STATUS"
}

test_doctor_fails_on_unguarded_binary() {
  healthy_host
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  mkdir -p "$HOME/.vscode/extensions/anthropic.claude-code-2.1.400-linux-x64/resources/native-binary"
  : >"$HOME/.vscode/extensions/anthropic.claude-code-2.1.400-linux-x64/resources/native-binary/claude"
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "2.1.400"
}

test_doctor_fails_on_host_claude_process() {
  healthy_host
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
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
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
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
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  FAKE_NETWORK_INFO="false map[] 172.30.99.0/24" run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "internal"
}

test_doctor_warns_on_git_auto_repository_detection() {
  healthy_host
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\" }"
  run_cli doctor
  assert_contains "$OUT" "git.autoRepositoryDetection"
  ide_settings Code "{ \"claudeCode.claudeProcessWrapper\": \"$(wrapper_real)\", \"git.autoRepositoryDetection\": false }"
  run_cli doctor
  assert_not_contains "$OUT" "git.autoRepositoryDetection"
}

test_concurrent_guard_keeps_original_binary() {
  make_extensions
  local _
  for _ in 1 2 3 4 5 6; do
    (cd "$PROJECT" && "$CLI" guard >/dev/null 2>&1) &
  done
  wait
  local b
  for b in $(all_bundled); do
    [ -L "$b" ] || fail "$b is not a symlink"
    [ ! -L "$b.orig" ] || fail "$b.orig was overwritten by the symlink"
    assert_eq "#!/bin/sh" "$(head -1 "$b.orig")"
  done
}

# --- modules: composable profiles, user profiles and presets -------------------

user_profile() {
  mkdir -p "$HOME/.config/claude-ide-box/profiles/$1"
  # shellcheck disable=SC2016 # a literal ${BASE_IMAGE} for the Dockerfile
  printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' >"$HOME/.config/claude-ide-box/profiles/$1/Dockerfile"
}

project_conf() {
  local name
  name="$(cd "$PROJECT" && "$CLI" status | awk '/^container:/{print $2}')"
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf '%s\n' "$1" >"$HOME/.config/claude-ide-box/projects/$name.conf"
}

test_setup_builds_a_profile_chain() {
  user_profile mytool
  run_cli setup --profile php,mytool
  assert_status 0 "$STATUS"
  local c
  c="$(calls)"
  assert_contains "$c" "-t claude-ide-box/env:mytool "
  assert_contains "$c" "-t claude-ide-box/env:mytool.php "
  assert_contains "$c" "BASE_IMAGE=claude-ide-box/env:mytool "
  assert_contains "$c" "$HOME/.config/claude-ide-box/profiles/mytool"
}

test_setup_builds_the_current_projects_profiles() {
  user_profile mytool
  project_conf 'PROFILE="mytool php"'
  run_cli setup
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "-t claude-ide-box/env:mytool.php "
}

test_wrapper_uses_the_combined_image() {
  user_profile mytool
  project_conf 'PROFILE="php mytool"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(run_args | tr '\n' ' ')" "claude-ide-box/env:mytool.php sleep infinity"
}

test_unknown_profile_fails_closed() {
  project_conf 'PROFILE="nosuchthing"'
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "nosuchthing"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_profile_command_sets_and_shows_the_project_profiles() {
  user_profile mytool
  run_cli profile php mytool
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "mytool php"
  assert_contains "$OUT" "setup"
  run_cli profile
  assert_contains "$OUT" "mytool php"
  run_cli profile nosuchthing
  assert_nonzero "$STATUS"
  run_cli profile base
  assert_status 0 "$STATUS"
  run_cli profile
  assert_contains "$OUT" "base"
}

test_profiles_command_lists_builtin_and_user_profiles() {
  user_profile mytool
  run_cli profiles
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "php"
  assert_contains "$OUT" "mytool"
  assert_contains "$OUT" "user"
}

test_user_preset_can_be_enabled() {
  mkdir -p "$HOME/.config/claude-ide-box/presets"
  printf '# corporate mirror\nnexus.example.com\n' >"$HOME/.config/claude-ide-box/presets/corp.txt"
  run_cli preset corp on
  assert_status 0 "$STATUS"
  assert_contains "$(generated_allowlist)" "nexus.example.com"
}

test_presets_command_lists_state() {
  run_cli preset php on
  run_cli presets
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "php"
  assert_contains "$OUT" "on"
  assert_contains "$OUT" "github"
  assert_contains "$OUT" "prestashop"
}
