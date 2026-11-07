# shellcheck shell=bash
# Unit tests for dependency volumes (DEPS_VOLUMES, `claude-ide-box deps`) and
# the detection of native dependencies built for another platform.

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }

container() {
  printf 'claude-ide-box-my-project-%s\n' "$(sha8 "$PROJECT")"
}

project_conf() {
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf '%s\n' "$@" >"$HOME/.config/claude-ide-box/projects/$(container).conf"
}

deps_volume() {
  printf '%s-deps-%s\n' "$(container)" "$(sha8 "$1")"
}

# --- mounts ---------------------------------------------------------------

test_deps_volume_is_mounted_over_node_modules() {
  mkdir -p "$PROJECT/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(run_args)" "type=volume,src=$(deps_volume node_modules),dst=$PROJECT/node_modules"
  # the project itself is still the same bind mount
  assert_contains "$(run_args)" "type=bind,src=$PROJECT,dst=$PROJECT"
}

test_no_deps_volume_by_default() {
  mkdir -p "$PROJECT/node_modules"
  run_wrapper --version
  assert_not_contains "$(run_args)" "-deps-"
  assert_file_missing "$FAKE_DOCKER_DIR/run-rm.log"
}

test_missing_root_deps_directory_is_created_on_the_host() {
  project_conf 'DEPS_VOLUMES="node_modules .venv"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  [ -d "$PROJECT/node_modules" ] && [ ! -L "$PROJECT/node_modules" ] || fail "node_modules was not created as a directory"
  [ -w "$PROJECT/.venv" ] || fail ".venv was not created writable for the user"
  assert_contains "$(run_args)" "dst=$PROJECT/.venv"
}

test_deps_name_matches_nested_workspaces_but_not_inside_itself() {
  mkdir -p "$PROJECT/node_modules/pkg/node_modules" "$PROJECT/packages/a/node_modules" \
    "$PROJECT/apps/web/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_contains "$(run_args)" "dst=$PROJECT/packages/a/node_modules"
  assert_contains "$(run_args)" "dst=$PROJECT/apps/web/node_modules"
  assert_contains "$(run_args)" "src=$(deps_volume packages/a/node_modules),"
  assert_not_contains "$(run_args)" "dst=$PROJECT/node_modules/pkg/node_modules"
}

test_deps_path_with_slash_is_anchored_at_the_root() {
  mkdir -p "$PROJECT/web/node_modules" "$PROJECT/other/web/node_modules"
  project_conf 'DEPS_VOLUMES="web/node_modules"'
  run_wrapper --version
  assert_contains "$(run_args)" "dst=$PROJECT/web/node_modules"
  assert_not_contains "$(run_args)" "dst=$PROJECT/other/web/node_modules"
}

test_masks_and_nested_git_inside_a_deps_directory_are_not_mounted() {
  # The volume hides the host directory, so nothing below it can leak; a
  # mount target inside the volume would only make Docker create files there.
  mkdir -p "$PROJECT/node_modules/pkg/.git" "$PROJECT/src"
  : >"$PROJECT/node_modules/pkg/.env"
  : >"$PROJECT/src/.env"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_not_contains "$(run_args)" "dst=$PROJECT/node_modules/pkg/.env"
  assert_not_contains "$(run_args)" "dst=$PROJECT/node_modules/pkg/.git"
  assert_contains "$(run_args)" "dst=$PROJECT/src/.env,readonly"
}

test_masks_in_node_modules_still_apply_without_deps_volumes() {
  mkdir -p "$PROJECT/node_modules/pkg"
  : >"$PROJECT/node_modules/pkg/.env"
  run_wrapper --version
  assert_contains "$(run_args)" "dst=$PROJECT/node_modules/pkg/.env,readonly"
}

test_new_deps_volume_is_labelled_and_given_to_the_container_user() {
  mkdir -p "$PROJECT/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  local vol log
  vol="$(deps_volume node_modules)"
  assert_file_exists "$FAKE_DOCKER_DIR/volumes/$vol"
  assert_contains "$(cat "$FAKE_DOCKER_DIR/volumes/$vol")" "io.claude-ide-box.deps-of=$(container)"
  log="$(cat "$FAKE_DOCKER_DIR/run-rm.log")"
  assert_contains "$log" "chown"
  # the container user's IDs (1000 when the tests run as root)
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  [ "$uid" != 0 ] || uid=1000
  [ "$gid" != 0 ] || gid=1000
  assert_contains "$log" " $uid:$gid "
  assert_contains "$log" "--network none"
  assert_contains "$log" "--cap-drop ALL"
  assert_contains "$log" "--cap-add CHOWN"
  assert_contains "$log" "type=volume,src=$vol,dst="
  # the one-off root container never sees the project
  assert_not_contains "$log" "$PROJECT"
}

