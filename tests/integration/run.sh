#!/usr/bin/env bash
# shellcheck disable=SC2015 # "check && ok || not_ok" is safe: ok() always succeeds
# Integration tests against a real Docker daemon.
#
# Builds the images, runs `claude-ide-box setup` in an isolated namespace
# (CLAUDE_IDE_BOX_INSTANCE=cbit, its own subnet, a throw-away HOME) and checks the
# sandbox from inside a project container. Without a reachable Docker daemon
# the tests are SKIPPED and say so; with CLAUDE_IDE_BOX_REQUIRE_DOCKER=1 a missing
# daemon is a failure instead.
#
# Environment (all optional):
#   CLAUDE_IDE_BOX_IT_BASE_IMAGE        base for the claude-ide-box image (default: config default)
#   CLAUDE_IDE_BOX_IT_PROXY_BASE_IMAGE  base for the proxy image
#   CLAUDE_IDE_BOX_IT_BUILD_NETWORK     `docker build --network` value
#   CLAUDE_IDE_BOX_IT_UPSTREAM_PROXY    host:port of a parent proxy for squid
#   CLAUDE_IDE_BOX_IT_SUBNET            internal subnet (default 172.30.98.0/24)
#   CLAUDE_IDE_BOX_IT_ALLOWED_URL       URL that must pass (default https://api.anthropic.com/)
#   CLAUDE_IDE_BOX_IT_PROFILES          image profiles to build and test, e.g. "php python go rust java office"
#   CLAUDE_IDE_BOX_IT_KEEP=1            keep containers, networks and volumes afterwards
#   CLAUDE_IDE_BOX_DOCKER               engine CLI, e.g. podman (as for claude-ide-box itself)
set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
export CLAUDE_IDE_BOX_INSTANCE=cbit
SUBNET="${CLAUDE_IDE_BOX_IT_SUBNET:-172.30.98.0/24}"
PREFIX3="${SUBNET%.*}"
PROXY_IP="$PREFIX3.2"
ALLOWED_URL="${CLAUDE_IDE_BOX_IT_ALLOWED_URL:-https://api.anthropic.com/}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
not_ok() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES="$FAILED_NAMES
  - $1"
  printf 'FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /'
}
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s (%s)\n' "$1" "$2"; }

DOCKER="${CLAUDE_IDE_BOX_DOCKER:-docker}"
ENGINE=docker
case "$("$DOCKER" --version 2>/dev/null || true)" in *[Pp]odman*) ENGINE=podman ;; esac
if ! command -v "$DOCKER" >/dev/null 2>&1 || ! "$DOCKER" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "======================================================================"
  echo " INTEGRATION TESTS SKIPPED: no reachable Docker daemon."
  echo " Nothing was verified. Run them on a machine with Docker."
  echo "======================================================================"
  if [ "${CLAUDE_IDE_BOX_REQUIRE_DOCKER:-0}" = "1" ]; then
    exit 1
  fi
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cbit.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME/claude-ide-box"
for v in $(compgen -e); do
  case "$v" in CLAUDE_CODE_* | ANTHROPIC_* | MCP_* | CLAUDE_AGENT_SDK*) unset "$v" ;; esac
done

CLI="$REPO_DIR/bin/claude-ide-box"
WRAPPER="$REPO_DIR/bin/claude-ide-box-exec"
PROJECT="$WORK/it project"
PROJECT_B="$WORK/second"
mkdir -p "$PROJECT" "$PROJECT_B"
# As root (e.g. rootful Podman), the container user is UID 1000 (see setup);
# give it the project directories as a root user's projects would need.
as_project_owner() {
  [ "$(id -u)" != 0 ] || chown 1000:1000 "$@"
}
as_project_owner "$PROJECT" "$PROJECT_B"

HOST_LISTENER_PID=""
cleanup() {
  [ -z "$HOST_LISTENER_PID" ] || kill "$HOST_LISTENER_PID" 2>/dev/null || true
  if [ "${CLAUDE_IDE_BOX_IT_KEEP:-0}" != "1" ]; then
    "$DOCKER" ps -aq --filter "name=^cbit-" | xargs "$DOCKER" rm -f >/dev/null 2>&1 || true
    "$DOCKER" volume ls -q --filter "name=^cbit-" | xargs "$DOCKER" volume rm >/dev/null 2>&1 || true
    "$DOCKER" network rm cbit-internal cbit-egress >/dev/null 2>&1 || true
    rm -rf "$WORK"
  else
    echo "kept: $WORK and cbit-* Docker objects"
  fi
}
trap cleanup EXIT

