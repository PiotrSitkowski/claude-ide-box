# shellcheck shell=bash
# Unit tests of bin/pii-airgap with a fake docker on PATH.

test_scan_runs_an_isolated_container() {
  make_project "$T/proj"
  out="$(cd "$T/proj" && pa scan)" || fail "scan failed: $out"
  run="$(docker_runs)"
  assert_eq "$(printf '%s\n' "$run" | wc -l | tr -d ' ')" 1 "one container"
  assert_contains "$run" "|--rm|"
  assert_contains "$run" "|--network|none|"
  assert_contains "$run" "|--read-only|"
  assert_contains "$run" "|--cap-drop|ALL|"
  assert_contains "$run" "|--security-opt|no-new-privileges|"
  assert_contains "$run" "|--user|$(id -u):$(id -g)|"
  assert_contains "$run" "type=bind,src=$T/proj,dst=$T/proj,readonly"
  assert_contains "$run" "|scan|$T/proj"
  assert_not_contains "$run" "docker.sock"
  assert_not_contains "$run" "src=$HOME,"
  assert_not_contains "$run" "$HOME/.local/state"
}

test_scan_mounts_cache_and_lists() {
  make_project "$T/proj"
  mkdir -p "$XDG_CONFIG_HOME/pii-airgap/lists"
  printf 'CLIENT: Acme\n' >"$XDG_CONFIG_HOME/pii-airgap/lists/clients.txt"
  pa scan "$T/proj" >/dev/null || fail "scan failed"
  run="$(docker_runs)"
  assert_contains "$run" "type=bind,src=$XDG_CONFIG_HOME/pii-airgap/lists,dst=/lists,readonly"
  assert_contains "$run" "|--lists|/lists/clients.txt"
  assert_contains "$run" "type=bind,src=$XDG_CACHE_HOME/pii-airgap/scan,dst=/cache"
  [ -d "$XDG_CACHE_HOME/pii-airgap/scan" ] || fail "cache dir not created"
}

test_scan_passes_options_and_output_through() {
  make_project "$T/proj"
  out="$(FAKE_DOCKER_RUN_OUT='{"files": []}' pa scan "$T/proj" --json --fail-on-pii --min-confidence 0.8)"
  assert_eq "$out" '{"files": []}'
  assert_contains "$(docker_runs)" "|scan|$T/proj|--json|--fail-on-pii|--min-confidence|0.8"
}

test_scan_status_is_the_containers() {
  make_project "$T/proj"
  set +e
  FAKE_DOCKER_FAIL_RUN=1 pa scan "$T/proj" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" 3
}

test_lists_inside_the_scanned_folder_are_refused() {
  make_project "$T/proj"
  set +e
  out="$(PII_AIRGAP_LISTS="$T/proj/lists" pa scan "$T/proj" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "accepted lists inside the project"
  assert_contains "$out" "outside"
  assert_eq "$(docker_runs)" ""
}

test_fails_closed_without_daemon_or_image() {
  make_project "$T/proj"
  set +e
  out="$(FAKE_DOCKER_DOWN=1 pa scan "$T/proj" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ran without a daemon"
  assert_contains "$out" "not running"
  set +e
  out="$(FAKE_DOCKER_NO_IMAGE=1 pa scan "$T/proj" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ran without the image"
  assert_contains "$out" "pii-airgap build"
  assert_eq "$(docker_runs)" ""
}

test_paths_that_mount_options_cannot_express_are_refused() {
  mkdir -p "$T/a,b"
  set +e
  out="$(pa scan "$T/a,b" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "accepted a comma"
  assert_eq "$(docker_runs)" ""
}

test_rootless_podman_keeps_the_user_id() {
  make_project "$T/proj"
  PII_AIRGAP_DOCKER=docker FAKE_DOCKER_PODMAN=1 FAKE_DOCKER_ROOTLESS=true pa scan "$T/proj" >/dev/null
  assert_contains "$(docker_runs)" "|--userns=keep-id|"
}

# ---------------------------------------------------------------- masks

test_mask_add_writes_the_claude_ide_box_project_config() {
  make_project "$T/proj"
  mkdir -p "$T/proj/docs"
  : >"$T/proj/docs/umowa.docx"
  : >"$T/proj/b.pdf"
  (cd "$T/proj" && pa mask-add docs/umowa.docx ./b.pdf) || fail "mask-add failed"
  conf="$XDG_CONFIG_HOME/claude-ide-box/projects/$(cib_name "$T/proj").conf"
  [ -f "$conf" ] || fail "no $conf"
  assert_eq "$(cat "$conf")" 'MASK="docs/umowa.docx b.pdf"'
  [ ! -e "$T/proj/.claude-ide-box" ] || fail "wrote into the project"
}

test_mask_add_keeps_other_settings_and_does_not_duplicate() {
  make_project "$T/proj"
  conf="$XDG_CONFIG_HOME/claude-ide-box/projects/$(cib_name "$T/proj").conf"
  mkdir -p "$(dirname "$conf")"
  printf '# mine\nPROFILE="office"\nMASK="secret.txt"\n' >"$conf"
  : >"$T/proj/x.pdf"
  pa mask-add --project "$T/proj" x.pdf secret.txt >/dev/null
  pa mask-add --project "$T/proj" x.pdf >/dev/null
  assert_eq "$(cat "$conf")" "$(printf '# mine\nPROFILE="office"\nMASK="secret.txt x.pdf"')"
}

