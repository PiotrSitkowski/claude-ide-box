# shellcheck shell=bash
# The integration suite must never pass silently without Docker.

test_integration_skips_loudly_without_docker() {
  set +e
  OUT="$(FAKE_DOCKER_DOWN=1 bash "$REPO_DIR/tests/integration/run.sh" 2>&1)"
  STATUS=$?
  set -e
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "INTEGRATION TESTS SKIPPED"
  assert_contains "$OUT" "Nothing was verified"
}

test_integration_fails_without_docker_when_required() {
  set +e
  OUT="$(FAKE_DOCKER_DOWN=1 CLAUDE_BOX_REQUIRE_DOCKER=1 bash "$REPO_DIR/tests/integration/run.sh" 2>&1)"
  STATUS=$?
  set -e
  assert_nonzero "$STATUS"
}