{
  echo "SUBNET=$SUBNET"
  echo "PROXY_IP=$PROXY_IP"
  [ -z "${CLAUDE_IDE_BOX_IT_BASE_IMAGE:-}" ] || echo "BASE_IMAGE=$CLAUDE_IDE_BOX_IT_BASE_IMAGE"
  [ -z "${CLAUDE_IDE_BOX_IT_PROXY_BASE_IMAGE:-}" ] || echo "PROXY_BASE_IMAGE=$CLAUDE_IDE_BOX_IT_PROXY_BASE_IMAGE"
  [ -z "${CLAUDE_IDE_BOX_IT_BUILD_NETWORK:-}" ] || echo "BUILD_NETWORK=$CLAUDE_IDE_BOX_IT_BUILD_NETWORK"
  [ -z "${CLAUDE_IDE_BOX_IT_UPSTREAM_PROXY:-}" ] || echo "UPSTREAM_PROXY=$CLAUDE_IDE_BOX_IT_UPSTREAM_PROXY"
} >"$XDG_CONFIG_HOME/claude-ide-box/config"

echo "== $ENGINE $("$DOCKER" version --format '{{.Server.Version}}'), host $(uname -sm), uid $(id -u)"
echo "== config:"
sed 's/^/   /' "$XDG_CONFIG_HOME/claude-ide-box/config"

# Leftovers of an interrupted earlier run.
"$DOCKER" ps -aq --filter "name=^cbit-" | xargs "$DOCKER" rm -f >/dev/null 2>&1 || true
"$DOCKER" network rm cbit-internal cbit-egress >/dev/null 2>&1 || true

echo "== claude-ide-box setup"
setup_args=()
for p in ${CLAUDE_IDE_BOX_IT_PROFILES:-}; do
  setup_args+=(--profile "$p")
done
if ! "$CLI" setup ${setup_args[@]+"${setup_args[@]}"} >"$WORK/setup.log" 2>&1; then
  tail -n 40 "$WORK/setup.log"
  not_ok "setup builds images and starts the proxy"
  exit 1
fi
ok "setup builds images and starts the proxy"

# Project fixtures: secrets, a git directory, IDE config.
printf 'SECRET=hunter2\n' >"$PROJECT/.env"
mkdir -p "$PROJECT/.env.d" "$PROJECT/.git/hooks" "$PROJECT/.vscode"
printf 'TOKEN=abc\n' >"$PROJECT/.env.d/prod"
printf 'SECRET=\n' >"$PROJECT/.env.example"
printf '[core]\n\tbare = false\n' >"$PROJECT/.git/config"
printf '{}\n' >"$PROJECT/.vscode/settings.json"

if ! (cd "$PROJECT" && "$CLI" up) >"$WORK/up.log" 2>&1; then
  cat "$WORK/up.log"
  not_ok "claude-ide-box up creates the project container"
  exit 1
fi
ok "claude-ide-box up creates the project container"
# The container name of a project, as claude-ide-box computes it.
container_name() {
  (cd "$1" && "$CLI" status | awk '/^container:/{print $2}')
}
NAME="$(container_name "$PROJECT")"

# in_box CMD - run a shell command in the project container (as its user).
in_box() {
  "$DOCKER" exec -w "$PROJECT" "$NAME" bash -c "$1"
}

expected_uid="$(id -u)"
[ "$expected_uid" != 0 ] || expected_uid=1000

# ---------------------------------------------------------------------------
echo "== (a) egress through the proxy"
code="$(in_box "curl -sS -o /dev/null -w '%{http_code}' --max-time 30 '$ALLOWED_URL'" 2>&1 || true)"
case "$code" in
  [1-5][0-9][0-9]) ok "allowed domain passes the proxy ($ALLOWED_URL -> HTTP $code)" ;;
  *) not_ok "allowed domain passes the proxy" "$code" ;;
esac

out="$(in_box "curl -sS -o /dev/null --max-time 20 https://example.com/" 2>&1 || true)"
case "$out" in
  *403*) ok "disallowed domain is refused by the proxy (403)" ;;
  *) not_ok "disallowed domain is refused by the proxy" "$out" ;;
esac

code="$(in_box "curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://api.anthropic.com/" 2>&1 || true)"
[ "$code" = 403 ] && ok "plain HTTP through the proxy is refused" || not_ok "plain HTTP through the proxy is refused" "$code"

out="$(in_box "curl -sS -o /dev/null --max-time 20 https://1.1.1.1/" 2>&1 || true)"
case "$out" in
  *403*) ok "CONNECT to a bare IP address is refused" ;;
  *) not_ok "CONNECT to a bare IP address is refused" "$out" ;;