test_mask_add_refuses_unsafe_paths() {
  make_project "$T/proj"
  : >"$T/outside.txt"
  : >"$T/proj/with space.txt"
  : >"$T/proj/star*.txt"
  for p in ../outside.txt "$T/outside.txt" "with space.txt" "star*.txt" missing.txt; do
    set +e
    out="$(cd "$T/proj" && pa mask-add "$p" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "accepted $p"
  done
  [ ! -e "$XDG_CONFIG_HOME/claude-ide-box/projects" ] || [ -z "$(ls "$XDG_CONFIG_HOME/claude-ide-box/projects")" ] ||
    fail "wrote a config"
}

test_container_name_matches_claude_ide_box() {
  src="${CLAUDE_IDE_BOX_SRC:-}"
  [ -n "$src" ] && [ -f "$src/lib/claude-ide-box/common.sh" ] || { echo "CLAUDE_IDE_BOX_SRC not set"; return 77; }
  for d in "$T/My Project.v2" "$T/__x__" "$T/Zażółć" "$T/$(printf 'a%.0s' $(seq 1 60))"; do
    mkdir -p "$d"
    want="$(bash -c '. "$1/lib/claude-ide-box/common.sh" >/dev/null 2>&1; cb_container_name "$2"' _ "$src" "$d")"
    got="$(pa container-name --project "$d")"
    assert_eq "$got" "$want" "$d"
  done
}

# ---------------------------------------------------------------- try

make_try() {
  make_project "$T/proj"
  name="$(cib_name "$T/proj")"
  TRY_ROOT="$XDG_CACHE_HOME/claude-ide-box/try/$name"
  mkdir -p "$TRY_ROOT/work" "$TRY_ROOT/base"
  MAP="$XDG_STATE_HOME/pii-airgap/try/$name.map.json"
}

test_try_prepare_scans_then_pseudonymises() {
  make_try
  FAKE_DOCKER_RUN_OUT='{"files": []}' pa try-prepare "$T/proj" >/dev/null || fail "try-prepare failed"
  runs="$(docker_runs)"
  assert_eq "$(printf '%s\n' "$runs" | wc -l | tr -d ' ')" 2
  first="$(printf '%s\n' "$runs" | sed -n 1p)"
  second="$(printf '%s\n' "$runs" | sed -n 2p)"
  assert_contains "$first" "type=bind,src=$TRY_ROOT/work,dst=$T/proj,readonly"
  assert_contains "$first" "|scan|$T/proj|--json"
  assert_not_contains "$first" "pii-airgap/try"
  assert_contains "$second" "|--network|none|"
  assert_contains "$second" "type=bind,src=$TRY_ROOT/work,dst=$T/proj|"
  assert_contains "$second" "type=bind,src=$XDG_STATE_HOME/pii-airgap/try,dst=/state|"
  assert_contains "$second" "dst=/report.json,readonly"
  assert_contains "$second" "|anonymise|$T/proj|--map|/state/$name.map.json|--git|strip|--scan-report|/report.json"
  # shellcheck disable=SC2012 # only the mode string of one known directory
  perm="$(ls -ld "$XDG_STATE_HOME/pii-airgap/try" | cut -c1-10)"
  assert_eq "$perm" "drwx------"
  case "$MAP" in "$TRY_ROOT"/*) fail "map inside the try root" ;; esac
}

test_try_prepare_stops_when_the_scan_fails() {
  make_try
  set +e
  FAKE_DOCKER_FAIL_RUN=1 pa try-prepare "$T/proj" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "continued"
  assert_eq "$(docker_runs | wc -l | tr -d ' ')" 1
}

test_try_prepare_refusal_status_passes_through() {
  make_try
  set +e
  out="$(FAKE_DOCKER_RUN_OUT='{}' FAKE_DOCKER_FAIL_RUN=2 pa try-prepare "$T/proj" 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" 3
  assert_contains "$out" "mask-add"
}

test_try_commands_need_a_try_copy() {
  make_project "$T/proj"
  for c in try-prepare try-restore; do
    set +e
    out="$(pa "$c" "$T/proj" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$c ran without a try copy"
    assert_contains "$out" "up --try"
  done
  assert_eq "$(docker_runs)" ""
}

test_try_restore_mounts_map_read_only_and_base() {
  make_try
  mkdir -p "$(dirname "$MAP")"
  printf '{}' >"$MAP"
  pa try-restore "$T/proj" --keep-unresolved >/dev/null || fail "try-restore failed"
  run="$(docker_runs)"
  assert_contains "$run" "type=bind,src=$TRY_ROOT/work,dst=$T/proj|"
  assert_contains "$run" "type=bind,src=$TRY_ROOT/base,dst=/base,readonly"
  assert_contains "$run" "type=bind,src=$XDG_STATE_HOME/pii-airgap/try,dst=/state,readonly"
  assert_contains "$run" "|restore|$T/proj|--map|/state/$(cib_name "$T/proj").map.json|--base|/base|--keep-unresolved"
}

test_try_restore_without_a_map_fails() {
  make_try
  set +e
  out="$(pa try-restore "$T/proj" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "restored without a map"
  assert_contains "$out" "no token map"
}

test_try_forget_removes_the_map() {
  make_try
  mkdir -p "$(dirname "$MAP")"
  printf '{}' >"$MAP"
  pa try-forget "$T/proj" >/dev/null
  [ ! -e "$MAP" ] || fail "map still there"
}

test_system_prompt_is_printed_by_the_image() {
  out="$(FAKE_DOCKER_RUN_OUT='prompt text' pa system-prompt)"
  assert_eq "$out" "prompt text"
  assert_contains "$(docker_runs)" "|--network|none|"
}

test_unknown_command_and_help() {
  set +e
  pa frobnicate >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" 2
  out="$(pa help)"
  assert_contains "$out" "scan"
  assert_contains "$out" "not a compliance"
}
