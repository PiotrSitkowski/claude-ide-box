# shellcheck shell=bash
# Unit tests for the personal-data scan before a project container is
# created: when pii-airgap is installed, a project in which it finds personal
# data does not start until the files are masked, the project is replaced by
# a pseudonymised copy, or the user accepts it for this project.

# fake_scanner - a pii-airgap on PATH that prints a scan report in its text
# format. FAKE_SCAN_FILES holds "RELPATH|METHOD|TYPES" lines; every file gets
# a detail line with a value that must never be shown. FAKE_SCAN_RAW is
# printed as it is first (a printf format).
# FAKE_SCAN_STATUS, FAKE_SCAN_SLEEP and FAKE_SCAN_STDERR change how it ends.
fake_scanner() {
  cat >"$SANDBOX/bin/pii-airgap" <<'EOS'
#!/usr/bin/env bash
printf 'pii-airgap %s\n' "$*" >>"$FAKE_DOCKER_DIR/calls"
[ "$1" = scan ] || exit 0
dir="$2"
[ -z "${FAKE_SCAN_SLEEP:-}" ] || sleep "$FAKE_SCAN_SLEEP"
# shellcheck disable=SC2059 # the test passes the format
[ -z "${FAKE_SCAN_RAW:-}" ] || printf "$FAKE_SCAN_RAW"
n=0
while IFS='|' read -r rel method types; do
  [ -n "$rel" ] || continue
  # paths relative to the scanned directory, as pii-airgap prints them
  printf '%s  [%s]  %s\n' "$rel" "$method" "$types"
  printf '    line 1     PESEL      0.95   pesel     VALUE-NEVER-SHOWN\n'
  n=$((n + 1))
done <<EOF
${FAKE_SCAN_FILES:-}
EOF
printf '%d file(s) scanned, %d with PII, %d finding(s), 0 from cache, 0 not scanned\n' 3 "$n" "$n"
[ -z "${FAKE_SCAN_STDERR:-}" ] || printf '%s\n' "$FAKE_SCAN_STDERR" >&2
exit "${FAKE_SCAN_STATUS:-0}"
EOS
  chmod +x "$SANDBOX/bin/pii-airgap"
}

calls() {
  cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true
}

global_config() {
  mkdir -p "$HOME/.config/claude-ide-box"
  printf '%s\n' "$1" >>"$HOME/.config/claude-ide-box/config"
}

scans() {
  grep -c '^pii-airgap scan' "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true
}

project_conf() {
  printf '%s/.config/claude-ide-box/projects/claude-ide-box-my-project-%s.conf\n' "$HOME" "$(sha8 "$PROJECT")"
}

assert_not_started() {
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT" "stdout must stay empty"
  assert_not_contains "$(calls)" "run -d" "no project container may be created"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.args" "claude must not be started"
}

PII_FILES='notes/client.txt|text|PESEL x1, PERSON x2
data/customers.csv|text|EMAIL x40, PERSON x40
contracts/umowa.docx|docx|IBAN x1, PERSON x3'

test_pii_scan_without_pii_airgap_changes_nothing() {
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_not_contains "$ERR" "pii-airgap"
  assert_not_contains "$(calls)" "pii-airgap"
}

test_pii_scan_refuses_a_project_with_personal_data() {
  fake_scanner
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --output-format stream-json
  assert_not_started
  assert_contains "$ERR" "personal data"
  assert_contains "$ERR" "notes/client.txt: PESEL x1, PERSON x2"
  assert_contains "$ERR" "data/customers.csv: EMAIL x40, PERSON x40"
  assert_contains "$ERR" "contracts/umowa.docx: IBAN x1, PERSON x3"
  assert_not_contains "$ERR" "VALUE-NEVER-SHOWN"
  assert_not_contains "$ERR" "$PROJECT/notes"
  # the three ways out
  assert_contains "$ERR" "pii-airgap mask-add"
  assert_contains "$ERR" "pseudonymised copy"
  assert_contains "$ERR" "claude-ide-box pii-scan accept"
}

test_pii_scan_reads_the_project_with_the_configured_confidence() {
  fake_scanner
  # By default a model's guess alone (0.75) does not stop a start.
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "pii-airgap scan $PROJECT --min-confidence 0.8"
  rm -f "$FAKE_DOCKER_DIR/state"
  mkdir -p "$(dirname "$(project_conf)")"
  printf 'PII_SCAN_MIN_CONFIDENCE=0\n' >"$(project_conf)"
  run_wrapper --version
  assert_contains "$(calls)" "pii-airgap scan $PROJECT --min-confidence 0"
}

