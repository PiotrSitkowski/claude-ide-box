#!/usr/bin/env bash
# Run the unit tests: every test_* function in tests/unit/test_*.sh.
# Usage: tests/run-unit.sh [FILTER]   (FILTER is a substring of test names)
set -euo pipefail

# Tests run with a minimal PATH; remember node for the login filter test.
TEST_NODE="$(command -v node 2>/dev/null || true)"
export TEST_NODE

TESTS_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
REPO_DIR="$(dirname "$TESTS_DIR")"
export TESTS_DIR REPO_DIR
filter="${1:-}"

passed=0
failed=0
failed_names=""

for file in "$TESTS_DIR"/unit/test_*.sh; do
  printf '%s\n' "$(basename "$file")"
  names="$(bash -c 'source "$1"; compgen -A function | grep "^test_"' _ "$file")"
  for name in $names; do
    case "$name" in
      *"$filter"*) ;;
      *) continue ;;
    esac
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/cb-unit.XXXXXX")"
    sandbox="$(cd -P "$sandbox" && pwd -P)"
    set +e
    (
      set -euo pipefail
      SANDBOX="$sandbox"
      export SANDBOX
      # shellcheck source=tests/lib.sh
      source "$TESTS_DIR/lib.sh"
      # shellcheck source=tests/unit/helpers.sh
      source "$TESTS_DIR/unit/helpers.sh"
      # shellcheck disable=SC1090 # test files are discovered at runtime
      source "$file"
      setup_sandbox
      "$name"
      exit "$T_FAILED"
    ) >"$sandbox.out" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      passed=$((passed + 1))
      printf '  ok    %s\n' "$name"
    else
      failed=$((failed + 1))
      failed_names="$failed_names $name"
      printf '  FAIL  %s\n' "$name"
      sed 's/^/        /' "$sandbox.out"
    fi
    rm -rf "$sandbox" "$sandbox.out"
  done
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  printf 'failed:%s\n' "$failed_names"
  exit 1
fi