esac

out="$(in_box "curl -sS -o /dev/null --max-time 20 --proxytunnel http://api.anthropic.com:80/" 2>&1 || true)"
case "$out" in
  *403*) ok "CONNECT to a port other than 443 is refused" ;;
  *) not_ok "CONNECT to a port other than 443 is refused" "$out" ;;
esac

if in_box "curl -sS -o /dev/null --noproxy '*' --max-time 8 https://1.1.1.1/" >/dev/null 2>&1; then
  not_ok "direct connection without the proxy is blocked"
else
  ok "direct connection without the proxy is blocked"
fi
if in_box "timeout 8 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'" >/dev/null 2>&1; then
  not_ok "raw TCP to the internet is blocked"
else
  ok "raw TCP to the internet is blocked"
fi
v="$(in_box "awk 'NR>1 && \$2==\"00000000\"' /proc/net/route")"
[ -z "$v" ] && ok "the container has no default route" || not_ok "the container has no default route" "$v"

# ---------------------------------------------------------------------------
echo "== (b) DNS"
if in_box "getent hosts api.anthropic.com || getent hosts example.com" >/dev/null 2>&1; then
  not_ok "DNS resolution of external names fails"
else
  ok "DNS resolution of external names fails"
fi
v="$(in_box "grep '^nameserver' /etc/resolv.conf" 2>&1 || true)"
printf '      resolv.conf: %s\n' "$v"

# ---------------------------------------------------------------------------
echo "== (c) masked secrets"
v="$(in_box "cat .env" 2>&1 || true)"
[ -z "$v" ] && ok ".env is empty inside the container" || not_ok ".env is empty inside the container" "$v"
v="$(in_box "ls -A .env.d" 2>&1 || true)"
[ -z "$v" ] && ok ".env.d/ is an empty tmpfs inside the container" || not_ok ".env.d/ is empty" "$v"
in_box "echo leak >> .env" >/dev/null 2>&1 && not_ok ".env is read-only" || ok ".env is read-only"
[ "$(cat "$PROJECT/.env")" = "SECRET=hunter2" ] && ok "host .env is untouched" || not_ok "host .env is untouched"
v="$(in_box "cat .env.example" 2>&1 || true)"
[ "$v" = "SECRET=" ] && ok ".env.example (a template) stays readable" || not_ok ".env.example (a template) stays readable" "$v"

# ---------------------------------------------------------------------------
echo "== (d) read-only host-tool directories"
for p in ".git/hooks/pre-commit" ".git/config" ".vscode/settings.json" ".vscode/tasks.json" ".idea/x" ".devcontainer/devcontainer.json" ".agent/x"; do
  if in_box "echo 'touch /tmp/pwned' > '$p'" >/dev/null 2>&1; then
    not_ok "writing $p fails"
  else
    ok "writing $p fails"
  fi
done
in_box "rm -rf .git" >/dev/null 2>&1 || true
[ -f "$PROJECT/.git/config" ] && ok ".git cannot be removed" || not_ok ".git cannot be removed"
in_box "mv .vscode vscode-moved" >/dev/null 2>&1 && not_ok ".vscode cannot be renamed" || ok ".vscode cannot be renamed"

# ---------------------------------------------------------------------------
echo "== (e) project writes"
if in_box "echo hello > created-in-box.txt && mkdir -p sub/dir && touch sub/dir/f"; then
  ok "writing to the project works"
  # shellcheck disable=SC2012 # ls -n is the portable way to read a numeric owner
  owner="$(ls -n "$PROJECT/created-in-box.txt" | awk '{print $3}')"
  [ "$owner" = "$expected_uid" ] && ok "new files belong to UID $expected_uid on the host" ||
    not_ok "new files belong to UID $expected_uid on the host" "owner: $owner"
else
  not_ok "writing to the project works"
fi

# ---------------------------------------------------------------------------
echo "== (f) privileges"
v="$(in_box "grep CapEff /proc/self/status | awk '{print \$2}'")"
[ "$v" = "0000000000000000" ] && ok "no effective capabilities" || not_ok "no effective capabilities" "$v"
v="$(in_box "grep CapBnd /proc/self/status | awk '{print \$2}'")"
[ "$v" = "0000000000000000" ] && ok "empty capability bounding set" || not_ok "empty capability bounding set" "$v"
v="$(in_box "grep NoNewPrivs /proc/self/status | awk '{print \$2}'")"
[ "$v" = "1" ] && ok "no_new_privs is set" || not_ok "no_new_privs is set" "$v"
v="$(in_box "id -u")"
[ "$v" != 0 ] && ok "runs as non-root (uid $v)" || not_ok "runs as non-root"
if in_box "ls -la /var/run/docker.sock /run/docker.sock 2>/dev/null; grep -q docker.sock /proc/mounts" >/dev/null 2>&1; then
  not_ok "no docker.sock in the container"