test_existing_deps_volume_is_not_touched_again() {
  mkdir -p "$PROJECT/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  rm -f "$FAKE_DOCKER_DIR/run-rm.log" "$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run-rm.log"
}

test_deps_volume_change_recreates_the_container() {
  mkdir -p "$PROJECT/node_modules"
  run_wrapper --version
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "rm -f $(container)"
  assert_contains "$(run_args)" "dst=$PROJECT/node_modules"
}

test_symlinked_deps_directory_fails_closed() {
  mkdir -p "$PROJECT/real_modules"
  ln -s real_modules "$PROJECT/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "symlink"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_deps_entry_that_is_a_file_fails_closed() {
  : >"$PROJECT/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_invalid_deps_entries_fail_closed() {
  local e
  for e in /abs ../up . .git a/../b .vscode; do
    rm -f "$FAKE_DOCKER_DIR/run.args"
    project_conf "DEPS_VOLUMES=\"$e\""
    run_wrapper --version
    assert_nonzero "$STATUS" "DEPS_VOLUMES=$e must be refused"
    assert_file_missing "$FAKE_DOCKER_DIR/run.args" "no container for DEPS_VOLUMES=$e"
  done
}

test_deps_path_with_comma_fails_closed() {
  mkdir -p "$PROJECT/x,src=$HOME,dst=y/node_modules"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_wrapper_stdout_stays_clean_with_deps_volumes() {
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_new_empty_deps_volume_is_announced() {
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_contains "$ERR" "claude-ide-box deps install"
}

# --- deps command ---------------------------------------------------------

test_deps_on_off_and_status() {
  run_cli deps on
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$HOME/.config/claude-ide-box/projects/$(container).conf")" 'DEPS_VOLUMES="node_modules .venv"'
  assert_contains "$OUT" "claude-ide-box deps install"
  run_cli deps
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "node_modules"
  run_cli deps on node_modules packages/api/.venv
  assert_contains "$(cat "$HOME/.config/claude-ide-box/projects/$(container).conf")" 'DEPS_VOLUMES="node_modules packages/api/.venv"'
  run_cli deps off
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$HOME/.config/claude-ide-box/projects/$(container).conf")" 'DEPS_VOLUMES=""'
}

test_deps_on_rejects_bad_paths() {
  run_cli deps on ../x
  assert_nonzero "$STATUS"
  run_cli deps on /etc
  assert_nonzero "$STATUS"
}

test_deps_install_uses_the_lockfile() {
  local lock cmd
  for lock in package-lock.json:"npm ci" pnpm-lock.yaml:"corepack pnpm install --frozen-lockfile" \
    yarn.lock:"yarn install --frozen-lockfile"; do
    rm -f "$PROJECT"/*.json "$PROJECT"/*.yaml "$PROJECT"/*.lock "$FAKE_DOCKER_DIR/exec.log"
    echo '{}' >"$PROJECT/package.json"
    : >"$PROJECT/${lock%%:*}"
    cmd="${lock#*:}"
    project_conf 'DEPS_VOLUMES="node_modules"'
    run_cli deps install
    assert_status 0 "$STATUS" "deps install with ${lock%%:*}"
    assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.log")" "$PROJECT :: $cmd"
  done
}

test_deps_install_yarn_berry_is_immutable() {
  echo '{}' >"$PROJECT/package.json"
  : >"$PROJECT/yarn.lock"
  : >"$PROJECT/.yarnrc.yml"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_cli deps install
  assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.log")" "yarn install --immutable"
}

test_deps_install_runs_once_for_a_workspace() {
  echo '{}' >"$PROJECT/package.json"
  : >"$PROJECT/pnpm-lock.yaml"
  mkdir -p "$PROJECT/packages/a/node_modules" "$PROJECT/packages/b/node_modules"
  echo '{}' >"$PROJECT/packages/a/package.json"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_cli deps install
  assert_status 0 "$STATUS"
  assert_eq 1 "$(grep -c 'pnpm install' "$FAKE_DOCKER_DIR/exec.log")"
}

test_deps_install_python_venv() {
  printf 'requests==2.32.3\n' >"$PROJECT/requirements.txt"
  project_conf 'DEPS_VOLUMES=".venv"'
  run_cli deps install
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.log")" "python3 -m venv .venv"
  assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.log")" ".venv/bin/pip install -r requirements.txt"
  rm -f "$PROJECT/requirements.txt" "$FAKE_DOCKER_DIR/exec.log"
  : >"$PROJECT/uv.lock"
  run_cli deps install
  assert_contains "$(cat "$FAKE_DOCKER_DIR/exec.log")" "uv sync --frozen"
}

test_deps_install_without_lockfile_says_what_to_do() {
  echo '{}' >"$PROJECT/package.json"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_cli deps install
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "lockfile"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.log"
}

test_deps_install_needs_deps_volumes() {
  : >"$PROJECT/package-lock.json"
  run_cli deps install
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "deps on"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.log"
}

test_deps_install_failure_is_reported() {
  : >"$PROJECT/package-lock.json"
  project_conf 'DEPS_VOLUMES="node_modules"'
  FAKE_EXEC_STATUS=1 run_cli deps install
  assert_nonzero "$STATUS"
}

test_rm_volume_also_removes_deps_volumes() {
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_cli up
  assert_file_exists "$FAKE_DOCKER_DIR/volumes/$(deps_volume node_modules)"
  run_cli rm
  assert_file_exists "$FAKE_DOCKER_DIR/volumes/$(deps_volume node_modules)"
  run_cli rm --volume
  assert_status 0 "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/volumes/$(deps_volume node_modules)"
}

# --- native dependencies of another platform ---------------------------------

test_first_start_warns_about_darwin_binaries_in_node_modules() {
  mkdir -p "$PROJECT/node_modules/@esbuild/darwin-x64" "$PROJECT/node_modules/@rollup/rollup-darwin-arm64" \
    "$PROJECT/node_modules/is-windows"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
  assert_contains "$ERR" "node_modules/@esbuild/darwin-x64"
  assert_contains "$ERR" "claude-ide-box deps on"
  assert_not_contains "$ERR" "is-windows"
  assert_contains "$(cat "$HOME/.local/state/claude-ide-box/wrapper.log")" "another platform"
}

test_pnpm_store_and_workerd_windows_are_detected() {
  mkdir -p "$PROJECT/node_modules/.pnpm/@cloudflare+workerd-windows-64@1.2/node_modules" \
    "$PROJECT/packages/x/node_modules/@img/sharp-win32-x64"
  run_cli up
  assert_contains "$ERR" "workerd-windows-64"
  assert_contains "$ERR" "packages/x/node_modules/@img/sharp-win32-x64"
}

test_linux_binaries_are_not_reported() {
  mkdir -p "$PROJECT/node_modules/@esbuild/linux-x64" "$PROJECT/node_modules/@rollup/rollup-linux-x64-gnu"
  run_wrapper --version
  assert_not_contains "$ERR" "another platform"
}

test_foreign_binaries_hidden_by_a_deps_volume_are_not_reported() {
  mkdir -p "$PROJECT/node_modules/@esbuild/darwin-arm64"
  project_conf 'DEPS_VOLUMES="node_modules"'
  run_wrapper --version
  assert_not_contains "$ERR" "darwin-arm64"
}

test_foreign_check_runs_only_when_the_container_is_created() {
  run_wrapper --version
  mkdir -p "$PROJECT/node_modules/@esbuild/darwin-x64"
  run_wrapper --version
  assert_not_contains "$ERR" "darwin-x64"
}

test_macos_venv_is_detected() {
  mkdir -p "$PROJECT/.venv/lib/python3.12/site-packages"
  printf 'home = /opt/homebrew/opt/python@3.12/bin\nversion = 3.12.4\n' >"$PROJECT/.venv/pyvenv.cfg"
  run_wrapper --version
  assert_contains "$ERR" ".venv"
  assert_contains "$ERR" "claude-ide-box deps on"
}

test_linux_venv_is_not_reported() {
  mkdir -p "$PROJECT/.venv"
  printf 'home = /usr/bin\nversion = 3.11.2\n' >"$PROJECT/.venv/pyvenv.cfg"
  run_wrapper --version
  assert_not_contains "$ERR" "another platform"
}

test_doctor_reports_foreign_binaries_in_the_project() {
  mkdir -p "$PROJECT/node_modules/@esbuild/darwin-x64"
  run_cli doctor
  assert_contains "$OUT" "[warn]"
  assert_contains "$OUT" "node_modules/@esbuild/darwin-x64"
  assert_contains "$OUT" "claude-ide-box deps on"
}
