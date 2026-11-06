# shellcheck shell=bash
# Unit tests for COPY_HISTORY: copying finished transcripts from the project's
# container volume to ~/.claude/projects on the host, container -> host only.
#
# The fake docker keeps the container's /home/claude in $FAKE_DOCKER_DIR/home
# and emulates the listing and reading done by node in the container; the real
# node script is tested on its own at the end (when node is installed).

U1=11111111-2222-4333-8444-555555555555
U2=22222222-3333-4444-8555-666666666666
U3=33333333-4444-4555-8666-777777777777
U4=44444444-5555-4666-8777-888888888888

# hist_setup [CONFIG_LINES] - enable COPY_HISTORY for $PROJECT; sets CDIR (the
# transcript directory in the container volume) and HDIR (the one on the host).
hist_setup() {
  local name slug
  name="claude-ide-box-my-project-$(sha8 "$PROJECT")"
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf 'COPY_HISTORY=1\n%s\n' "${1:-}" >"$HOME/.config/claude-ide-box/projects/$name.conf"
  slug="$(printf '%s' "$PROJECT" | tr -c 'a-zA-Z0-9' '-')"
  CDIR="$FAKE_DOCKER_DIR/home/.claude/projects/$slug"
  HDIR="$HOME/.claude/projects/$slug"
  RECORD="$HOME/.local/state/claude-ide-box/history/$name.list"
  mkdir -p "$CDIR"
}

history_runs() {
  grep -c 'history: done' "$HOME/.local/state/claude-ide-box/wrapper.log" 2>/dev/null || true
}

# run_history [ARGS...] - run the wrapper and wait for its background copy.
run_history() {
  local before n=0
  before="$(history_runs)"
  run_wrapper "${@:---version}"
  while [ "$(history_runs)" -le "${before:-0}" ]; do
    n=$((n + 1))
    if [ "$n" -gt 150 ]; then
      fail "the history copy did not finish"
      return 1
    fi
    sleep 0.1
  done
}

wrapper_log() {
  cat "$HOME/.local/state/claude-ide-box/wrapper.log"
}

test_history_off_by_default_copies_nothing() {
  local slug
  slug="$(printf '%s' "$PROJECT" | tr -c 'a-zA-Z0-9' '-')"
  mkdir -p "$FAKE_DOCKER_DIR/home/.claude/projects/$slug"
  printf '{"a":1}\n' >"$FAKE_DOCKER_DIR/home/.claude/projects/$slug/$U1.jsonl"
  run_wrapper --version
  sleep 1
  assert_status 0 "$STATUS"
  assert_file_missing "$HOME/.claude/projects/$slug/$U1.jsonl"
  assert_not_contains "$(cat "$FAKE_DOCKER_DIR/calls")" " node -e "
  assert_not_contains "$(wrapper_log)" "history:"
}

test_history_copies_a_regular_transcript() {
  hist_setup
  printf '{"type":"user","n":1}\n{"type":"assistant","n":2}\n' >"$CDIR/$U1.jsonl"
  run_history
  assert_status 0 "$STATUS"
  assert_eq "$(cat "$CDIR/$U1.jsonl")" "$(cat "$HDIR/$U1.jsonl" 2>/dev/null)" "copied content"
  [ -f "$HDIR/$U1.jsonl" ] && [ ! -L "$HDIR/$U1.jsonl" ] || fail "the copy is not a regular file"
  assert_contains "$(cat "$RECORD" 2>/dev/null)" "$HDIR/$U1.jsonl" "the copy is recorded"
}

test_history_copy_keeps_stdout_and_arguments_unchanged() {
  hist_setup
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  run_history --resume "$U1" --output-format stream-json
  assert_eq "FAKE-STDOUT" "$OUT" "stdout must carry only the container's stdout"
  assert_eq "claude --resume $U1 --output-format stream-json" "$(exec_args)" "resume goes into the container"
  assert_file_exists "$HDIR/$U1.jsonl"
}

