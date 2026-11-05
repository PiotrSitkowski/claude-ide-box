# shellcheck shell=bash
# Assertions for the unit tests. Each prints a reason and returns non-zero.

fail() {
  printf 'assertion failed: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$2], got [$1]${3:+ ($3)}"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "[$2] not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "[$2] unexpectedly found in: $1" ;;
  esac
}

# Calls to the fake docker, one per line, arguments separated by '|'.
docker_calls() {
  [ -f "$FAKE_DOCKER_LOG" ] && cat "$FAKE_DOCKER_LOG" || true
}

docker_runs() {
  docker_calls | grep '^run|' || true
}

pa() {
  "$BASH" "$ROOT/bin/pii-airgap" "$@"
}

make_project() {
  mkdir -p "$1"
  printf 'Jan Kowalski\n' >"$1/a.txt"
}

# The container name claude-ide-box gives a project directory, computed
# independently with sha256sum/shasum.
cib_name() {
  local base hash
  base="$(printf "%s" "$(basename "$1")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$1" | sha256sum | cut -c1-8)"
  else
    hash="$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
  fi
  printf 'claude-ide-box-%s-%s\n' "$base" "$hash"
}
