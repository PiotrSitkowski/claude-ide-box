# shellcheck shell=bash
# Unit tests for bin/claude-box-exec against the fake docker.

STREAM_ARGS="--output-format stream-json --verbose --input-format stream-json"

test_no_leading_path() {
  # shellcheck disable=SC2086
  run_wrapper $STREAM_ARGS
  assert_status 0 "$STATUS"
  assert_eq "claude $STREAM_ARGS" "$(exec_args)"
}

test_one_leading_path() {
  local bin="$SANDBOX/ext/resources/native-binary/claude"
  mkdir -p "$(dirname "$bin")"
  : >"$bin"
  # shellcheck disable=SC2086
  run_wrapper "$bin" $STREAM_ARGS --resume abc
  assert_status 0 "$STATUS"
  assert_eq "claude $STREAM_ARGS --resume abc" "$(exec_args)"
}

test_two_leading_paths() {
  # shellcheck disable=SC2086
  run_wrapper /usr/local/bin/node /opt/ext/dist/cli.js $STREAM_ARGS
  assert_status 0 "$STATUS"
  assert_eq "claude $STREAM_ARGS" "$(exec_args)"
}

test_bare_interpreter_name_is_dropped() {
  run_wrapper node /opt/ext/cli.mjs --version
  assert_eq "claude --version" "$(exec_args)"
}

test_subcommand_after_leading_path_is_kept() {
  run_wrapper /opt/ext/resources/native-binary/claude worktree remove --json
  assert_status 0 "$STATUS"
  assert_eq "claude worktree remove --json" "$(exec_args)"
}

test_slash_prompt_is_not_mistaken_for_a_path() {
  run_wrapper -p "/review"
  assert_eq "claude -p /review" "$(exec_args)"
}

test_stdout_is_only_the_container_process() {
  run_wrapper /opt/ext/claude --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT" "stdout must carry only the container's stdout"
  assert_contains "$ERR" "fake-stderr"
}

test_stdout_clean_when_container_already_exists_but_stopped() {
  run_wrapper --version
  echo "false $(cut -d' ' -f2 "$FAKE_DOCKER_DIR/state")" >"$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_eq "FAKE-STDOUT" "$OUT"
  assert_contains "$(cat "$FAKE_DOCKER_DIR/calls")" "start "
}

test_exit_status_is_passed_through() {
  FAKE_EXEC_STATUS=7 run_wrapper --version
  assert_status 7 "$STATUS"
}

test_stdin_is_forwarded() {
  set +e
  (cd "$PROJECT" && printf '{"type":"user"}\n' | "$WRAPPER" --input-format stream-json >/dev/null 2>&1)
  set -e
  assert_eq '{"type":"user"}' "$(cat "$FAKE_DOCKER_DIR/exec.stdin")"
}

test_container_name_and_workdir() {
  run_wrapper --version
  local expected
  expected="claude-box-my-project-$(sha8 "$PROJECT")"
  assert_eq "$expected" "$(cat "$FAKE_DOCKER_DIR/exec.name")"
  assert_eq "$PROJECT" "$(cat "$FAKE_DOCKER_DIR/exec.workdir")"
}

test_container_name_sanitised() {
  local dir="$SANDBOX/work/--Ünïcode Stuff!!"
  mkdir -p "$dir"
  RUN_DIR="$dir" run_wrapper --version
  local name
  name="$(cat "$FAKE_DOCKER_DIR/exec.name")"
  case "$name" in
    claude-box-[a-z0-9]*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "unexpected container name '$name'" ;;
  esac
  assert_not_contains "$name" "!"
  assert_not_contains "$name" " "
}

test_project_mounted_at_identical_path() {
  run_wrapper --version
  assert_contains "$(run_args)" "type=bind,src=$PROJECT,dst=$PROJECT"
}

test_hardening_flags() {
  run_wrapper --version
  local a
  a="$(run_args | tr '\n' ' ')"
  assert_contains "$a" "--cap-drop ALL"
  assert_contains "$a" "--security-opt no-new-privileges"
  assert_contains "$a" "--read-only"
  assert_contains "$a" "--init"
  assert_contains "$a" "--pids-limit"
  assert_contains "$a" "--memory"
  assert_contains "$a" "--network claude-box-internal"
  assert_contains "$a" "--dns 127.0.0.1"
  assert_contains "$a" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
  assert_not_contains "$a" "docker.sock"
  assert_not_contains "$a" "src=$HOME,"
  assert_not_contains "$a" "--privileged"
}

test_masks_only_existing_files() {
  : >"$PROJECT/.env"
  mkdir -p "$PROJECT/.env.d"
  : >"$PROJECT/.env.d/x"
  mkdir -p "$PROJECT/sub"
  : >"$PROJECT/sub/.env.local"
  run_wrapper --version
  local a
  a="$(run_args)"
  assert_contains "$a" "dst=$PROJECT/.env,readonly"
  assert_contains "$a" "type=tmpfs,dst=$PROJECT/.env.d,"
  assert_contains "$a" "dst=$PROJECT/sub/.env.local,readonly"
  assert_not_contains "$a" "dst=$PROJECT/.env.production"
}

