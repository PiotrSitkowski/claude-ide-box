#!/usr/bin/env bash
# shellcheck disable=SC2015 # "check && ok || not_ok" is safe: ok() always succeeds
# Integration tests against a real Docker daemon.
#
# Builds the images, runs `claude-box setup` in an isolated namespace
# (CLAUDE_BOX_INSTANCE=cbit, its own subnet, a throw-away HOME) and checks the
# sandbox from inside a project container. Without a reachable Docker daemon
# the tests are SKIPPED and say so; with CLAUDE_BOX_REQUIRE_DOCKER=1 a missing
# daemon is a failure instead.
#
# Environment (all optional):
#   CLAUDE_BOX_IT_BASE_IMAGE        base for the claude-box image (default: config default)
#   CLAUDE_BOX_IT_PROXY_BASE_IMAGE  base for the proxy image
#   CLAUDE_BOX_IT_BUILD_NETWORK     `docker build --network` value
#   CLAUDE_BOX_IT_UPSTREAM_PROXY    host:port of a parent proxy for squid
#   CLAUDE_BOX_IT_SUBNET            internal subnet (default 172.30.98.0/24)
#   CLAUDE_BOX_IT_ALLOWED_URL       URL that must pass (default https://api.anthropic.com/)
#   CLAUDE_BOX_IT_PROFILES          extra image profiles to build and test (e.g. "php")
#   CLAUDE_BOX_IT_KEEP=1            keep containers, networks and volumes afterwards
set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
export CLAUDE_BOX_INSTANCE=cbit
SUBNET="${CLAUDE_BOX_IT_SUBNET:-172.30.98.0/24}"
PREFIX3="${SUBNET%.*}"
PROXY_IP="$PREFIX3.2"
ALLOWED_URL="${CLAUDE_BOX_IT_ALLOWED_URL:-https://api.anthropic.com/}"

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

if ! command -v docker >/dev/null 2>&1 || ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "======================================================================"
  echo " INTEGRATION TESTS SKIPPED: no reachable Docker daemon."
  echo " Nothing was verified. Run them on a machine with Docker."
  echo "======================================================================"
  if [ "${CLAUDE_BOX_REQUIRE_DOCKER:-0}" = "1" ]; then
    exit 1
  fi
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cbit.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME/claude-box"
for v in $(compgen -e); do
  case "$v" in CLAUDE_CODE_* | ANTHROPIC_* | MCP_* | CLAUDE_AGENT_SDK*) unset "$v" ;; esac
done

CLI="$REPO_DIR/bin/claude-box"
WRAPPER="$REPO_DIR/bin/claude-box-exec"
PROJECT="$WORK/it project"
PROJECT_B="$WORK/second"
mkdir -p "$PROJECT" "$PROJECT_B"

HOST_LISTENER_PID=""
cleanup() {
  [ -z "$HOST_LISTENER_PID" ] || kill "$HOST_LISTENER_PID" 2>/dev/null || true
  if [ "${CLAUDE_BOX_IT_KEEP:-0}" != "1" ]; then
    docker ps -aq --filter "name=^cbit-" | xargs docker rm -f >/dev/null 2>&1 || true
    docker volume ls -q --filter "name=^cbit-" | xargs docker volume rm >/dev/null 2>&1 || true
    docker network rm cbit-internal cbit-egress >/dev/null 2>&1 || true
    rm -rf "$WORK"
  else
    echo "kept: $WORK and cbit-* Docker objects"
  fi
}
trap cleanup EXIT

{
  echo "SUBNET=$SUBNET"
  echo "PROXY_IP=$PROXY_IP"
  [ -z "${CLAUDE_BOX_IT_BASE_IMAGE:-}" ] || echo "BASE_IMAGE=$CLAUDE_BOX_IT_BASE_IMAGE"
  [ -z "${CLAUDE_BOX_IT_PROXY_BASE_IMAGE:-}" ] || echo "PROXY_BASE_IMAGE=$CLAUDE_BOX_IT_PROXY_BASE_IMAGE"
  [ -z "${CLAUDE_BOX_IT_BUILD_NETWORK:-}" ] || echo "BUILD_NETWORK=$CLAUDE_BOX_IT_BUILD_NETWORK"
  [ -z "${CLAUDE_BOX_IT_UPSTREAM_PROXY:-}" ] || echo "UPSTREAM_PROXY=$CLAUDE_BOX_IT_UPSTREAM_PROXY"
} >"$XDG_CONFIG_HOME/claude-box/config"

