#!/bin/bash
# Run every test_* function in tests/unit/test_*.sh, each in a fresh subshell
# with a private HOME and a fake docker first on PATH.
#   tests/run-unit.sh [name-filter]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FILTER="${1:-}"
pass=0
fail=0
skip=0
failed=""

for file in "$TESTS_DIR"/unit/test_*.sh; do
  names="$(grep -E '^test_[a-z0-9_]+\(\)' "$file" | sed 's/().*//')"
  for t in $names; do
    case "$t" in *"$FILTER"*) ;; *) continue ;; esac
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pii-airgap-test.XXXXXX")"
    set +e
    out="$(
      export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_CACHE_HOME="$tmp/home/.cache"
      export XDG_STATE_HOME="$tmp/home/.local/state" T="$tmp" ROOT
      export PATH="$TESTS_DIR/unit/fake-bin:$PATH" FAKE_DOCKER_LOG="$tmp/docker.log"
      exec 2>&1
      unset PII_AIRGAP_DOCKER CLAUDE_IDE_BOX_INSTANCE
      mkdir -p "$HOME"
      cd "$tmp" || exit 1
      # shellcheck source=/dev/null
      . "$TESTS_DIR/unit/helpers.sh"
      # shellcheck source=/dev/null
      . "$file"
      set -e
      "$t"
    )" 2>&1
    rc=$?
    set -e
    rm -rf "$tmp"
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
    elif [ "$rc" -eq 77 ]; then
      skip=$((skip + 1))
      printf 'SKIP %s: %s\n' "$t" "$(printf '%s\n' "$out" | tail -n 1)"
    else
      fail=$((fail + 1))
      failed="$failed $t"
      printf 'FAIL %s\n%s\n' "$t" "$out" | sed 's/^/  /'
    fi
  done
done
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || { printf 'failed:%s\n' "$failed"; exit 1; }