test_no_mask_when_no_secret_files() {
  run_wrapper --version
  assert_not_contains "$(run_args)" ".env"
}

test_prestashop_mask_preset() {
  mkdir -p "$PROJECT/app/config" "$HOME/.config/claude-box/projects"
  : >"$PROJECT/app/config/parameters.php"
  run_wrapper --version
  assert_not_contains "$(run_args)" "parameters.php"
  local name
  name="$(cat "$FAKE_DOCKER_DIR/exec.name")"
  echo 'MASK_PRESETS="prestashop"' >"$HOME/.config/claude-box/projects/$name.conf"
  run_wrapper --version
  assert_contains "$(run_args)" "dst=$PROJECT/app/config/parameters.php,readonly"
}

test_readonly_dirs_created_and_mounted() {
  run_wrapper --version
  local d
  for d in .git .vscode .agent .agents .idea .devcontainer; do
    assert_file_exists "$PROJECT/$d"
    assert_contains "$(run_args)" "type=bind,src=$PROJECT/$d,dst=$PROJECT/$d,readonly"
  done
}

test_git_writable_option() {
  local name
  run_wrapper --version
  name="$(cat "$FAKE_DOCKER_DIR/exec.name")"
  mkdir -p "$HOME/.config/claude-box/projects"
  echo 'GIT_WRITABLE=1' >"$HOME/.config/claude-box/projects/$name.conf"
  run_wrapper --version
  assert_not_contains "$(run_args)" "dst=$PROJECT/.git,"
  assert_contains "$(run_args)" "dst=$PROJECT/.vscode,readonly"
}

test_new_secret_file_triggers_recreate_when_idle() {
  run_wrapper --version
  : >"$PROJECT/.env"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$FAKE_DOCKER_DIR/calls")" "rm -f"
  assert_contains "$(run_args)" "dst=$PROJECT/.env,readonly"
}

test_new_secret_file_refused_when_busy() {
  run_wrapper --version
  : >"$PROJECT/.env"
  FAKE_BUSY=1 run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  assert_contains "$ERR" "recreate"
}

test_fail_closed_when_daemon_down() {
  FAKE_DOCKER_DOWN=1 run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  assert_contains "$ERR" "Docker"
  assert_file_missing "$FAKE_DOCKER_DIR/host-claude-ran" "host claude must never run"
}

test_fail_closed_when_docker_missing() {
  rm "$SANDBOX/bin/docker"
  local bashdir
  bashdir="$(dirname "$BASH")"
  export PATH="$SANDBOX/bin:$bashdir:/bin"
  CLAUDE_BOX_DOCKER="$SANDBOX/nonexistent" run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  assert_file_missing "$FAKE_DOCKER_DIR/host-claude-ran"
}

test_fail_closed_when_image_missing() {
  FAKE_DOCKER_NO_IMAGE=1 run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  assert_contains "$ERR" "claude-box setup"
}