echo "== docker $(docker version --format '{{.Server.Version}}'), host $(uname -sm), uid $(id -u)"
echo "== config:"
sed 's/^/   /' "$XDG_CONFIG_HOME/claude-box/config"

# Leftovers of an interrupted earlier run.
docker ps -aq --filter "name=^cbit-" | xargs docker rm -f >/dev/null 2>&1 || true
docker network rm cbit-internal cbit-egress >/dev/null 2>&1 || true

echo "== claude-box setup"
setup_args=()
for p in ${CLAUDE_BOX_IT_PROFILES:-}; do
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
printf '[core]\n\tbare = false\n' >"$PROJECT/.git/config"
printf '{}\n' >"$PROJECT/.vscode/settings.json"

if ! (cd "$PROJECT" && "$CLI" up) >"$WORK/up.log" 2>&1; then
  cat "$WORK/up.log"
  not_ok "claude-box up creates the project container"
  exit 1
fi
ok "claude-box up creates the project container"
# The container name of a project, as claude-box computes it.
container_name() {
  (cd "$1" && "$CLI" status | awk '/^container:/{print $2}')
}
NAME="$(container_name "$PROJECT")"

# in_box CMD - run a shell command in the project container (as its user).
in_box() {
  docker exec -w "$PROJECT" "$NAME" bash -c "$1"
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
v="$(docker inspect --format '{{.HostConfig.PidsLimit}} {{.HostConfig.Memory}} {{.HostConfig.Init}}' "$NAME")"
case "$v" in
  "512 "*" true") ok "pids/memory limits and --init are set ($v)" ;;
  *) not_ok "pids/memory limits and --init are set" "$v" ;;
esac
if docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$NAME" | tr ' ' '\n' | grep -qx "$HOME"; then
  not_ok "host home directory is not mounted"
else
  ok "host home directory is not mounted"
fi

# ---------------------------------------------------------------------------
echo "== (g) wrapper stdout"
out="$(cd "$PROJECT" && "$WRAPPER" /fake/native-binary/claude --version 2>"$WORK/wrapper.err")"
if printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+ \(Claude Code\)$' && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then
  ok "claude-box-exec /fake/native-binary/claude --version prints only the version ($out)"
else
  not_ok "claude-box-exec --version prints only the version" "stdout: $out"$'\n'"stderr: $(cat "$WORK/wrapper.err")"
fi

# ---------------------------------------------------------------------------
echo "== extra: host services are unreachable from the internal network"
port=$((20000 + RANDOM % 10000))
if command -v python3 >/dev/null 2>&1; then
  python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 &
  HOST_LISTENER_PID=$!
  sleep 1
  # Positive control: from a container on the default bridge the listener is
  # reachable, so the checks below are not passing because nothing listens.
  gw="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
  if docker run --rm --entrypoint bash "$(docker inspect --format '{{.Config.Image}}' "$NAME")" \
    -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$gw/$port'" >/dev/null 2>&1; then
    ok "control: host listener is reachable from the default bridge ($gw:$port)"
  else
    skip "control: host listener reachable from the default bridge" "host firewall blocks it anyway"
  fi
  for ip in "$PREFIX3.1" "$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"; do
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
tunnels_before="$(docker logs cbit-proxy 2>/dev/null | grep -c 'TCP_TUNNEL.*CONNECT api.anthropic.com:443' || true)"
out="$(cd "$PROJECT" && ANTHROPIC_API_KEY=sk-ant-api03-claude-box-invalid-key "$WRAPPER" -p "say hi" 2>&1 </dev/null || true)"
tunnels_after="$(docker logs cbit-proxy 2>/dev/null | grep -c 'TCP_TUNNEL.*CONNECT api.anthropic.com:443' || true)"
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
v="$(docker exec cbit-proxy sh -c 'grep CapEff /proc/1/status' | awk '{print $2}')"
[ "$v" = "0000000000000000" ] && ok "squid runs without capabilities" || not_ok "squid runs without capabilities" "$v"
v="$(docker exec cbit-proxy id -un)"
[ "$v" = proxy ] && ok "squid runs as the unprivileged proxy user" || not_ok "squid runs as proxy" "$v"
v="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' cbit-proxy)"
[ "$v" = true ] && ok "proxy root filesystem is read-only" || not_ok "proxy root filesystem is read-only" "$v"
logs="$(cd "$PROJECT" && "$CLI" logs 2>&1 || true)"
case "$logs" in
  *TCP_DENIED*example.com*) ok "claude-box logs shows the denied request" ;;
  *) not_ok "claude-box logs shows the denied request" "$logs" ;;
esac