else
  ok "no docker.sock in the container"
fi
in_box "touch /etc/pwned" >/dev/null 2>&1 && not_ok "root filesystem is read-only" || ok "root filesystem is read-only"
in_box "command -v sudo" >/dev/null 2>&1 && not_ok "no sudo in the image" || ok "no sudo in the image"
v="$("$DOCKER" inspect --format '{{.HostConfig.PidsLimit}} {{.HostConfig.Memory}} {{.HostConfig.Init}}' "$NAME")"
case "$v" in
  "512 "*" true") ok "pids/memory limits and --init are set ($v)" ;;
  *) not_ok "pids/memory limits and --init are set" "$v" ;;
esac
if "$DOCKER" inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$NAME" | tr ' ' '\n' | grep -qx "$HOME"; then
  not_ok "host home directory is not mounted"
else
  ok "host home directory is not mounted"
fi

for d in /run /var/tmp; do
  in_box "touch $d/claude-ide-box-probe" >/dev/null 2>&1 && not_ok "$d is not writable" || ok "$d is not writable"
done
in_box "touch /dev/shm/probe" >/dev/null 2>&1 && ok "/dev/shm is writable (as on Docker)" || not_ok "/dev/shm is writable"

echo "== engine: $ENGINE"
v="$(in_box "grep '^nameserver' /etc/resolv.conf" 2>&1 || true)"
[ "$v" = "nameserver 127.0.0.1" ] && ok "the only resolver is 127.0.0.1" || not_ok "the only resolver is 127.0.0.1" "$v"
if [ "$ENGINE" = podman ]; then
  v="$("$DOCKER" network inspect --format '{{.Internal}} {{.DNSEnabled}}' cbit-internal 2>&1)"
  [ "$v" = "true false" ] && ok "Podman internal network has no DNS (so no host address on its bridge)" ||
    not_ok "Podman internal network has no DNS" "$v"
  v="$("$DOCKER" info --format '{{.Host.Security.Rootless}}')"
  printf '      rootless: %s\n' "$v"
fi

# ---------------------------------------------------------------------------
echo "== (g) wrapper stdout"
out="$(cd "$PROJECT" && "$WRAPPER" /fake/native-binary/claude --version 2>"$WORK/wrapper.err")"
if printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+ \(Claude Code\)$' && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then
  ok "claude-ide-box-exec /fake/native-binary/claude --version prints only the version ($out)"
else
  not_ok "claude-ide-box-exec --version prints only the version" "stdout: $out"$'\n'"stderr: $(cat "$WORK/wrapper.err")"
fi

# ---------------------------------------------------------------------------
# Gateway of the engine's default bridge network (docker0, or Podman's "podman").
default_gateway() {
  if [ "$ENGINE" = podman ]; then
    "$DOCKER" network inspect podman --format '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null
  else
    "$DOCKER" network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null
  fi
}

echo "== extra: host services are unreachable from the internal network"
port=$((20000 + RANDOM % 10000))
if command -v python3 >/dev/null 2>&1; then
  python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 &
  HOST_LISTENER_PID=$!
  sleep 1
  # Positive control: from a container on the default bridge the listener is
  # reachable, so the checks below are not passing because nothing listens.
  gw="$(default_gateway)"
  if "$DOCKER" run --rm --entrypoint bash "$("$DOCKER" inspect --format '{{.Config.Image}}' "$NAME")" \
    -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$gw/$port'" >/dev/null 2>&1; then
    ok "control: host listener is reachable from the default bridge ($gw:$port)"
  else
    skip "control: host listener reachable from the default bridge" "host firewall blocks it anyway"
  fi
  for ip in "$PREFIX3.1" "$gw"; do
    [ -n "$ip" ] || continue
    if in_box "timeout 5 bash -c 'exec 3<>/dev/tcp/$ip/$port'" >/dev/null 2>&1; then
      not_ok "host listener on $ip:$port is unreachable"
    else
      ok "host listener on $ip:$port is unreachable"
    fi
  done
  kill "$HOST_LISTENER_PID" 2>/dev/null || true
  HOST_LISTENER_PID=""
else
  skip "host listener unreachable" "python3 not available on the host"
fi