test_pii_scan_clean_project_starts_and_is_not_scanned_again() {
  fake_scanner
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq 1 "$(scans)"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq 1 "$(scans)" "an existing container is started without a new scan"
}

test_pii_scan_runs_again_when_the_container_is_created_again() {
  fake_scanner
  run_wrapper --version
  assert_eq 1 "$(scans)"
  rm -f "$FAKE_DOCKER_DIR/state" "$FAKE_DOCKER_DIR/calls" "$FAKE_DOCKER_DIR/exec.args"
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --version
  assert_not_started
  assert_eq 1 "$(scans)" "a new container needs a new scan"
}

test_pii_scan_ignores_masked_files() {
  fake_scanner
  mkdir -p "$PROJECT/contracts"
  : >"$PROJECT/contracts/umowa.docx"
  mkdir -p "$(dirname "$(project_conf)")"
  printf 'MASK="contracts/umowa.docx"\n' >"$(project_conf)"
  FAKE_SCAN_FILES='contracts/umowa.docx|docx|IBAN x1' run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "run -d"
}

test_pii_scan_off() {
  fake_scanner
  global_config 'PII_SCAN=0'
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq 0 "$(scans)"
}

test_pii_scan_accept_is_recorded_outside_the_project() {
  fake_scanner
  FAKE_SCAN_FILES="$PII_FILES" run_cli pii-scan accept
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$(project_conf)")" "PII_ACCEPTED"
  assert_eq "" "$(ls -A "$PROJECT")" "nothing is written into the project"
  assert_contains "$OUT$ERR" "sent to"
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --version
  assert_status 0 "$STATUS"
  assert_contains "$(calls)" "run -d"
  run_cli pii-scan reset
  assert_status 0 "$STATUS"
  rm -f "$FAKE_DOCKER_DIR/state" "$FAKE_DOCKER_DIR/calls" "$FAKE_DOCKER_DIR/exec.args"
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --version
  assert_not_started
}

test_pii_scan_acceptance_cannot_come_from_the_global_config() {
  fake_scanner
  global_config 'PII_ACCEPTED=1'
  FAKE_SCAN_FILES="$PII_FILES" run_wrapper --version
  assert_not_started
}

test_pii_scan_command_shows_the_report_in_a_terminal() {
  fake_scanner
  FAKE_SCAN_FILES="$PII_FILES" run_cli pii-scan
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "notes/client.txt: PESEL x1, PERSON x2"
  assert_not_contains "$OUT$ERR" "VALUE-NEVER-SHOWN"
  run_cli pii-scan
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "No personal data found"
}

test_pii_scan_that_takes_too_long_refuses_with_a_message() {
  fake_scanner
  global_config 'PII_SCAN_TIMEOUT=1'
  local start end
  start="$(date +%s)"
  FAKE_SCAN_SLEEP=20 run_wrapper --output-format stream-json
  end="$(date +%s)"
  assert_not_started
  assert_contains "$ERR" "did not finish"
  assert_contains "$ERR" "claude-ide-box pii-scan"
  [ $((end - start)) -lt 10 ] || fail "the panel waited $((end - start)) s for a 1 s limit"
}

test_pii_scan_that_fails_refuses() {
  fake_scanner
  FAKE_SCAN_STATUS=1 FAKE_SCAN_STDERR="pii-airgap: image pii-airgap:latest not found - run 'pii-airgap build'" run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "pii-airgap build"
}

test_pii_scan_also_guards_up() {
  fake_scanner
  FAKE_SCAN_FILES="$PII_FILES" run_cli up
  assert_nonzero "$STATUS"
  assert_not_contains "$(calls)" "run -d"
  assert_contains "$ERR" "notes/client.txt"
}

test_pii_scan_file_names_reach_the_terminal_printable_only() {
  fake_scanner
  FAKE_SCAN_FILES="$(printf 'evil\033]0;x\007.txt|text|EMAIL x1')" run_wrapper --version
  assert_not_started
  case "$ERR" in
    *"$(printf '\033')"* | *"$(printf '\007')"*) fail "control characters reached the terminal" ;;
  esac
}

test_pii_scan_settings_are_validated() {
  global_config 'PII_SCAN_TIMEOUT=soon'
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "PII_SCAN_TIMEOUT"
}

test_pii_scan_report_that_cannot_be_read_refuses() {
  # A file name with a line break splits its report line; the part with the
  # finding must not slip through as a detail line.
  fake_scanner
  FAKE_SCAN_RAW='evil\n    [text]  EMAIL x1\n' run_wrapper --version
  assert_not_started
  assert_contains "$ERR" "report"
}