test_refuses_home_directory() {
  RUN_DIR="$HOME" run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "home directory"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_refuses_root_directory() {
  RUN_DIR=/ run_wrapper --version
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_refuses_parent_of_home() {
  RUN_DIR="$SANDBOX" run_wrapper --version
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_env_passed_by_name_only() {
  CLAUDE_CODE_ENTRYPOINT=claude-vscode MCP_TIMEOUT=5000 CLAUDE_AGENT_SDK_VERSION=1 \
    CLAUDE_CODE_SSE_PORT=12345 CLAUDE_CONFIG_DIR=/x CLAUDE_CODE_TMPDIR=/tmp/x \
    CLAUDE_CODE_IDE_HOST_OVERRIDE=1.2.3.4 SECRET_THING=nope run_wrapper --version
  local env calls
  env="$(cat "$FAKE_DOCKER_DIR/exec.env")"
  calls="$(cat "$FAKE_DOCKER_DIR/calls")"
  assert_contains "$env" "CLAUDE_CODE_ENTRYPOINT=claude-vscode"
  assert_contains "$env" "MCP_TIMEOUT=5000"
  assert_contains "$env" "CLAUDE_AGENT_SDK_VERSION=1"
  assert_not_contains "$env" "CLAUDE_CODE_SSE_PORT"
  assert_not_contains "$env" "CLAUDE_CONFIG_DIR"
  assert_not_contains "$env" "CLAUDE_CODE_TMPDIR"
  assert_not_contains "$env" "CLAUDE_CODE_IDE_HOST_OVERRIDE"
  assert_not_contains "$env" "SECRET_THING"
  assert_not_contains "$calls" "claude-vscode" "values must not appear on the docker command line"
}

test_token_from_file_never_on_command_line() {
  mkdir -p "$HOME/.config/claude-box"
  printf 'sk-ant-oat01-secret\n' >"$HOME/.config/claude-box/token"
  chmod 600 "$HOME/.config/claude-box/token"
  run_wrapper --version
  assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.env")" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-secret"
  assert_not_contains "$(cat "$FAKE_DOCKER_DIR/calls")" "sk-ant-oat01-secret"
  assert_not_contains "$(cat "$HOME/.local/state/claude-box/wrapper.log")" "sk-ant-oat01-secret"
}

test_log_has_args_and_env_names_not_values() {
  CLAUDE_CODE_ENTRYPOINT=value-should-not-be-logged run_wrapper /opt/x/claude --verbose
  local log
  log="$(cat "$HOME/.local/state/claude-box/wrapper.log")"
  assert_contains "$log" "$PROJECT"
  assert_contains "$log" "--verbose"
  assert_contains "$log" "CLAUDE_CODE_ENTRYPOINT"
  assert_not_contains "$log" "value-should-not-be-logged"
}

test_xdg_state_home_respected() {
  export XDG_STATE_HOME="$SANDBOX/state"
  run_wrapper --version
  assert_file_exists "$SANDBOX/state/claude-box/wrapper.log"
}

test_host_path_flags_outside_project_dropped() {
  : >"$PROJECT/mcp.json"
  run_wrapper --mcp-config /etc/outside.json "$PROJECT/mcp.json" '{"mcpServers":{}}' \
    --settings=/etc/settings.json --plugin-dir /opt/plugins --verbose
  local a
  a="$(exec_args)"
  assert_not_contains "$a" "/etc/outside.json"
  assert_not_contains "$a" "/etc/settings.json"
  assert_not_contains "$a" "/opt/plugins"
  assert_not_contains "$a" "--plugin-dir"
  assert_not_contains "$a" "--settings"
  assert_contains "$a" "--mcp-config $PROJECT/mcp.json {\"mcpServers\":{}}"
  assert_contains "$a" "--verbose"
  assert_contains "$ERR" "outside the project"
}

test_inline_json_settings_kept() {
  run_wrapper --settings '{"model":"x"}' --verbose
  assert_eq 'claude --settings {"model":"x"} --verbose' "$(exec_args)"
}

test_relative_path_escaping_project_dropped() {
  run_wrapper --add-dir ../other sub --verbose
  assert_eq "claude --add-dir sub --verbose" "$(exec_args)"
}

test_parallel_starts_create_container_once() {
  local _
  for _ in 1 2 3 4; do
    (cd "$PROJECT" && "$WRAPPER" --version >/dev/null 2>&1 </dev/null) &
  done
  wait
  local n
  n="$(grep -c '^run ' "$FAKE_DOCKER_DIR/calls" || true)"
  assert_eq 1 "$n" "docker run must happen exactly once"
}

test_stale_lock_is_removed() {
  local lockdir="$HOME/.local/state/claude-box/locks"
  local name
  name="claude-box-my-project-$(sha8 "$PROJECT")"
  mkdir -p "$lockdir/$name.lock"
  echo 999999 >"$lockdir/$name.lock/pid"
  run_wrapper --version
  assert_status 0 "$STATUS"
}

test_works_when_invoked_through_symlink() {
  local link="$SANDBOX/ext/resources/native-binary/claude"
  mkdir -p "$(dirname "$link")"
  ln -s "$WRAPPER" "$link"
  set +e
  OUT="$(cd "$PROJECT" && "$link" --version 2>/dev/null </dev/null)"
  STATUS=$?
  set -e
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_unknown_config_key_fails_closed() {
  mkdir -p "$HOME/.config/claude-box"
  echo 'MOUNT_HOME=1' >"$HOME/.config/claude-box/config"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "MOUNT_HOME"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.args"
}

test_cpus_clamped_to_available() {
  FAKE_NCPU=1 run_wrapper --version
  assert_contains "$(run_args | tr '\n' ' ')" "--cpus 1 "
}

test_auto_guard_replaces_new_bundled_binary() {
  local ext="$HOME/.vscode/extensions/anthropic.claude-code-9.9.9-linux-x64/resources/native-binary"
  mkdir -p "$ext"
  printf '#!/bin/sh\necho real\n' >"$ext/claude"
  chmod +x "$ext/claude"
  run_wrapper --version
  assert_status 0 "$STATUS"
  [ -L "$ext/claude" ] || fail "bundled binary was not replaced by a symlink"
  assert_file_exists "$ext/claude.orig"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_auto_guard_can_be_disabled() {
  local ext="$HOME/.vscode/extensions/anthropic.claude-code-9.9.9-linux-x64/resources/native-binary"
  mkdir -p "$ext" "$HOME/.config/claude-box"
  : >"$ext/claude"
  echo 'AUTO_GUARD=0' >"$HOME/.config/claude-box/config"
  run_wrapper --version
  [ ! -L "$ext/claude" ] || fail "guard ran although AUTO_GUARD=0"
}

test_created_readonly_dirs_use_normal_permissions() {
  umask 022
  run_wrapper --version
  local mode
  # shellcheck disable=SC2012 # ls is the portable way to read a mode string (no stat -c on BSD)
  mode="$(ls -ld "$PROJECT/.vscode" | cut -c1-10)"
  assert_eq "drwxr-xr-x" "$mode"
}

# --- mount hardening ----------------------------------------------------------

test_mount_option_injection_via_comma_is_refused() {
  local evil="$PROJECT/q,src=$HOME,dst=/home/claude/leak"
  mkdir -p "$evil"
  : >"$evil/.env"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args" "docker run must not happen"
  assert_contains "$ERR" "cannot be mounted safely"
}

test_mount_paths_with_quote_or_newline_are_refused() {
  mkdir -p "$PROJECT/a\"b" "$PROJECT/c
d"
  : >"$PROJECT/a\"b/.env"
  run_wrapper --version
  assert_nonzero "$STATUS"
  rm -rf "$PROJECT/a\"b"
  : >"$PROJECT/c
d/.env"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_nested_git_directories_are_read_only() {
  mkdir -p "$PROJECT/sub/.git" "$PROJECT/vendor/acme/pkg/.git" "$PROJECT/wt"
  echo "gitdir: /elsewhere" >"$PROJECT/wt/.git"
  run_wrapper --version
  assert_status 0 "$STATUS"
  local a
  a="$(run_args)"
  assert_contains "$a" "type=bind,src=$PROJECT/sub/.git,dst=$PROJECT/sub/.git,readonly"
  assert_contains "$a" "type=bind,src=$PROJECT/vendor/acme/pkg/.git,dst=$PROJECT/vendor/acme/pkg/.git,readonly"
  assert_contains "$a" "type=bind,src=$PROJECT/wt/.git,dst=$PROJECT/wt/.git,readonly"
}

test_new_nested_git_triggers_recreate() {
  run_wrapper --version
  mkdir -p "$PROJECT/evil/.git"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(run_args)" "dst=$PROJECT/evil/.git,readonly"
}

test_masks_are_found_in_node_modules_and_vendor() {
  mkdir -p "$PROJECT/node_modules/x" "$PROJECT/vendor/y"
  : >"$PROJECT/node_modules/x/.env"
  : >"$PROJECT/vendor/y/.env.prod"
  run_wrapper --version
  assert_contains "$(run_args)" "dst=$PROJECT/node_modules/x/.env,readonly"
  assert_contains "$(run_args)" "dst=$PROJECT/vendor/y/.env.prod,readonly"
}

test_moved_masked_file_fails_closed() {
  mkdir -p "$PROJECT/app/config" "$HOME/.config/claude-box/projects"
  echo 'SECRET' >"$PROJECT/app/config/parameters.php"
  local name
  name="claude-box-my-project-$(sha8 "$PROJECT")"
  echo 'MASK_PRESETS="prestashop"' >"$HOME/.config/claude-box/projects/$name.conf"
  run_wrapper --version
  assert_status 0 "$STATUS"
  # Inside the container the parent of a mountpoint can be renamed.
  mv "$PROJECT/app/config" "$PROJECT/app/cfg"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "app/config/parameters.php"
  assert_eq "" "$OUT"
}

test_recreate_by_user_accepts_removed_masks() {
  : >"$PROJECT/.env"
  run_wrapper --version
  rm "$PROJECT/.env"
  run_wrapper --version
  assert_nonzero "$STATUS"
  run_cli up --recreate
  assert_status 0 "$STATUS"
  run_wrapper --version
  assert_status 0 "$STATUS"
}

test_moved_masked_file_with_decoy_fails_closed() {
  mkdir -p "$PROJECT/app/config" "$HOME/.config/claude-box/projects"
  echo 'SECRET' >"$PROJECT/app/config/parameters.php"
  local name
  name="claude-box-my-project-$(sha8 "$PROJECT")"
  echo 'MASK_PRESETS="prestashop"' >"$HOME/.config/claude-box/projects/$name.conf"
  run_wrapper --version
  assert_status 0 "$STATUS"
  mv "$PROJECT/app/config" "$PROJECT/app/cfg"
  mkdir -p "$PROJECT/app/config"
  echo 'decoy' >"$PROJECT/app/config/parameters.php"
  # The running container still masks the moved file (the mount moved with
  # its parent); the danger is the next creation, e.g. after `docker rm`.
  rm -f "$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "app/config/parameters.php"
}