echo "== extra: Claude Code reaches the API through the proxy without DNS"
tunnels_before="$("$DOCKER" logs cbit-proxy 2>/dev/null | grep -c 'TCP_TUNNEL.*CONNECT api.anthropic.com:443' || true)"
out="$(cd "$PROJECT" && ANTHROPIC_API_KEY=sk-ant-api03-claude-ide-box-invalid-key "$WRAPPER" -p "say hi" 2>&1 </dev/null || true)"
tunnels_after="$("$DOCKER" logs cbit-proxy 2>/dev/null | grep -c 'TCP_TUNNEL.*CONNECT api.anthropic.com:443' || true)"
if [ "$tunnels_after" -gt "$tunnels_before" ]; then
  ok "claude opened $((tunnels_after - tunnels_before)) tunnel(s) to api.anthropic.com:443 through squid"
else
  not_ok "claude's API traffic goes through squid" "tunnels before $tunnels_before, after $tunnels_after"
fi
case "$out" in
  *ENOTFOUND* | *EAI_AGAIN* | *getaddrinfo* | *"Unable to connect"* | *ECONNREFUSED* | *ETIMEDOUT*)
    not_ok "an API request reaches api.anthropic.com (expected an authentication error)" "$out" ;;
  *"API key"* | *api?key* | *401* | *uthenticat* | *nvalid*)
    ok "an API request reaches api.anthropic.com and is rejected for the fake key"
    printf '%s\n' "$out" | head -n 3 | sed 's/^/      claude: /' ;;
  *) not_ok "an API request reaches api.anthropic.com (expected an authentication error)" "$out" ;;
esac

echo "== extra: proxy hardening"
v="$("$DOCKER" exec cbit-proxy sh -c 'grep CapEff /proc/1/status' | awk '{print $2}')"
[ "$v" = "0000000000000000" ] && ok "squid runs without capabilities" || not_ok "squid runs without capabilities" "$v"
v="$("$DOCKER" exec cbit-proxy id -un)"
[ "$v" = proxy ] && ok "squid runs as the unprivileged proxy user" || not_ok "squid runs as proxy" "$v"
v="$("$DOCKER" inspect --format '{{.HostConfig.ReadonlyRootfs}}' cbit-proxy)"
[ "$v" = true ] && ok "proxy root filesystem is read-only" || not_ok "proxy root filesystem is read-only" "$v"
logs="$(cd "$PROJECT" && "$CLI" logs 2>&1 || true)"
case "$logs" in
  *TCP_DENIED*example.com*) ok "claude-ide-box logs shows the denied request" ;;
  *) not_ok "claude-ide-box logs shows the denied request" "$logs" ;;
esac
v="$(printf '%s\n' "$logs" | sed -n '/denied domains/,$p' | grep ' example.com ' || true)"
case "$v" in
  *"claude-ide-box allow example.com"*) ok "claude-ide-box logs summarises the denied domain with a hint" ;;
  *) not_ok "claude-ide-box logs summarises the denied domain with a hint" "$logs" ;;
esac

echo "== extra: allowlist changes apply without restarting the proxy"
before="$(in_box "curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://packagist.org/" 2>&1 || true)"
allow_out="$("$CLI" allow packagist.org 2>&1 || true)"
after="$(in_box "curl -s -o /dev/null -w '%{http_code}' --max-time 30 https://packagist.org/" 2>&1 || true)"
case "$before:$after" in
  000:[1-5][0-9][0-9] | 403:[1-5][0-9][0-9])
    if [ "$after" != 403 ]; then
      ok "claude-ide-box allow takes effect immediately (before: $before, after: HTTP $after)"
    else
      not_ok "claude-ide-box allow takes effect immediately" "before $before, after $after"$'\n'"$allow_out"
    fi
    ;;
  *) not_ok "claude-ide-box allow takes effect immediately" "before $before, after $after"$'\n'"$allow_out" ;;
esac
case "$allow_out" in
  *"proxy reloaded"*) ok "the reload is confirmed by squid" ;;
  *) not_ok "the reload is confirmed by squid" "$allow_out" ;;
esac

echo "== extra: forward a dev server to the host"
"$DOCKER" exec -d -w /tmp "$NAME" python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null
fport=$((30000 + RANDOM % 20000))
(cd "$PROJECT" && exec "$CLI" forward 8765 "$fport" >"$WORK/forward.log" 2>&1) &
fwd_pid=$!
code=000
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  sleep 0.5
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' "http://127.0.0.1:$fport/" || true)"
  [ "$code" != 000 ] && break
