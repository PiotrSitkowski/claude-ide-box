# shellcheck shell=bash
# Unit tests for the pii-airgap hooks: 'pii' passthrough and pseudonymised
# try sessions ('up --try --pseudonymise'). A fake pii-airgap records its
# calls in the same log as the fake docker, so the order can be checked.

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }
base_name() { printf 'claude-ide-box-my-project-%s\n' "$(sha8 "$PROJECT")"; }
try_root() { printf '%s/.cache/claude-ide-box/try/%s\n' "$HOME" "$(base_name)"; }
work() { printf '%s/work\n' "$(try_root)"; }

fake_pii() {
  cat >"$SANDBOX/bin/pii-airgap" <<'EOS'
#!/bin/sh
printf 'pii %s\n' "$*" >>"$FAKE_DOCKER_DIR/calls"
case "$1" in
  try-prepare)
    [ "${FAKE_PII_FAIL:-}" != prepare ] || { echo "refusing: docs/umowa.docx holds PII" >&2; exit 3; } ;;
  try-restore)
    [ "${FAKE_PII_FAIL:-}" != restore ] || { echo "src/a.txt:1: altered token [person_1]" >&2; exit 4; } ;;
  system-prompt) printf 'Keep [TYPE_N] tokens exactly.\n' ;;
  scan) echo "scanned $2" ;;
esac
exit 0
EOS
  chmod +x "$SANDBOX/bin/pii-airgap"
}

pii_fixture() {
  fake_pii
  printf 'a\n' >"$PROJECT/a.txt"
  mkdir -p "$PROJECT/.git"
  printf '[core]\n' >"$PROJECT/.git/config"
}

# line number of the first call matching PATTERN in the call log
call_line() {
  calls | grep -n -- "$1" | head -n 1 | cut -d: -f1
}

test_pii_command_passes_through_to_pii_airgap() {
  fake_pii
  run_cli pii scan --json
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(calls)" "pii scan --json"
}

test_pii_command_without_pii_airgap_fails_clearly() {
  run_cli pii scan
  assert_status 1 "$STATUS"
  assert_contains "$ERR" "pii-airgap"
}

test_pseudonymised_try_prepares_the_copy_before_the_container_starts() {
  pii_fixture
  run_cli up --try --pseudonymise
  assert_status 0 "$STATUS" "$ERR"
  local prep run
  prep="$(call_line "pii try-prepare $PROJECT")"
  run="$(call_line "^run ")"
  [ -n "$prep" ] || fail "try-prepare not called"
  [ -n "$run" ] || fail "container not started"
  [ "$prep" -lt "$run" ] || fail "container started before the copy was pseudonymised"
  assert_eq "tokens" "$(cat "$(try_root)/pii")"
  assert_eq "Keep [TYPE_N] tokens exactly." "$(cat "$(try_root)/pii-prompt")"
}

test_failed_prepare_starts_nothing_and_removes_the_copy() {
  pii_fixture
  FAKE_PII_FAIL=prepare run_cli up --try --pseudonymise
  [ "$STATUS" -ne 0 ] || fail "up succeeded"
  assert_contains "$ERR" "docs/umowa.docx"
  assert_not_contains "$(calls)" "run "
  assert_file_missing "$(try_root)"
  rm -f "$FAKE_DOCKER_DIR/state"
  run_wrapper --version
  assert_eq "$(base_name)" "$(cat "$FAKE_DOCKER_DIR/exec.name")" "no try session left behind"
}

test_pseudonymise_needs_pii_airgap() {
  printf 'a\n' >"$PROJECT/a.txt"
  run_cli up --try --pseudonymise
  [ "$STATUS" -ne 0 ] || fail "up succeeded without pii-airgap"
  assert_contains "$ERR" "pii-airgap"
  assert_not_contains "$(calls)" "run "
  assert_file_missing "$(try_root)"
}

