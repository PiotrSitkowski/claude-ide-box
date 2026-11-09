# shellcheck shell=bash
# Unit tests for the ephemeral mode: up --try, try diff/apply/discard/end.

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }
base_name() { printf 'claude-ide-box-my-project-%s\n' "$(sha8 "$PROJECT")"; }
try_root() { printf '%s/.cache/claude-ide-box/try/%s\n' "$HOME" "$(base_name)"; }
work() { printf '%s/work\n' "$(try_root)"; }

try_fixture() {
  printf 'a\n' >"$PROJECT/a.txt"
  printf 'b\n' >"$PROJECT/b.txt"
  mkdir -p "$PROJECT/dir" "$PROJECT/.git"
  printf 'c\n' >"$PROJECT/dir/c.txt"
  printf 'SECRET=1\n' >"$PROJECT/.env"
  printf '[core]\n' >"$PROJECT/.git/config"
}

# run_try_cli INPUT ARGS... - run the CLI with INPUT on stdin.
run_cli_input() {
  local input="$1"
  shift
  set +e
  OUT="$(cd "$PROJECT" && printf '%s' "$input" | "$CLI" "$@" 2>"$SANDBOX/stderr")"
  STATUS=$?
  set -e
  ERR="$(cat "$SANDBOX/stderr")"
}

test_try_copies_the_project_and_mounts_the_copy_at_the_same_path() {
  try_fixture
  run_cli up --try
  assert_status 0 "$STATUS" "$ERR"
  local w a
  w="$(work)"
  assert_eq "a" "$(cat "$w/a.txt")"
  assert_file_exists "$w/.env"
  assert_eq "" "$(cat "$w/.env")" "the copy must not hold the secret"
  assert_eq "SECRET=1" "$(cat "$PROJECT/.env")"
  a="$(run_args | tr '\n' ' ')"
  assert_contains "$a" "--name $(base_name)-try "
  assert_contains "$a" "type=bind,src=$w,dst=$PROJECT "
  assert_not_contains "$a" "src=$PROJECT,"
  assert_contains "$a" "dst=$PROJECT/.env,readonly"
  assert_contains "$a" "type=bind,src=$w/.git,dst=$PROJECT/.git,readonly"
  assert_contains "$a" "src=$(base_name)-try-home,"
}

test_try_blanks_secrets_reached_through_symlinks() {
  mkdir -p "$PROJECT/config"
  printf 'REAL\n' >"$PROJECT/config/prod"
  # absolute link into the project: inside the container it resolves to the copy
  ln -s "$PROJECT/config/prod" "$PROJECT/.env"
  run_cli up --try
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "" "$(cat "$(work)/config/prod")"
  assert_eq "REAL" "$(cat "$PROJECT/config/prod")"
}