echo "== extra: allowlist changes apply without restarting the proxy"
before="$(in_box "curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://packagist.org/" 2>&1 || true)"
allow_out="$("$CLI" allow packagist.org 2>&1 || true)"
after="$(in_box "curl -s -o /dev/null -w '%{http_code}' --max-time 30 https://packagist.org/" 2>&1 || true)"
case "$before:$after" in
  000:[1-5][0-9][0-9] | 403:[1-5][0-9][0-9])
    if [ "$after" != 403 ]; then
      ok "claude-box allow takes effect immediately (before: $before, after: HTTP $after)"
    else
      not_ok "claude-box allow takes effect immediately" "before $before, after $after"$'\n'"$allow_out"
    fi
    ;;
  *) not_ok "claude-box allow takes effect immediately" "before $before, after $after"$'\n'"$allow_out" ;;
esac
case "$allow_out" in
  *"proxy reloaded"*) ok "the reload is confirmed by squid" ;;
  *) not_ok "the reload is confirmed by squid" "$allow_out" ;;
esac

echo "== extra: per-project home volumes"
in_box 'echo "project-a" > ~/.claude/marker' || true
(cd "$PROJECT_B" && "$CLI" up >/dev/null 2>&1) || not_ok "second project container starts"
NAME_B="$(container_name "$PROJECT_B")"
if docker exec "$NAME_B" test -e /home/claude/.claude/marker 2>/dev/null; then
  not_ok "one project's ~/.claude is invisible to another"
else
  ok "one project's ~/.claude is invisible to another"
fi
if docker exec "$NAME_B" test -e "$PROJECT/.env" 2>/dev/null; then
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
docker rm -f "$NAME" >/dev/null 2>&1 || true
out="$(cd "$PROJECT" && "$WRAPPER" --version 2>&1)" && st=0 || st=$?
if [ "$st" != 0 ] && ! docker inspect "$NAME" >/dev/null 2>&1; then
  ok "a file name with a comma cannot inject mount options (start refused)"
else
  not_ok "a file name with a comma cannot inject mount options" "status $st: $out"
fi
rm -rf "$evil"
(cd "$PROJECT" && "$CLI" up >/dev/null 2>&1) || not_ok "container comes back after removing the bad name"

echo "== extra: fail closed"
out="$(cd "$PROJECT" && DOCKER_HOST=unix:///nonexistent.sock "$WRAPPER" --version 2>/dev/null)" && st=0 || st=$?
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

if printf ' %s ' "${CLAUDE_BOX_IT_PROFILES:-}" | grep -q ' php '; then
  echo "== profile php"
  PHP_PROJECT="$WORK/php-project"
  mkdir -p "$PHP_PROJECT"
  mkdir -p "$XDG_CONFIG_HOME/claude-box/projects"
  php_name="$(container_name "$PHP_PROJECT")"
  echo 'PROFILE=php' >"$XDG_CONFIG_HOME/claude-box/projects/$php_name.conf"
  if (cd "$PHP_PROJECT" && "$CLI" up) >"$WORK/php-up.log" 2>&1; then
    ok "php profile container starts"
    v="$(docker exec "$php_name" php -m 2>&1 | tr '\n' ' ')"
    missing=""
    for m in curl gd intl mbstring mysqli pdo_mysql xml zip; do
      printf ' %s ' "$v" | grep -qi " $m " || missing="$missing $m"
    done
    [ -z "$missing" ] && ok "PHP $(docker exec "$php_name" php -r 'echo PHP_VERSION;') has the PrestaShop extensions" ||
      not_ok "PHP extensions present" "missing:$missing"
    docker exec "$php_name" mysql --version >/dev/null 2>&1 && ok "mariadb client present" || not_ok "mariadb client present"
    preset_out="$("$CLI" preset php on 2>&1 || true)"
    out="$(docker exec -w "$PHP_PROJECT" "$php_name" composer show --all --no-interaction monolog/monolog 2>&1 || true)"
    case "$out" in
      *"name "*monolog/monolog*) ok "composer reaches packagist through the proxy without DNS" ;;
      *) not_ok "composer reaches packagist through the proxy without DNS" "preset: $preset_out"$'\n'"$(printf '%s\n' "$out" | tail -n 5)"$'\n'"allowlist: $(tr '\n' ' ' <"$XDG_STATE_HOME/claude-box/proxy/allowlist")" ;;
    esac
    "$CLI" preset php off >/dev/null 2>&1 || true
  else
    not_ok "php profile container starts" "$(tail -n 20 "$WORK/php-up.log")"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