done
kill "$fwd_pid" 2>/dev/null || true
wait "$fwd_pid" 2>/dev/null || true
[ "$code" = 200 ] && ok "claude-ide-box forward serves a container dev server on 127.0.0.1" ||
  not_ok "claude-ide-box forward serves a container dev server on 127.0.0.1" "HTTP $code"$'\n'"$(cat "$WORK/forward.log")"
v="$("$DOCKER" port "$NAME" 2>/dev/null || true)"
[ -z "$v" ] && ok "the container still publishes no ports" || not_ok "the container still publishes no ports" "$v"

echo "== extra: per-project home volumes"
in_box 'echo "project-a" > ~/.claude/marker' || true
(cd "$PROJECT_B" && "$CLI" up >/dev/null 2>&1) || not_ok "second project container starts"
NAME_B="$(container_name "$PROJECT_B")"
if "$DOCKER" exec "$NAME_B" test -e /home/claude/.claude/marker 2>/dev/null; then
  not_ok "one project's ~/.claude is invisible to another"
else
  ok "one project's ~/.claude is invisible to another"
fi
if "$DOCKER" exec "$NAME_B" test -e "$PROJECT/.env" 2>/dev/null; then
  not_ok "another project's files are invisible"
else
  ok "another project's files are invisible"
fi

echo "== extra: a new secret file causes the container to be recreated with a mask"
printf 'NEW=1\n' >"$PROJECT/.env.local"
(cd "$PROJECT" && "$WRAPPER" --version >/dev/null 2>&1) || true
v="$(in_box "cat .env.local" 2>&1 || true)"
[ -z "$v" ] && ok ".env.local created on the host later is masked" || not_ok ".env.local created later is masked" "$v"

echo "== extra: nested repositories and mount-option injection"
mkdir -p "$PROJECT/nested/.git/hooks"
(cd "$PROJECT" && "$WRAPPER" --version >/dev/null 2>&1) || true
if in_box "echo 'touch /tmp/pwned' > nested/.git/hooks/post-checkout" >/dev/null 2>&1; then
  not_ok "a nested .git is read-only after the next start"
else
  ok "a nested .git is read-only after the next start"
fi
evil="$PROJECT/q,src=$HOME,dst=/home/claude/leak"
mkdir -p "$evil" && : >"$evil/.env"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
out="$(cd "$PROJECT" && "$WRAPPER" --version 2>&1)" && st=0 || st=$?
if [ "$st" != 0 ] && ! "$DOCKER" inspect "$NAME" >/dev/null 2>&1; then
  ok "a file name with a comma cannot inject mount options (start refused)"
else
  not_ok "a file name with a comma cannot inject mount options" "status $st: $out"
fi
rm -rf "$evil"
(cd "$PROJECT" && "$CLI" up >/dev/null 2>&1) || not_ok "container comes back after removing the bad name"

echo "== minimum engine versions"
out="$("$CLI" doctor 2>&1 || true)"
v="$(printf '%s\n' "$out" | grep -E 'container escape|engine version|runc version' || true)"
printf '      %s\n' "$v"
case "$v" in
  *"[ ok ]"*"no known container escape"*) ok "doctor reads the real engine's versions (Engine, runc) and checks them" ;;
  *) not_ok "doctor reads the real engine's versions (Engine, runc) and checks them" "$v" ;;
esac

echo "== ephemeral mode (up --try)"
printf 'original\n' >"$PROJECT/try-me.txt"
if (cd "$PROJECT" && "$CLI" up --try) >"$WORK/try.log" 2>&1; then
  ok "up --try starts a container on a copy of the project"
  TNAME="$NAME-try"
  in_try() { "$DOCKER" exec -w "$PROJECT" "$TNAME" bash -c "$1"; }
  v="$(in_try "cat .env" 2>&1 || true)"
  [ -z "$v" ] && ok "try: .env is empty in the copy's container" || not_ok "try: .env is empty in the copy's container" "$v"
  in_try "echo x > .git/config" >/dev/null 2>&1 && not_ok "try: .git is read-only" || ok "try: .git is read-only"
  v="$(in_try "curl -sS -o /dev/null --noproxy '*' --max-time 8 https://1.1.1.1/ && echo reached" 2>/dev/null || true)"
  [ -z "$v" ] && ok "try: no direct network either" || not_ok "try: no direct network either" "$v"
  in_try "echo changed > try-me.txt && echo new > try-new.txt" || true
  [ "$(cat "$PROJECT/try-me.txt")" = original ] && [ ! -e "$PROJECT/try-new.txt" ] &&
    ok "try: the project is untouched while Claude works on the copy" ||
    not_ok "try: the project is untouched while Claude works on the copy"
  v="$(cd "$PROJECT" && "$CLI" try diff 2>&1 || true)"
  case "$v" in
    *"+changed"*"try-new.txt"* | *"try-new.txt"*"+changed"*) ok "try diff shows the copy's changes on the host" ;;
    *) not_ok "try diff shows the copy's changes on the host" "$v" ;;
  esac
  v="$(cd "$PROJECT" && "$CLI" try apply 2>&1)" && st=0 || st=$?
  if [ "$st" = 0 ] && [ "$(cat "$PROJECT/try-me.txt")" = changed ] && [ "$(cat "$PROJECT/try-new.txt")" = new ] &&
    [ "$(cat "$PROJECT/.env")" = "SECRET=hunter2" ]; then
    ok "try apply writes the changes and leaves the secret alone"
  else
    not_ok "try apply writes the changes and leaves the secret alone" "$v"
  fi
  "$DOCKER" inspect "$TNAME" >/dev/null 2>&1 && not_ok "try apply removes the copy's container" ||
    ok "try apply removes the copy's container"