test_wrapper_uses_the_try_container_while_a_session_is_active() {
  try_fixture
  run_cli up --try
  run_wrapper --version
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "$(base_name)-try" "$(cat "$FAKE_DOCKER_DIR/exec.name")"
  assert_eq "$PROJECT" "$(cat "$FAKE_DOCKER_DIR/exec.workdir")"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_up_try_twice_resumes_the_session() {
  try_fixture
  run_cli up --try
  printf 'new\n' >"$(work)/new.txt"
  run_cli up --try
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$OUT" "resum"
  assert_file_exists "$(work)/new.txt"
}

test_try_diff_lists_and_shows_changes() {
  try_fixture
  run_cli up --try
  printf 'changed\n' >"$(work)/a.txt"
  rm "$(work)/b.txt"
  printf 'new\n' >"$(work)/new.txt"
  run_cli try diff
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$OUT" "modified  a.txt"
  assert_contains "$OUT" "deleted   b.txt"
  assert_contains "$OUT" "added     new.txt"
  assert_contains "$OUT" "+changed"
  assert_contains "$OUT" "-a"
  assert_not_contains "$OUT" "dir/c.txt"
}

test_try_apply_applies_changes_and_ends_the_session() {
  try_fixture
  run_cli up --try
  printf 'changed\n' >"$(work)/a.txt"
  rm "$(work)/b.txt"
  mkdir -p "$(work)/new/deep"
  printf 'new\n' >"$(work)/new/deep/n.txt"
  printf '#!/bin/sh\n' >"$(work)/run.sh"
  chmod +x "$(work)/run.sh"
  : >"$FAKE_DOCKER_DIR/calls"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "changed" "$(cat "$PROJECT/a.txt")"
  assert_file_missing "$PROJECT/b.txt"
  assert_eq "new" "$(cat "$PROJECT/new/deep/n.txt")"
  [ -x "$PROJECT/run.sh" ] || fail "run.sh lost its execute bit"
  assert_eq "c" "$(cat "$PROJECT/dir/c.txt")"
  # the container is removed before anything is compared or written
  assert_contains "$(calls | head -n 3)" "rm -f $(base_name)-try"
  assert_contains "$(calls)" "volume rm $(base_name)-try-home"
  assert_file_missing "$(try_root)"
  rm -f "$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_eq "$(base_name)" "$(cat "$FAKE_DOCKER_DIR/exec.name")"
}

test_try_apply_never_writes_masked_or_readonly_paths() {
  try_fixture
  run_cli up --try
  local w
  w="$(work)"
  printf 'LEAK\n' >"$w/.env"
  printf 'NEW\n' >"$w/.env.local"
  printf '[core]\n\thooksPath = x\n' >"$w/.git/config"
  mkdir -p "$w/.vscode" "$w/sub/.git/hooks"
  printf '{}\n' >"$w/.vscode/tasks.json"
  printf 'evil\n' >"$w/sub/.git/hooks/post-checkout"
  printf 'ok\n' >"$w/fine.txt"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "SECRET=1" "$(cat "$PROJECT/.env")"
  assert_file_missing "$PROJECT/.env.local"
  assert_eq "[core]" "$(cat "$PROJECT/.git/config")"
  assert_file_missing "$PROJECT/.vscode/tasks.json"
  assert_file_missing "$PROJECT/sub/.git"
  assert_eq "ok" "$(cat "$PROJECT/fine.txt")"
  assert_contains "$OUT" "not applied"
  assert_contains "$OUT" ".env.local"
}

test_try_apply_refuses_conflicts_and_writes_nothing() {
  try_fixture
  run_cli up --try
  printf 'mine\n' >"$PROJECT/a.txt"
  printf 'claude\n' >"$(work)/a.txt"
  printf 'new\n' >"$(work)/new.txt"
  run_cli try apply
  assert_nonzero "$STATUS"
  assert_contains "$ERR$OUT" "conflict"
  assert_contains "$ERR$OUT" "a.txt"
  assert_eq "mine" "$(cat "$PROJECT/a.txt")"
  assert_file_missing "$PROJECT/new.txt"
  assert_file_exists "$(work)/a.txt"
  run_cli try apply --skip-conflicts
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "mine" "$(cat "$PROJECT/a.txt")"
  assert_eq "new" "$(cat "$PROJECT/new.txt")"
  # Claude's version of the conflicting file is kept for the user.
  assert_eq "claude" "$(cat "$(work)/a.txt")"
  assert_contains "$OUT" "a.txt"
}

test_try_identical_change_on_both_sides_is_not_a_conflict() {
  try_fixture
  run_cli up --try
  printf 'same\n' >"$PROJECT/a.txt"
  printf 'same\n' >"$(work)/a.txt"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "same" "$(cat "$PROJECT/a.txt")"
}

test_try_apply_copies_symlinks_as_symlinks() {
  try_fixture
  printf 'HOSTSECRET\n' >"$SANDBOX/hostsecret"
  run_cli up --try
  ln -s "$SANDBOX/hostsecret" "$(work)/link.txt"
  rm "$(work)/b.txt"
  ln -s "$SANDBOX/hostsecret" "$(work)/b.txt"
  run_cli try diff
  assert_not_contains "$OUT" "HOSTSECRET"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  [ -L "$PROJECT/link.txt" ] || fail "link.txt is not a symlink"
  [ -L "$PROJECT/b.txt" ] || fail "b.txt is not a symlink"
  assert_eq "$SANDBOX/hostsecret" "$(readlink "$PROJECT/link.txt")"
  # Regular files only: busybox `grep -r` follows symlinks, and links to the
  # host file are allowed (they are applied as links, not as content).
  if find "$PROJECT" -type f -exec grep -l HOSTSECRET {} + 2>/dev/null | grep -q .; then
    fail "a host file's content was copied into the project"
  fi
}

test_try_apply_does_not_write_through_a_symlinked_parent() {
  try_fixture
  mkdir -p "$SANDBOX/outside"
  run_cli up --try
  printf 'x\n' >"$(work)/dir/new.txt"
  # meanwhile something replaces dir/ in the project by a link out of it
  rm -rf "$PROJECT/dir"
  ln -s "$SANDBOX/outside" "$PROJECT/dir"
  run_cli try apply --skip-conflicts
  assert_file_missing "$SANDBOX/outside/new.txt"
  assert_contains "$OUT$ERR" "dir/new.txt"
}

test_try_apply_skips_special_files() {
  try_fixture
  command -v mkfifo >/dev/null 2>&1 || return 0
  run_cli up --try
  mkfifo "$(work)/pipe"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_file_missing "$PROJECT/pipe"
  assert_contains "$OUT" "pipe"
}

test_try_deleted_directory_keeps_files_the_user_added() {
  try_fixture
  run_cli up --try
  rm -rf "$(work)/dir"
  printf 'mine\n' >"$PROJECT/dir/user.txt"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_file_missing "$PROJECT/dir/c.txt"
  assert_eq "mine" "$(cat "$PROJECT/dir/user.txt")"
}

test_try_discard_removes_the_copy_and_the_container() {
  try_fixture
  run_cli up --try
  printf 'changed\n' >"$(work)/a.txt"
  run_cli try discard
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "a" "$(cat "$PROJECT/a.txt")"
  assert_file_missing "$(try_root)"
  assert_contains "$(calls)" "rm -f $(base_name)-try"
  assert_contains "$(calls)" "volume rm $(base_name)-try-home"
  rm -f "$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_eq "$(base_name)" "$(cat "$FAKE_DOCKER_DIR/exec.name")"
}

test_try_end_shows_the_diff_and_asks() {
  try_fixture
  run_cli up --try
  printf 'changed\n' >"$(work)/a.txt"
  run_cli_input 'k
' try end
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$OUT" "+changed"
  assert_file_exists "$(try_root)"
  run_cli_input 'a
' try end
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "changed" "$(cat "$PROJECT/a.txt")"
  assert_file_missing "$(try_root)"
}

test_try_commands_need_a_session() {
  run_cli try apply
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "no try session"
  run_cli try discard
  assert_nonzero "$STATUS"
  run_cli try
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "no try session"
}

test_try_apply_fails_closed_without_docker() {
  try_fixture
  run_cli up --try
  printf 'changed\n' >"$(work)/a.txt"
  FAKE_DOCKER_DOWN=1 run_cli try apply
  assert_nonzero "$STATUS"
  assert_eq "a" "$(cat "$PROJECT/a.txt")"
}

test_try_copy_path_with_comma_is_refused() {
  try_fixture
  XDG_CACHE_HOME="$SANDBOX/ca,che" run_cli up --try
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_try_apply_never_reads_through_a_symlinked_directory_in_the_copy() {
  # Inside the container Claude can replace a directory of the copy by a
  # link to a host path it guessed. Comparing or copying through it would
  # pull host files into the project.
  mkdir -p "$PROJECT/docs" "$SANDBOX/hostdir"
  printf 'project\n' >"$PROJECT/docs/config"
  printf 'HOSTSECRET\n' >"$SANDBOX/hostdir/config"
  run_cli up --try
  rm -rf "$(work)/docs"
  ln -s "$SANDBOX/hostdir" "$(work)/docs"
  run_cli try diff
  assert_not_contains "$OUT" "HOSTSECRET"
  run_cli try apply --skip-conflicts
  # Regular files only: busybox `grep -r` follows symlinks, and links to the
  # host file are allowed (they are applied as links, not as content).
  if find "$PROJECT" -type f -exec grep -l HOSTSECRET {} + 2>/dev/null | grep -q .; then
    fail "a host file's content was copied into the project"
  fi
  assert_eq "HOSTSECRET" "$(cat "$SANDBOX/hostdir/config")"
}

test_try_works_when_the_cache_path_contains_a_symlink() {
  try_fixture
  mkdir -p "$SANDBOX/realcache"
  ln -s "$SANDBOX/realcache" "$SANDBOX/linkcache"
  export XDG_CACHE_HOME="$SANDBOX/linkcache"
  run_cli up --try
  assert_status 0 "$STATUS" "$ERR"
  printf 'changed\n' >"$SANDBOX/linkcache/claude-ide-box/try/$(base_name)/work/a.txt"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "changed" "$(cat "$PROJECT/a.txt")"
}
