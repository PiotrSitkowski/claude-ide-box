# shellcheck shell=bash
# shellcheck disable=SC2034 # OUT/ERR/STATUS/PROJECT/... are read by the test files
# Sandbox for unit tests: private HOME/XDG dirs, a fake docker first on PATH,
# and a "host claude" trap that records if anything ever runs it.

setup_sandbox() {
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export FAKE_DOCKER_DIR="$SANDBOX/docker"
  mkdir -p "$HOME" "$FAKE_DOCKER_DIR" "$SANDBOX/bin" "$SANDBOX/work"
  cp "$TESTS_DIR/unit/fake-bin/docker" "$SANDBOX/bin/docker"
  # A host `claude` that must never run.
  cat >"$SANDBOX/bin/claude" <<'EOS'
#!/bin/sh
echo "HOST CLAUDE RAN" >&2
: >"$FAKE_DOCKER_DIR/host-claude-ran"
exit 99
EOS
  chmod +x "$SANDBOX/bin/claude"
  # Keep the directory of the bash running the tests (e.g. /usr/local/bin) so
  # the scripts' "#!/usr/bin/env bash" finds the same interpreter.
  export PATH="$SANDBOX/bin:$(dirname "$BASH"):/usr/bin:/bin:/usr/sbin:/sbin"
  unset CLAUDE_BOX_DOCKER CLAUDE_BOX_DEBUG DOCKER_HOST DOCKER_CONTEXT || true
  # Drop anything the developer's shell may have that the wrapper would forward.
  local n
  for n in $(compgen -e); do
    case "$n" in
      CLAUDE_* | ANTHROPIC_* | MCP_* | MAX_THINKING_TOKENS) unset "$n" ;;
    esac
  done
  PROJECT="$SANDBOX/work/My Project"
  mkdir -p "$PROJECT"
  WRAPPER="$REPO_DIR/bin/claude-box-exec"
  CLI="$REPO_DIR/bin/claude-box"
}

# run_wrapper [ARGS...] - runs the wrapper in $PROJECT; sets OUT, ERR, STATUS.
run_wrapper() {
  local dir="${RUN_DIR:-$PROJECT}"
  set +e
  OUT="$(cd "$dir" && "$WRAPPER" "$@" 2>"$SANDBOX/stderr" </dev/null)"
  STATUS=$?
  set -e
  ERR="$(cat "$SANDBOX/stderr")"
}

# run_cli [ARGS...] - runs the management CLI in $PROJECT.
run_cli() {
  local dir="${RUN_DIR:-$PROJECT}"
  set +e
  OUT="$(cd "$dir" && "$CLI" "$@" 2>"$SANDBOX/stderr" </dev/null)"
  STATUS=$?
  set -e
  ERR="$(cat "$SANDBOX/stderr")"
}

exec_args() {
  tr '\n' ' ' <"$FAKE_DOCKER_DIR/exec.args" 2>/dev/null | sed 's/ $//'
}

run_args() {
  cat "$FAKE_DOCKER_DIR/run.args" 2>/dev/null
}

sha8() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | sha256sum)"
  else
    out="$(printf '%s' "$1" | shasum -a 256)"
  fi
  printf '%s\n' "$out" | cut -c1-8
}