test_history_skips_a_symlink() {
  hist_setup
  printf 'secret\n' >"$FAKE_DOCKER_DIR/home/elsewhere"
  ln -s ../../elsewhere "$CDIR/$U2.jsonl"
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  run_history
  assert_file_exists "$HDIR/$U1.jsonl"
  assert_file_missing "$HDIR/$U2.jsonl" "a symlink must not be copied"
  assert_contains "$(wrapper_log)" "$U2.jsonl"
}

test_history_skips_a_fifo() {
  hist_setup
  mkfifo "$CDIR/$U3.jsonl"
  run_history
  assert_status 0 "$STATUS"
  assert_file_missing "$HDIR/$U3.jsonl" "a FIFO must not be copied"
  assert_contains "$(wrapper_log)" "$U3.jsonl"
}

test_history_skips_names_that_are_not_session_ids() {
  hist_setup
  local n
  for n in notes.jsonl "$U1.jsonl.bak" AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.jsonl "x$U1.jsonl" "$U1.json" .hidden.jsonl; do
    printf '{"n":1}\n' >"$CDIR/$n"
  done
  mkdir -p "$CDIR/memory" "$CDIR/$U2" "$CDIR/$U4.jsonl"
  printf 'remember\n' >"$CDIR/memory/MEMORY.md"
  printf '{"n":1}\n' >"$CDIR/$U2/sub.jsonl"
  run_history
  assert_status 0 "$STATUS"
  if [ -d "$HDIR" ]; then
    assert_eq "" "$(ls -A "$HDIR")" "nothing but session transcripts may be copied"
  fi
}

test_history_skips_a_file_over_the_size_limit() {
  hist_setup 'COPY_HISTORY_MAX_SIZE=1k'
  awk 'BEGIN { for (i = 0; i < 2000; i++) printf "x" }' >"$CDIR/$U1.jsonl"
  awk 'BEGIN { for (i = 0; i < 1000; i++) printf "y" }' >"$CDIR/$U2.jsonl"
  run_history
  assert_file_missing "$HDIR/$U1.jsonl" "a file over COPY_HISTORY_MAX_SIZE must not be copied"
  assert_file_exists "$HDIR/$U2.jsonl"
  assert_contains "$(wrapper_log)" "$U1.jsonl"
}