test_pseudonymise_requires_try() {
  pii_fixture
  run_cli up --pseudonymise
  [ "$STATUS" -ne 0 ] || fail "accepted --pseudonymise without --try"
  assert_not_contains "$(calls)" "pii "
}

test_wrapper_appends_the_token_instructions_to_chat_sessions_only() {
  pii_fixture
  run_cli up --try --pseudonymise
  run_wrapper --output-format stream-json --verbose --input-format stream-json
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(exec_args)" "--append-system-prompt Keep [TYPE_N] tokens exactly."
  run_wrapper --version
  assert_not_contains "$(exec_args)" "--append-system-prompt"
}

test_plain_try_session_gets_no_token_instructions() {
  pii_fixture
  run_cli up --try
  run_wrapper --output-format stream-json --input-format stream-json
  assert_not_contains "$(exec_args)" "--append-system-prompt"
  assert_not_contains "$(calls)" "pii "
}

test_apply_restores_real_values_after_stopping_the_container() {
  pii_fixture
  run_cli up --try --pseudonymise
  printf 'changed\n' >"$(work)/a.txt"
  run_cli try apply
  assert_status 0 "$STATUS" "$ERR"
  local stop restore
  stop="$(call_line "rm -f $(base_name)-try")"
  restore="$(call_line "pii try-restore $PROJECT")"
  [ -n "$restore" ] || fail "try-restore not called"
  [ "$stop" -lt "$restore" ] || fail "restored while the container could still run"
  assert_eq "changed" "$(cat "$PROJECT/a.txt")"
  assert_contains "$(calls)" "pii try-forget $PROJECT"
}

test_failed_restore_applies_nothing() {
  pii_fixture
  run_cli up --try --pseudonymise
  printf 'changed\n' >"$(work)/a.txt"
  FAKE_PII_FAIL=restore run_cli try apply
  [ "$STATUS" -ne 0 ] || fail "apply succeeded"
  assert_contains "$ERR" "altered token"
  assert_eq "a" "$(cat "$PROJECT/a.txt")"
  assert_file_exists "$(work)/a.txt"
  assert_eq "tokens" "$(cat "$(try_root)/pii")"
}

test_restored_copy_is_never_mounted_until_pseudonymised_again() {
  pii_fixture
  run_cli up --try --pseudonymise
  run_cli try diff
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(calls)" "pii try-restore $PROJECT"
  assert_eq "restored" "$(cat "$(try_root)/pii")"
  : >"$FAKE_DOCKER_DIR/calls"
  rm -f "$FAKE_DOCKER_DIR/state"
  run_wrapper --output-format stream-json --input-format stream-json
  [ "$STATUS" -ne 0 ] || fail "the wrapper started a session on the restored copy"
  assert_not_contains "$(calls)" "run "
  assert_not_contains "$(calls)" "exec "
  run_cli up
  [ "$STATUS" -ne 0 ] || fail "up started the restored copy"
  assert_not_contains "$(calls)" "run "
  run_cli up --try
  assert_status 0 "$STATUS" "$ERR"
  local prep run
  prep="$(call_line "pii try-prepare $PROJECT")"
  run="$(call_line "^run ")"
  [ -n "$prep" ] && [ -n "$run" ] && [ "$prep" -lt "$run" ] || fail "resume did not pseudonymise first"
  assert_eq "tokens" "$(cat "$(try_root)/pii")"
}

test_plain_session_cannot_be_pseudonymised_later() {
  pii_fixture
  run_cli up --try
  run_cli up --try --pseudonymise
  [ "$STATUS" -ne 0 ] || fail "pseudonymised a session the agent already saw in clear text"
  assert_contains "$ERR" "discard"
}

test_discard_forgets_the_token_map() {
  pii_fixture
  run_cli up --try --pseudonymise
  run_cli try discard
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(calls)" "pii try-forget $PROJECT"
  assert_file_missing "$(try_root)"
}