else
  not_ok "up --try starts a container on a copy of the project" "$(tail -n 20 "$WORK/try.log")"
fi

echo "== extra: fail closed"
out="$(cd "$PROJECT" && DOCKER_HOST=unix:///nonexistent.sock CONTAINER_HOST=unix:///nonexistent.sock "$WRAPPER" --version 2>/dev/null)" && st=0 || st=$?
if [ "$st" != 0 ] && [ -z "$out" ]; then
  ok "unreachable Docker daemon: non-zero exit, empty stdout"
else
  not_ok "unreachable Docker daemon: non-zero exit, empty stdout" "status $st, stdout '$out'"
fi
out="$(cd "$HOME" && "$WRAPPER" --version 2>&1)" && st=0 || st=$?
case "$st:$out" in
  0:*) not_ok "the home directory is refused as a project" ;;
  *home*) ok "the home directory is refused as a project" ;;
  *) not_ok "the home directory is refused as a project" "$out" ;;
esac

echo "== base image: native npm modules and Python"
out="$(in_box "cd /tmp && mkdir -p native && cd native && npm init -y >/dev/null && npm_config_build_from_source=true npm install --no-audit --no-fund bufferutil@4 >/tmp/npm.log 2>&1 && node -e \"require('bufferutil'); console.log('native-ok')\"" 2>&1 || true)"
case "$out" in
  *native-ok*) ok "a native npm module compiles (node-gyp, no header download)" ;;
  *) not_ok "a native npm module compiles" "$out"$'\n'"$(in_box "tail -n 15 /tmp/npm.log" 2>&1)" ;;
esac
out="$(in_box "python3 -m venv /tmp/venv && /tmp/venv/bin/python -c 'import sys; print(sys.version_info[0])'" 2>&1 || true)"
[ "$out" = 3 ] && ok "python3 with venv is in the base image" || not_ok "python3 with venv is in the base image" "$out"

# profile_project NAME PROFILES - create a project using PROFILES; sets PNAME and PDIR.
profile_project() {
  PDIR="$WORK/profile-$1"
  mkdir -p "$PDIR" "$XDG_CONFIG_HOME/claude-ide-box/projects"
  as_project_owner "$PDIR"
  PNAME="$(container_name "$PDIR")"
  printf 'PROFILE="%s"\n' "$2" >"$XDG_CONFIG_HOME/claude-ide-box/projects/$PNAME.conf"
  if (cd "$PDIR" && "$CLI" up) >"$WORK/up-$1.log" 2>&1; then
    ok "profile '$2': container starts"
    return 0
  fi
  not_ok "profile '$2': container starts" "$(tail -n 20 "$WORK/up-$1.log")"
  return 1
}

# in_profile CMD - run CMD in the current profile project's container.
in_profile() {
  "$DOCKER" exec -w "$PDIR" "$PNAME" bash -c "$1"
}

# check_with_preset PRESET DESCRIPTION EXPECTED CMD
check_with_preset() {
  local preset_out out
  preset_out="$("$CLI" preset "$1" on 2>&1 || true)"
  out="$(in_profile "$4" 2>&1 || true)"
  case "$out" in
    *"$3"*) ok "$2" ;;
    *) not_ok "$2" "preset: $preset_out"$'\n'"$(printf '%s\n' "$out" | tail -n 8)" ;;
  esac
  "$CLI" preset "$1" off >/dev/null 2>&1 || true
}