test_history_keeps_to_the_total_limit() {
  hist_setup 'COPY_HISTORY_MAX_TOTAL=3k'
  local u
  for u in "$U1" "$U2" "$U3"; do
    awk 'BEGIN { for (i = 0; i < 1400; i++) printf "z" }' >"$CDIR/$u.jsonl"
  done
  run_history
  local n=0 f
  for f in "$HDIR"/*.jsonl; do
    [ ! -f "$f" ] || n=$((n + 1))
  done
  assert_eq 2 "$n" "only what fits in COPY_HISTORY_MAX_TOTAL"
  assert_contains "$(wrapper_log)" "COPY_HISTORY_MAX_TOTAL"
}

test_history_never_overwrites_a_host_file_it_did_not_create() {
  hist_setup
  mkdir -p "$HDIR"
  printf '{"session":"run on the host"}\n' >"$HDIR/$U1.jsonl"
  printf '{"session":"from the box"}\n' >"$CDIR/$U1.jsonl"
  run_history
  assert_eq '{"session":"run on the host"}' "$(cat "$HDIR/$U1.jsonl")" "a foreign host file must stay"
  assert_contains "$(wrapper_log)" "not created by"
  # Still not on a later start, when the container file changes.
  printf '{"more":1}\n' >>"$CDIR/$U1.jsonl"
  echo 1500000000 >"$FAKE_DOCKER_DIR/mtime.$U1.jsonl"
  run_history
  assert_eq '{"session":"run on the host"}' "$(cat "$HDIR/$U1.jsonl")"
}

test_history_never_writes_through_a_host_symlink() {
  hist_setup
  mkdir -p "$HDIR"
  printf 'precious\n' >"$SANDBOX/target"
  ln -s "$SANDBOX/target" "$HDIR/$U1.jsonl"
  printf '{"session":"from the box"}\n' >"$CDIR/$U1.jsonl"
  run_history
  assert_eq precious "$(cat "$SANDBOX/target")"
  [ -L "$HDIR/$U1.jsonl" ] || fail "the host symlink was replaced"
}

test_history_updates_its_own_copy() {
  hist_setup
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  run_history
  printf '{"n":2}\n' >>"$CDIR/$U1.jsonl"
  echo 1500000000 >"$FAKE_DOCKER_DIR/mtime.$U1.jsonl"
  run_history
  assert_eq "$(cat "$CDIR/$U1.jsonl")" "$(cat "$HDIR/$U1.jsonl")" "a resumed session is copied again"
}

test_history_keeps_a_copy_changed_on_the_host() {
  hist_setup
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  run_history
  printf '{"resumed":"on the host"}\n' >>"$HDIR/$U1.jsonl"
  local host
  host="$(cat "$HDIR/$U1.jsonl")"
  printf '{"n":2}\n' >>"$CDIR/$U1.jsonl"
  echo 1500000000 >"$FAKE_DOCKER_DIR/mtime.$U1.jsonl"
  run_history
  assert_eq "$host" "$(cat "$HDIR/$U1.jsonl")" "a copy changed on the host must not be overwritten"
  assert_contains "$(wrapper_log)" "changed on the host"
}

test_history_waits_for_a_transcript_still_being_written() {
  hist_setup
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  echo 1999999999 >"$FAKE_DOCKER_DIR/mtime.$U1.jsonl"
  FAKE_NOW=2000000000 run_history
  assert_file_missing "$HDIR/$U1.jsonl" "a file written seconds ago is not finished"
  FAKE_NOW=2000000100 run_history
  assert_file_exists "$HDIR/$U1.jsonl"
}

test_history_uses_claude_config_dir() {
  hist_setup
  printf '{"n":1}\n' >"$CDIR/$U1.jsonl"
  CLAUDE_CONFIG_DIR="$SANDBOX/claude-config" run_history
  assert_file_exists "$SANDBOX/claude-config/projects/$(basename "$HDIR")/$U1.jsonl"
  assert_file_missing "$HDIR/$U1.jsonl"
}

test_history_settings_are_validated() {
  local name
  name="claude-ide-box-my-project-$(sha8 "$PROJECT")"
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf 'COPY_HISTORY=yes\n' >"$HOME/.config/claude-ide-box/projects/$name.conf"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT"
  printf 'COPY_HISTORY=1\nCOPY_HISTORY_MAX_SIZE=lots\n' >"$HOME/.config/claude-ide-box/projects/$name.conf"
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "COPY_HISTORY_MAX_SIZE"
}

# The directory name Claude Code uses for a project in ~/.claude/projects.
# Expected values come from Claude Code 2.1.318's own function (non-alphanumeric
# UTF-16 code units become "-"; over 200 characters it is cut and a hash added).
test_history_project_directory_names() {
  # shellcheck source=lib/claude-ide-box/common.sh
  . "$REPO_DIR/lib/claude-ide-box/common.sh"
  # shellcheck source=lib/claude-ide-box/history.sh
  . "$REPO_DIR/lib/claude-ide-box/history.sh"
  local long
  long="/Users/piotr/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/very-long-directory-name/project"
  assert_eq "-Users-piotr-src-My-Project" "$(cb_claude_project_slug "/Users/piotr/src/My Project")"
  assert_eq "-home-u-Umowy-klient-w-2026---Za----" "$(cb_claude_project_slug "/home/u/Umowy klientów/2026 – Zażółć")"
  assert_eq "-tmp-x----y" "$(cb_claude_project_slug "/tmp/x 😀 y")"
  assert_eq "-Users-piotr-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-di-ecgeg0" \
    "$(cb_claude_project_slug "$long")"
  assert_eq "-Users-pi--very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-directory-name-very-long-dire-yk8rom" \
    "$(cb_claude_project_slug "/Users/pió/${long#/Users/piotr/}")"
}

# The script that lists and reads transcripts inside the container, run with
# the node on this machine.
node_or_skip() {
  if [ -z "${HOST_NODE:-}" ]; then
    printf '    SKIPPED: node is not installed here (the integration tests run it in the container)\n' >&2
    return 1
  fi
}

test_history_container_script_lists_types() {
  node_or_skip || return 0
  . "$REPO_DIR/lib/claude-ide-box/common.sh"
  . "$REPO_DIR/lib/claude-ide-box/history.sh"
  local d="$SANDBOX/t" out
  mkdir -p "$d/sub"
  printf 'abc\n' >"$d/$U1.jsonl"
  ln -s "$U1.jsonl" "$d/$U2.jsonl"
  mkfifo "$d/$U3.jsonl"
  printf 'x\n' >"$d/bad name;rm.jsonl"
  out="$("$HOST_NODE" -e "$(cb_history_node_script)" list "$d")"
  assert_contains "$out" "$(printf 'f\t4\t')"
  assert_contains "$out" "$(printf '\t%s.jsonl' "$U1")"
  assert_contains "$out" "$(printf 'l\t')"
  assert_contains "$out" "$(printf 'p\t0\t')"
  assert_contains "$out" "$(printf 'd\t')"
  assert_not_contains "$out" "bad name" "unsafe names are not printed"
  case "$out" in
    now*) ;;
    *) fail "the listing starts with the container's time: $out" ;;
  esac
  # A symlinked directory is not listed.
  ln -s "$d" "$SANDBOX/linked"
  out="$("$HOST_NODE" -e "$(cb_history_node_script)" list "$SANDBOX/linked")"
  assert_not_contains "$out" "$U1"
}

test_history_container_script_reads_only_regular_files() {
  node_or_skip || return 0
  . "$REPO_DIR/lib/claude-ide-box/common.sh"
  . "$REPO_DIR/lib/claude-ide-box/history.sh"
  local d="$SANDBOX/t" st out
  mkdir -p "$d"
  printf 'abc\n' >"$d/$U1.jsonl"
  ln -s "$U1.jsonl" "$d/$U2.jsonl"
  mkfifo "$d/$U3.jsonl"
  awk 'BEGIN { for (i = 0; i < 3000; i++) printf "x" }' >"$d/$U4.jsonl"
  out="$("$HOST_NODE" -e "$(cb_history_node_script)" read "$d/$U1.jsonl" 100)"
  assert_eq abc "$out"
  set +e
  "$HOST_NODE" -e "$(cb_history_node_script)" read "$d/$U2.jsonl" 100 >"$SANDBOX/o" 2>/dev/null
  st=$?
  set -e
  assert_nonzero "$st" "a symlink is refused"
  assert_eq "" "$(cat "$SANDBOX/o")"
  set +e
  # A FIFO would block a reader without O_NONBLOCK; the watchdog catches that.
  "$HOST_NODE" -e "$(cb_history_node_script)" read "$d/$U3.jsonl" 100 >"$SANDBOX/o" 2>/dev/null &
  local pid=$!
  (sleep 5; kill "$pid" 2>/dev/null) &
  wait "$pid"
  st=$?
  set -e
  assert_nonzero "$st" "a FIFO is refused"
  [ "$st" -lt 128 ] || fail "reading a FIFO hung"
  set +e
  "$HOST_NODE" -e "$(cb_history_node_script)" read "$d/$U4.jsonl" 1000 >"$SANDBOX/o" 2>/dev/null
  st=$?
  set -e
  assert_nonzero "$st" "a file over the limit is refused"
  assert_eq 0 "$(wc -c <"$SANDBOX/o" | tr -d ' ')"
}
