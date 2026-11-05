# shellcheck shell=bash
# shellcheck disable=SC2034 # T_FAILED is read by the test runner
# Minimal test harness in plain bash (runs on macOS bash 3.2 without extra
# dependencies). Each test file defines functions named test_*; run-unit.sh
# runs every one of them in a fresh subshell with a private sandbox.

T_FAILED=0

fail() {
  printf '    FAIL: %s\n' "$*" >&2
  T_FAILED=1
  return 1
}

assert_eq() {
  # assert_eq EXPECTED ACTUAL [MESSAGE]
  if [ "$1" != "$2" ]; then
    fail "${3:-values differ}"$'\n'"      expected: $(printf '%q' "$1")"$'\n'"      actual:   $(printf '%q' "$2")"
  fi
}

assert_contains() {
  # assert_contains HAYSTACK NEEDLE [MESSAGE]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-missing text}: expected to find $(printf '%q' "$2") in"$'\n'"$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-unexpected text}: did not expect $(printf '%q' "$2") in"$'\n'"$1" ;;
  esac
}

assert_file_exists() {
  [ -e "$1" ] || [ -L "$1" ] || fail "${2:-file missing}: $1"
}

assert_file_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "${2:-file should not exist}: $1"
  fi
}

assert_status() {
  # assert_status EXPECTED ACTUAL [MESSAGE]
  if [ "$1" != "$2" ]; then
    fail "${3:-exit status}: expected $1, got $2"
  fi
}

assert_nonzero() {
  if [ "$1" = "0" ]; then
    fail "${2:-expected a non-zero exit status}"
  fi
}
