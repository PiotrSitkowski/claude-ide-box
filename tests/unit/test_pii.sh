# shellcheck shell=bash
# Unit tests for the check of pseudonymised copies recorded by pii-airgap:
# no container starts in a copy that holds values of its token map in clear
# text (for example after `pii-airgap restore --in-place`).

# pii_record COPY [MAP] - write the record `pii-airgap anonymise` leaves in
# its state directory, with the map's fingerprint.
pii_record() {
  local copy="$1" map="${2:-$SANDBOX/private/map.json}" dir sum
  dir="$XDG_STATE_HOME/pii-airgap/copies"
  mkdir -p "$dir" "$(dirname "$map")"
  [ -f "$map" ] || printf '{"format":"pii-airgap-map/1","tokens":{"[PESEL_1]":"x"}}\n' >"$map"
  sum="$(file_sha "$map")"
  {
    echo "# pii-airgap: pseudonymised copy. Claude IDE Box checks it before every start."
    echo "path=$copy"
    echo "physical=$(cd -P "$copy" && pwd -P)"
    echo "map=$map"
    echo "map_sha256=$sum"
    echo "image=pii-airgap:latest"
  } >"$dir/$(sha8 "$copy").copy"
}

file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -c1-64
  else
    shasum -a 256 <"$1" | cut -c1-64
  fi
}

calls() {
  cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true
}

assert_not_started() {
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT" "stdout must stay empty"
  assert_not_contains "$(calls)" "run -d" "no project container may be created"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.args" "claude must not be started"
}

test_pii_no_record_no_check() {
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/verify.args"
}

# The case from the manual test: anonymise, restore in place, open the copy.
test_pii_restored_copy_is_refused() {
  pii_record "$PROJECT"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='umowa.txt\t3\nnotes/a.md\t1\n' run_wrapper --output-format stream-json
  assert_not_started
  assert_contains "$ERR" "pseudonymised copy"
  assert_contains "$ERR" "umowa.txt"
  assert_contains "$ERR" "notes/a.md"
  assert_contains "$ERR" "--out"
}

test_pii_clean_copy_starts_after_an_isolated_check() {
  pii_record "$PROJECT"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
  local v
  v="$(tr '\n' ' ' <"$FAKE_DOCKER_DIR/verify.args")"
  assert_contains "$v" "--rm"
  assert_contains "$v" "--network none"
  assert_contains "$v" "--read-only"
  assert_contains "$v" "--cap-drop ALL"
  assert_contains "$v" "--security-opt no-new-privileges"
  assert_contains "$v" "type=bind,src=$PROJECT,dst=/copy,readonly"
  assert_contains "$v" "type=bind,src=$SANDBOX/private/map.json,dst=/map.json,readonly"
  assert_contains "$v" "pii-airgap:latest verify /copy --map /map.json"
  assert_not_contains "$(run_args)" "map.json" "the map never reaches the project container"
  assert_not_contains "$(run_args)" "pii-airgap"
}

test_pii_project_inside_a_copy_is_checked() {
  pii_record "$SANDBOX/work"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='My Project/a.txt\t1\n' run_wrapper --version
  assert_not_started
  assert_contains "$(cat "$FAKE_DOCKER_DIR/verify.args")" "src=$SANDBOX/work,dst=/copy,readonly"
}

test_pii_copy_inside_the_project_is_checked() {
  mkdir -p "$PROJECT/clients/copy"
  pii_record "$PROJECT/clients/copy"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='a.txt\t1\n' run_wrapper --version
  assert_not_started
}

test_pii_unrelated_and_vanished_copies_are_ignored() {
  mkdir -p "$SANDBOX/elsewhere" "$SANDBOX/gone"
  pii_record "$SANDBOX/elsewhere"
  pii_record "$SANDBOX/gone"
  rmdir "$SANDBOX/gone"
  mkdir -p "$PROJECT/gone-not"
  FAKE_PII_VERIFY_STATUS=5 run_wrapper --version
  assert_status 0 "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/verify.args"
}

test_pii_missing_map_refuses() {
  pii_record "$PROJECT"
  rm -f "$SANDBOX/private/map.json"
  run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "token map"
  assert_contains "$ERR" "forget-copy"
}

test_pii_replaced_map_refuses() {
  pii_record "$PROJECT"
  printf '{"format":"pii-airgap-map/1","tokens":{}}\n' >"$SANDBOX/private/map.json"
  run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "changed"
  assert_file_missing "$FAKE_DOCKER_DIR/verify.args" "an emptied map must not be used for the check"
}

test_pii_failed_check_refuses() {
  pii_record "$PROJECT"
  FAKE_PII_VERIFY_STATUS=1 run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "could not check"
}

test_pii_file_names_from_the_copy_are_shown_safely() {
  pii_record "$PROJECT"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='evil\033]0;x\007.txt\t1\n' run_wrapper --version
  assert_not_started
  case "$ERR" in
    *"$(printf '\033')"*) fail "a control character from a file name reached the terminal" ;;
  esac
}

test_pii_up_is_refused_too() {
  pii_record "$PROJECT"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='a.txt\t1\n' run_cli up
  assert_nonzero "$STATUS"
  assert_not_contains "$(calls)" "run -d"
  assert_contains "$ERR" "pseudonymised copy"
}

test_pii_restored_folder_is_refused() {
  mkdir -p "$SANDBOX/restored"
  pii_record "$SANDBOX/restored"
  printf 'kind=restored\n' >>"$XDG_STATE_HOME/pii-airgap/copies/$(sha8 "$SANDBOX/restored").copy"
  FAKE_PII_VERIFY_STATUS=5 FAKE_PII_VERIFY_OUT='umowa.txt\t3\n' RUN_DIR="$SANDBOX/restored" run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "restored from a pseudonymised copy"
}