cb_it_has_profile() {
  case " ${CLAUDE_IDE_BOX_IT_PROFILES:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

for profile in ${CLAUDE_IDE_BOX_IT_PROFILES:-}; do
  echo "== profile $profile"
  profile_project "$profile" "$profile" || continue
  case "$profile" in
    php)
      v="$(in_profile "php -m" 2>&1 | tr '\n' ' ')"
      missing=""
      for m in curl gd intl mbstring mysqli pdo_mysql xml zip; do
        printf ' %s ' "$v" | grep -qi " $m " || missing="$missing $m"
      done
      [ -z "$missing" ] && ok "PHP $(in_profile "php -r 'echo PHP_VERSION;'") has the PrestaShop extensions" ||
        not_ok "PHP extensions present" "missing:$missing"
      in_profile "mysql --version" >/dev/null 2>&1 && ok "mariadb client present" || not_ok "mariadb client present"
      check_with_preset php "composer reaches packagist through the proxy without DNS" "name " \
        "composer show --all --no-interaction monolog/monolog"
      ;;
    python)
      check_with_preset python "uv installs a package from PyPI through the proxy" "six-ok" \
        "uv venv -q .venv && uv pip install -q --python .venv/bin/python six && .venv/bin/python -c 'import six; print(\"six-ok\")'"
      ;;
    go)
      check_with_preset go "go downloads a module through proxy.golang.org" '"Version"' \
        "go mod download -json golang.org/x/text@latest"
      ;;
    rust)
      check_with_preset rust "cargo adds and builds a crate from crates.io" "rust-ok" \
        "cargo new -q --vcs none app && cd app && cargo add -q itoa && cargo build -q && printf 'rust-ok\n'"
      ;;
    java)
      check_with_preset java "Maven fetches an artifact from Maven Central" "java-ok" \
        "mvn -q -B dependency:get -Dartifact=junit:junit:4.13.2 && printf 'java-ok\n'"
      ;;
    office)
      out="$(in_profile "printf '# Umowa\n\nTekst zażółć.\n' > t.md && pandoc t.md -o t.docx && soffice --headless --convert-to pdf t.docx >/dev/null 2>&1 && pdftotext t.pdf -" 2>&1 || true)"
      case "$out" in
        *Umowa*) ok "office: Markdown -> DOCX -> PDF -> text works offline" ;;
        *) not_ok "office: Markdown -> DOCX -> PDF -> text works offline" "$out" ;;
      esac
      in_profile "tesseract --list-langs 2>&1 | grep -qx pol" && ok "office: OCR with Polish" || not_ok "office: OCR with Polish"
      # Excel: write a workbook with a formula, let LibreOffice recalculate it.
      out="$(in_profile "python3 -c \"import openpyxl; wb = openpyxl.Workbook(); ws = wb.active; ws['A1'] = 20; ws['A2'] = 22; ws['A3'] = '=SUM(A1:A2)'; wb.save('book.xlsx')\" && soffice --headless --convert-to csv book.xlsx >/dev/null 2>&1 && cat book.csv" 2>&1 || true)"
      case "$out" in
        *42*) ok "office: an .xlsx formula is computed (openpyxl + LibreOffice)" ;;
        *) not_ok "office: an .xlsx formula is computed" "$out" ;;
      esac
      # Word: edit an existing .docx in place, without converting it.
      out="$(in_profile "python3 -c \"import docx; d = docx.Document('t.docx'); d.add_paragraph('Aneks nr 1'); d.save('t.docx'); print([p.text for p in docx.Document('t.docx').paragraphs])\"" 2>&1 || true)"
      case "$out" in
        *Umowa*"Aneks nr 1"*) ok "office: a .docx is edited in place (python-docx)" ;;
        *) not_ok "office: a .docx is edited in place" "$out" ;;
      esac
      ;;
    *) skip "profile $profile" "no specific checks" ;;
  esac
done

if cb_it_has_profile go && cb_it_has_profile python; then
  echo "== combined profiles"
  # The user's flow: choose the profiles, build them with setup, start.
  mkdir -p "$WORK/profile-combo"
  as_project_owner "$WORK/profile-combo"
  if ! (cd "$WORK/profile-combo" && "$CLI" profile python go && "$CLI" setup) >"$WORK/combo-setup.log" 2>&1; then
    not_ok "profiles combine: 'profile python go' + setup builds the chain" "$(tail -n 15 "$WORK/combo-setup.log")"
  elif profile_project combo "python go"; then
    in_profile "go version && uv --version" >/dev/null 2>&1 &&
      ok "profiles combine: go and uv in one container" || not_ok "profiles combine: go and uv in one container"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
