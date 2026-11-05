# shellcheck shell=bash
# shellcheck disable=SC2034 # settings and paths defined here are read by the scripts that source this file
# Shared functions for claude-box-exec and claude-box.
#
# Must run on bash 3.2 with BSD or GNU userland: no associative arrays, no
# mapfile, no ${var,,}, no flock/timeout/readlink -f/stat -c/sed -i.
# Empty arrays are expanded as ${a[@]+"${a[@]}"} because bash < 4.4 treats
# "${a[@]}" of an empty array as unbound under `set -u`.

CB_VERSION="0.1.0"

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

cb_init_paths() {
  if [ -z "${HOME:-}" ]; then
    echo "claude-box: HOME is not set" >&2
    exit 1
  fi
  CB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-box"
  CB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-box"
  CB_CONFIG_FILE="$CB_CONFIG_DIR/config"
  CB_PROJECTS_DIR="$CB_CONFIG_DIR/projects"
  CB_TOKEN_FILE="$CB_CONFIG_DIR/token"
  CB_ALLOW_FILE="$CB_CONFIG_DIR/allowlist"
  CB_LOG_FILE="$CB_STATE_DIR/wrapper.log"
  CB_LOCK_DIR="$CB_STATE_DIR/locks"
  CB_PROXY_STATE_DIR="$CB_STATE_DIR/proxy"
  CB_EMPTY_FILE="$CB_STATE_DIR/empty"
}

# Resolve symlinks of a path without `readlink -f` (absent on older macOS).
cb_resolve_path() {
  local p="$1" link n=0 dir
  while [ -L "$p" ]; do
    n=$((n + 1))
    if [ "$n" -gt 40 ]; then
      return 1
    fi
    link="$(readlink "$p")"
    case "$link" in
      /*) p="$link" ;;
      *) p="$(dirname "$p")/$link" ;;
    esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  if [ "$dir" = "/" ]; then
    printf '/%s\n' "$(basename "$p")"
  else
    printf '%s/%s\n' "$dir" "$(basename "$p")"
  fi
}

# Lexically normalise an absolute path: collapse //, /./ and /../.
cb_normalize_path() {
  local path="$1" part out=""
  local IFS=/
  # shellcheck disable=SC2086 # word splitting on / is the point here
  set -f
  for part in $path; do
    case "$part" in
      "" | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  set +f
  printf '%s\n' "${out:-/}"
}

# cb_path_inside DIR PATH - true when PATH (absolute or relative to DIR) is DIR
# itself or below it, after normalisation and, where possible, symlink
# resolution.
cb_path_inside() {
  local dir="$1" path="$2" resolved
  case "$path" in
    /*) ;;
    *) path="$dir/$path" ;;
  esac
  path="$(cb_normalize_path "$path")"
  if [ -e "$path" ] || [ -L "$path" ]; then
    resolved="$(cb_resolve_path "$path" 2>/dev/null)" || resolved="$path"
    case "$resolved" in
      "$dir" | "$dir"/*) ;;
      *)
        # The project itself may live under a symlinked path (e.g. /tmp on
        # macOS); compare against the physical project path too.
        local pdir
        pdir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
        case "$resolved" in
          "$pdir" | "$pdir"/*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
  fi
  case "$path" in
    "$dir" | "$dir"/*) return 0 ;;
  esac
  return 1
}

# --------------------------------------------------------------------------
# Logging. Nothing here ever writes to stdout.
# --------------------------------------------------------------------------

CB_LOG_STDERR="${CLAUDE_BOX_DEBUG:-0}"

cb_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

cb_log() {
  if [ -n "${CB_LOG_FILE:-}" ]; then
    printf '%s [%s] %s\n' "$(cb_timestamp)" "$$" "$*" >>"$CB_LOG_FILE" 2>/dev/null || true
  fi
  if [ "$CB_LOG_STDERR" = "1" ]; then
    printf 'claude-box: %s\n' "$*" >&2
  fi
}

cb_warn() {
  cb_log "WARNING: $*"
  if [ "$CB_LOG_STDERR" != "1" ]; then
    printf 'claude-box: warning: %s\n' "$*" >&2
  fi
}

cb_die() {
  cb_log "ERROR: $*"
  if [ "$CB_LOG_STDERR" != "1" ]; then
    printf 'claude-box: error: %s\n' "$*" >&2
  fi
  exit 1
}

# Create state directories and the log file. Falls back to no log file (and
# says so on stderr) rather than failing, because logging is diagnostics.
cb_init_state() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  if mkdir -p "$CB_STATE_DIR" "$CB_LOCK_DIR" 2>/dev/null && : >>"$CB_LOG_FILE" 2>/dev/null; then
    :
  else
    printf 'claude-box: warning: cannot write %s; logging to stderr only\n' "$CB_LOG_FILE" >&2
    CB_LOG_FILE=""
    CB_LOG_STDERR=1
  fi
  if [ ! -f "$CB_EMPTY_FILE" ]; then
    : >"$CB_EMPTY_FILE" 2>/dev/null || true
  fi
  chmod 444 "$CB_EMPTY_FILE" 2>/dev/null || true
  umask "$old_umask"
}

# Quote an argument list for the log.
cb_quote_args() {
  local out="" a
  for a in "$@"; do
    out="$out $(printf '%q' "$a")"
  done
  printf '%s\n' "${out# }"
}

# --------------------------------------------------------------------------
# Configuration: KEY=VALUE files, never sourced.
# --------------------------------------------------------------------------

CB_CONFIG_KEYS="SUBNET PROXY_IP UPSTREAM_PROXY PROXY_PRESETS PROFILE BUILD_PROFILES
CLAUDE_CODE_VERSION BASE_IMAGE PROXY_BASE_IMAGE BUILD_NETWORK MEMORY CPUS PIDS_LIMIT
TMP_SIZE MASK_DEFAULTS MASK MASK_PRESETS READONLY_DEFAULTS READONLY GIT_WRITABLE
NONESSENTIAL_TRAFFIC CLAUDEAI_CONNECTORS AUTO_GUARD CONTAINER_UID CONTAINER_GID
EXTENSION_DIRS"

# Keys a per-project file may override. Network and build settings are global.
CB_PROJECT_KEYS="PROFILE MEMORY CPUS PIDS_LIMIT TMP_SIZE MASK_DEFAULTS MASK MASK_PRESETS
READONLY_DEFAULTS READONLY GIT_WRITABLE NONESSENTIAL_TRAFFIC CLAUDEAI_CONNECTORS"

cb_config_defaults() {
  CFG_SUBNET="172.30.99.0/24"
  CFG_PROXY_IP="172.30.99.2"
  CFG_UPSTREAM_PROXY=""
  CFG_PROXY_PRESETS=""
  CFG_PROFILE="base"
  CFG_BUILD_PROFILES=""
  CFG_CLAUDE_CODE_VERSION="2.1.318"
  CFG_BASE_IMAGE="node:22-bookworm-slim"
  CFG_PROXY_BASE_IMAGE="debian:bookworm-slim"
  CFG_BUILD_NETWORK=""
  CFG_MEMORY="4g"
  CFG_CPUS="2"
  CFG_PIDS_LIMIT="512"
  CFG_TMP_SIZE="1g"
  CFG_MASK_DEFAULTS=".env .env.*"
  CFG_MASK=""
  CFG_MASK_PRESETS=""
  CFG_READONLY_DEFAULTS=".git .vscode .agent .agents .idea .devcontainer"
  CFG_READONLY=""
  CFG_GIT_WRITABLE="0"
  CFG_NONESSENTIAL_TRAFFIC="0"
  CFG_CLAUDEAI_CONNECTORS="0"
  CFG_AUTO_GUARD="1"
  CFG_CONTAINER_UID=""
  CFG_CONTAINER_GID=""
  CFG_EXTENSION_DIRS=""
}

cb_word_in() {
  local w="$1" x
  shift
  # shellcheck disable=SC2048 # intentional word splitting of the list
  for x in $*; do
    if [ "$x" = "$w" ]; then
      return 0
    fi
  done
  return 1
}

# cb_read_config FILE ALLOWED_KEYS
cb_read_config() {
  local file="$1" allowed="$2" line key value n=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "" | "#"*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) cb_die "$file:$n: expected KEY=VALUE" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    if ! cb_word_in "$key" "$allowed"; then
      cb_die "$file:$n: unknown or not allowed setting '$key'"
    fi
    printf -v "CFG_$key" '%s' "$value"
  done <"$file"
}

cb_load_config() {
  cb_config_defaults
  cb_read_config "$CB_CONFIG_FILE" "$CB_CONFIG_KEYS"
  if [ -n "${CB_PROJECT_CONFIG:-}" ]; then
    cb_read_config "$CB_PROJECT_CONFIG" "$CB_PROJECT_KEYS"
  fi
  cb_validate_config
}

cb_validate_config() {
  case "$CFG_SUBNET" in
    *[!0-9./]* | "") cb_die "invalid SUBNET '$CFG_SUBNET'" ;;
  esac
  case "$CFG_PROXY_IP" in
    *[!0-9.]* | "") cb_die "invalid PROXY_IP '$CFG_PROXY_IP'" ;;
  esac
  case "$CFG_PROFILE" in
    *[!a-z0-9_-]* | "") cb_die "invalid PROFILE '$CFG_PROFILE'" ;;
  esac
  case "$CFG_PIDS_LIMIT" in
    *[!0-9]* | "") cb_die "invalid PIDS_LIMIT '$CFG_PIDS_LIMIT'" ;;
  esac
  case "$CFG_GIT_WRITABLE$CFG_NONESSENTIAL_TRAFFIC$CFG_CLAUDEAI_CONNECTORS$CFG_AUTO_GUARD" in
    *[!01]*) cb_die "GIT_WRITABLE, NONESSENTIAL_TRAFFIC, CLAUDEAI_CONNECTORS and AUTO_GUARD must be 0 or 1" ;;
  esac
}

# Set one key in a config file, keeping other lines. No sed -i (BSD/GNU differ).
cb_config_set() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  if [ -f "$file" ]; then
    grep -v "^[[:space:]]*$key=" "$file" >"$tmp" || true
  else
    : >"$tmp"
  fi
  printf '%s="%s"\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

# --------------------------------------------------------------------------
# Hashing and naming
# --------------------------------------------------------------------------

cb_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256)"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 | awk '{print $NF}')"
  else
    cb_die "no sha256 tool found (sha256sum, shasum or openssl)"
  fi
  printf '%s\n' "${out%% *}"
}

# Docker names: [a-zA-Z0-9][a-zA-Z0-9_.-]*
cb_sanitize_name() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
  # strip leading characters that are not alphanumeric
  while [ -n "$s" ]; do
    case "$s" in
      [a-z0-9]*) break ;;
      *) s="${s#?}" ;;
    esac
  done
  s="$(printf '%s' "$s" | cut -c1-40)"
  # trailing separators look odd before the hash
  while [ -n "$s" ]; do
    case "$s" in
      *[-_.]) s="${s%?}" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "${s:-project}"
}

cb_project_hash() {
  printf '%s' "$1" | cb_sha256 | cut -c1-8
}

cb_container_name() {
  printf '%s-%s-%s\n' "${CB_INSTANCE:-claude-box}" "$(cb_sanitize_name "$(basename "$1")")" "$(cb_project_hash "$1")"
}

# CLAUDE_BOX_INSTANCE namespaces every Docker object claude-box creates. It
# exists so the integration tests can run next to a real installation; normal
# use never sets it.
CB_INSTANCE="${CLAUDE_BOX_INSTANCE:-claude-box}"
case "$CB_INSTANCE" in
  *[!a-z0-9-]* | "" | -*)
    echo "claude-box: invalid CLAUDE_BOX_INSTANCE '$CB_INSTANCE'" >&2
    exit 1
    ;;
esac
CB_NETWORK_INTERNAL="$CB_INSTANCE-internal"
CB_NETWORK_EGRESS="$CB_INSTANCE-egress"
CB_PROXY_NAME="$CB_INSTANCE-proxy"
CB_PROXY_IMAGE="$CB_INSTANCE/proxy:latest"

cb_image_for_profile() {
  printf '%s/%s:latest\n' "$CB_INSTANCE" "$1"
}

# --------------------------------------------------------------------------
# Project directory
# --------------------------------------------------------------------------

# Validate the project directory (PWD) and set CB_PROJECT_DIR, CB_NAME,
# CB_VOLUME, CB_PROJECT_CONFIG.
cb_set_project() {
  local dir="$1" phys sensitive
  case "$dir" in
    /*) ;;
    *) cb_die "project directory '$dir' is not an absolute path" ;;
  esac
  [ -d "$dir" ] || cb_die "project directory '$dir' does not exist"
  case "$dir" in
    *,* | *'"'* | *"
"*) cb_die "project path '$dir' contains a comma, quote or newline, which docker --mount cannot express safely" ;;
  esac
  dir="$(cb_normalize_path "$dir")"
  phys="$(cd -P "$dir" && pwd -P)" || cb_die "cannot resolve '$dir'"

  local home_phys
  home_phys="$(cd -P "$HOME" 2>/dev/null && pwd -P)" || home_phys="$HOME"
  local d
  for d in "$dir" "$phys"; do
    if [ "$d" = "/" ]; then
      cb_die "refusing to use / as the project directory (open a project folder in the IDE)"
    fi
    case "$HOME/" in
      "$d"/*) cb_die "refusing to mount '$d': it is the home directory or contains it (open a project folder in the IDE)" ;;
    esac
    case "$home_phys/" in
      "$d"/*) cb_die "refusing to mount '$d': it is the home directory or contains it (open a project folder in the IDE)" ;;
    esac
    for sensitive in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.docker" "$HOME/.kube" \
      "$HOME/.config" "$HOME/.local" "$HOME/Library" "$CB_CONFIG_DIR" "$CB_STATE_DIR"; do
      case "$d/" in
        "$sensitive"/*) cb_die "refusing to mount '$d': it is inside $sensitive" ;;
      esac
    done
  done

  CB_PROJECT_DIR="$dir"
  CB_NAME="$(cb_container_name "$dir")"
  CB_VOLUME="$CB_NAME-home"
  CB_PROJECT_CONFIG="$CB_PROJECTS_DIR/$CB_NAME.conf"
}

# --------------------------------------------------------------------------
# Docker
# --------------------------------------------------------------------------

# The IDE's environment on macOS is the GUI launch environment, whose PATH may
# lack /usr/local/bin or /opt/homebrew/bin.
cb_find_docker() {
  local c
  if [ -n "${CLAUDE_BOX_DOCKER:-}" ]; then
    CB_DOCKER="$CLAUDE_BOX_DOCKER"
  elif c="$(command -v docker 2>/dev/null)" && [ -n "$c" ]; then
    CB_DOCKER="$c"
  else
    CB_DOCKER=""
    for c in /usr/local/bin/docker /opt/homebrew/bin/docker "$HOME/.docker/bin/docker" \
      /Applications/Docker.app/Contents/Resources/bin/docker /usr/bin/docker \
      /opt/local/bin/docker /snap/bin/docker; do
      if [ -x "$c" ]; then
        CB_DOCKER="$c"
        break
      fi
    done
  fi
  if [ -z "$CB_DOCKER" ] || [ ! -x "$CB_DOCKER" ]; then
    cb_die "docker CLI not found (looked in PATH and the usual install locations); is Docker installed?"
  fi
  # Credential helpers and CLI plugins live next to the docker binary.
  case ":$PATH:" in
    *":$(dirname "$CB_DOCKER"):"*) ;;
    *) PATH="$(dirname "$CB_DOCKER"):$PATH"; export PATH ;;
  esac
  cb_log "docker: $CB_DOCKER (DOCKER_HOST=${DOCKER_HOST:-unset}, DOCKER_CONTEXT=${DOCKER_CONTEXT:-unset})"
}

cb_docker() {
  "$CB_DOCKER" "$@"
}

cb_docker_ready() {
  cb_docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

cb_require_docker() {
  if ! cb_docker_ready; then
    cb_die "cannot reach the Docker daemon - is Docker (Desktop) running? Nothing was started on the host."
  fi
}

# --------------------------------------------------------------------------
# Locking: atomic mkdir with a PID file (no flock on macOS).
# --------------------------------------------------------------------------

CB_HELD_LOCK=""

cb_lock() {
  local lock="$CB_LOCK_DIR/$1.lock" tries=0 pid
  mkdir -p "$CB_LOCK_DIR"
  while ! mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      cb_log "removing stale lock $lock (pid $pid is gone)"
      rm -rf "$lock"
      continue
    fi
    if [ -z "$pid" ] && [ "$tries" -gt 25 ]; then
      # Holder died between mkdir and writing its PID.
      cb_log "removing lock $lock without a pid file"
      rm -rf "$lock"
      continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 900 ]; then
      cb_die "timed out waiting for lock $lock (held by pid ${pid:-unknown})"
    fi
    sleep 0.2
  done
  echo "$$" >"$lock/pid"
  CB_HELD_LOCK="$lock"
  trap 'cb_unlock' EXIT
}

cb_unlock() {
  if [ -n "$CB_HELD_LOCK" ]; then
    rm -rf "$CB_HELD_LOCK"
    CB_HELD_LOCK=""
  fi
}

# --------------------------------------------------------------------------
# Masks and read-only paths
# --------------------------------------------------------------------------

cb_mask_preset_patterns() {
  case "$1" in
    prestashop) echo "app/config/parameters.php app/config/parameters.yml config/settings.inc.php" ;;
    *) cb_die "unknown mask preset '$1' (known: prestashop)" ;;
  esac
}

cb_mask_patterns() {
  local p out="$CFG_MASK_DEFAULTS $CFG_MASK"
  for p in $CFG_MASK_PRESETS; do
    out="$out $(cb_mask_preset_patterns "$p")"
  done
  printf '%s\n' "$out"
}

cb_readonly_entries() {
  local out="$CFG_READONLY_DEFAULTS $CFG_READONLY" e res=""
  for e in $out; do
    if [ "$e" = ".git" ] && [ "$CFG_GIT_WRITABLE" = "1" ]; then
      continue
    fi
    res="$res $e"
  done
  printf '%s\n' "${res# }"
}

# Print absolute paths of existing files/dirs matching the mask patterns.
# A pattern containing "/" is anchored at the project root (shell glob);
# a pattern without "/" matches a name at any depth, skipping .git,
# node_modules and vendor. Symlinks are resolved; targets outside the project
# are skipped because they are not visible in the container anyway.
cb_find_masks() {
  local dir="$1" pat names="" f
  local -a find_expr
  find_expr=()
  set -f
  for pat in $(cb_mask_patterns); do
    case "$pat" in
      */*)
        set +f
        for f in "$dir"/$pat; do
          if [ -e "$f" ] || [ -L "$f" ]; then
            printf '%s\n' "$f"
          fi
        done
        set -f
        ;;
      *)
        if [ -n "$names" ]; then
          find_expr+=(-o)
        fi
        find_expr+=(-name "$pat")
        names=1
        ;;
    esac
  done
  set +f
  if [ -n "$names" ]; then
    find "$dir" \( -name .git -o -name node_modules -o -name vendor \) -prune \
      -o \( "${find_expr[@]}" \) -print 2>/dev/null
  fi
}

# Print mount specs, one per line: "KIND<TAB>PATH" where KIND is
# file (mask with empty file), dir (mask with tmpfs) or ro (read-only bind).
# Creates missing read-only directories on the host.
cb_compute_mounts() {
  local dir="$1" f target e path
  cb_find_masks "$dir" | sort -u | while IFS= read -r f; do
    target="$f"
    if [ -L "$f" ]; then
      target="$(cb_resolve_path "$f" 2>/dev/null)" || continue
      if ! cb_path_inside "$dir" "$target"; then
        cb_log "mask: $f is a symlink to $target outside the project; not visible in the container"
        continue
      fi
      [ -e "$target" ] || continue
    fi
    if [ -d "$target" ]; then
      printf 'dir\t%s\n' "$target"
    else
      printf 'file\t%s\n' "$target"
    fi
  done
  for e in $(cb_readonly_entries); do
    case "$e" in
      /* | *..*) cb_die "read-only entry '$e' must be a path relative to the project" ;;
    esac
    path="$dir/$e"
    if [ -L "$path" ]; then
      target="$(cb_resolve_path "$path" 2>/dev/null)" || target=""
      if [ -n "$target" ] && cb_path_inside "$dir" "$target" && [ -e "$target" ]; then
        printf 'ro\t%s\n' "$target"
      else
        cb_log "read-only: $path is a symlink pointing outside the project; it dangles in the container"
      fi
      continue
    fi
    if [ ! -e "$path" ]; then
      # Create it as the host user; otherwise the bind mount would make Docker
      # create it (as root on Linux), or Claude could create it writable.
      mkdir -p "$path" || cb_die "cannot create $path"
      cb_log "created missing read-only directory $path"
    fi
    printf 'ro\t%s\n' "$path"
  done
}

# --------------------------------------------------------------------------
# Container lifecycle
# --------------------------------------------------------------------------

cb_container_uid() {
  local uid gid
  uid="${CFG_CONTAINER_UID:-$(id -u)}"
  gid="${CFG_CONTAINER_GID:-$(id -g)}"
  if [ "$uid" = "0" ]; then
    uid=1000
  fi
  if [ "$gid" = "0" ]; then
    gid=1000
  fi
  printf '%s %s\n' "$uid" "$gid"
}

cb_cpus() {
  local want="$CFG_CPUS" have
  have="$(cb_docker info --format '{{.NCPU}}' 2>/dev/null || echo 1)"
  case "$have" in *[!0-9]* | "") have=1 ;; esac
  # docker refuses --cpus above the number of CPUs it sees
  if awk -v w="$want" -v h="$have" 'BEGIN { exit !(w > h) }'; then
    want="$have"
  fi
  printf '%s\n' "$want"
}

# Fill CB_RUN_ARGS with the full `docker run` argument list for the project.
cb_build_run_args() {
  local image="$1" kind path mounts
  local uidgid uid gid
  uidgid="$(cb_container_uid)"
  uid="${uidgid% *}"
  gid="${uidgid#* }"
  mounts="$(cb_compute_mounts "$CB_PROJECT_DIR")" || exit 1

  CB_RUN_ARGS=(
    run -d
    --name "$CB_NAME"
    --hostname claude-box
    --label "io.claude-box.project=$CB_PROJECT_DIR"
    --label "io.claude-box.managed=1"
    --network "$CB_NETWORK_INTERNAL"
    --dns 127.0.0.1
    --cap-drop ALL
    --security-opt no-new-privileges
    --read-only
    --tmpfs "/tmp:rw,nosuid,nodev,size=$CFG_TMP_SIZE"
    --pids-limit "$CFG_PIDS_LIMIT"
    --memory "$CFG_MEMORY"
    --cpus "$(cb_cpus)"
    --init
    --user "$uid:$gid"
    --env "HOME=/home/claude"
    --env "HTTPS_PROXY=http://$CFG_PROXY_IP:3128"
    --env "https_proxy=http://$CFG_PROXY_IP:3128"
    --env "HTTP_PROXY=http://$CFG_PROXY_IP:3128"
    --env "http_proxy=http://$CFG_PROXY_IP:3128"
    --env "NO_PROXY=localhost,127.0.0.1,::1"
    --env "no_proxy=localhost,127.0.0.1,::1"
    --env "DISABLE_AUTOUPDATER=1"
    --mount "type=volume,src=$CB_VOLUME,dst=/home/claude"
    --mount "type=bind,src=$CB_PROJECT_DIR,dst=$CB_PROJECT_DIR"
  )
  if [ "$CFG_NONESSENTIAL_TRAFFIC" = "0" ]; then
    CB_RUN_ARGS+=(--env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
  fi
  if [ "$CFG_CLAUDEAI_CONNECTORS" = "0" ]; then
    CB_RUN_ARGS+=(--env "ENABLE_CLAUDEAI_MCP_SERVERS=false")
  fi
  while IFS="$(printf '\t')" read -r kind path; do
    [ -n "$kind" ] || continue
    case "$kind" in
      file) CB_RUN_ARGS+=(--mount "type=bind,src=$CB_EMPTY_FILE,dst=$path,readonly") ;;
      dir) CB_RUN_ARGS+=(--mount "type=tmpfs,dst=$path,tmpfs-size=1048576") ;;
      ro) CB_RUN_ARGS+=(--mount "type=bind,src=$path,dst=$path,readonly") ;;
    esac
  done <<EOF
$mounts
EOF
  CB_RUN_ARGS+=("$image" sleep infinity)
}

# Busy = a claude process is running inside the container.
cb_container_busy() {
  local n
  n="$(cb_docker exec "$CB_NAME" ps -eo comm= 2>/dev/null | grep -c -x 'claude' || true)"
  [ "${n:-0}" -gt 0 ]
}

# Make sure the project container exists, runs and matches the current
# configuration. Must be called with stdout pointing away from the IDE.
cb_ensure_container() {
  local image image_id hash state running label
  image="$(cb_image_for_profile "$CFG_PROFILE")"
  cb_require_docker

  cb_lock "$CB_NAME"
  image_id="$(cb_docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" ||
    cb_die "image $image not found - run 'claude-box setup' (with --profile $CFG_PROFILE for a profile)"
  if ! cb_docker network inspect "$CB_NETWORK_INTERNAL" >/dev/null 2>&1; then
    cb_die "network $CB_NETWORK_INTERNAL not found - run 'claude-box setup'"
  fi

  cb_build_run_args "$image"
  hash="$( { printf '%s\n' "${CB_RUN_ARGS[@]}"; printf '%s\n' "$image_id"; } | cb_sha256 | cut -c1-16)"

  state="$(cb_docker inspect --format '{{.State.Running}} {{index .Config.Labels "io.claude-box.config"}}' "$CB_NAME" 2>/dev/null || true)"
  if [ -n "$state" ]; then
    running="${state%% *}"
    label="${state#* }"
    if [ "$label" != "$hash" ]; then
      if [ "$running" = "true" ] && cb_container_busy; then
        cb_die "container $CB_NAME runs with an outdated configuration (masks, image or settings changed) and a Claude session is active in it. Close the sessions and run 'claude-box up --recreate' in $CB_PROJECT_DIR."
      fi
      cb_log "configuration of $CB_NAME changed; recreating it"
      cb_docker rm -f "$CB_NAME" >/dev/null 2>&1 || cb_die "cannot remove outdated container $CB_NAME"
      # Recompute the mounts now that no process of the old container can
      # still be changing the project tree (e.g. planting symlinks between
      # our checks and `docker run`).
      cb_build_run_args "$image"
      hash="$( { printf '%s\n' "${CB_RUN_ARGS[@]}"; printf '%s\n' "$image_id"; } | cb_sha256 | cut -c1-16)"
      state=""
    elif [ "$running" != "true" ]; then
      cb_log "starting stopped container $CB_NAME"
      cb_docker start "$CB_NAME" >/dev/null 2>&1 || cb_die "cannot start container $CB_NAME (see 'docker start $CB_NAME')"
    fi
  fi
  if [ -z "$state" ]; then
    # Insert the config label right after "run -d".
    local -a args
    args=("${CB_RUN_ARGS[@]:0:2}" --label "io.claude-box.config=$hash" "${CB_RUN_ARGS[@]:2}")
    cb_log "creating container: docker $(cb_quote_args "${args[@]}")"
    local err
    if ! err="$(cb_docker "${args[@]}" 2>&1 >/dev/null)"; then
      cb_log "docker run failed: $err"
      cb_die "cannot create container $CB_NAME: $err"
    fi
  fi
  cb_unlock
}

# --------------------------------------------------------------------------
# Environment passed from the host into `docker exec`
# --------------------------------------------------------------------------

# Names that match the allowed prefixes but must not cross: they carry host
# paths, IDE connection details, or settings claude-box controls itself.
CB_ENV_DENY="CLAUDE_CONFIG_DIR CLAUDE_CODE_SSE_PORT CLAUDE_CODE_GIT_BASH_PATH CLAUDE_CODE_TMPDIR
CLAUDE_CODE_SHELL CLAUDE_CODE_SHELL_PREFIX CLAUDE_CODE_PROCESS_WRAPPER CLAUDE_CODE_CLIENT_CERT
CLAUDE_CODE_CLIENT_KEY CLAUDE_CODE_CLIENT_KEY_PASSPHRASE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
CLAUDE_CODE_DEBUG_LOGS_DIR CLAUDE_CODE_CERT_STORE"

# Print the names of host environment variables to pass to the container.
cb_env_passthrough() {
  local name value
  for name in $(compgen -e); do
    case "$name" in
      CLAUDE_CODE_IDE_*) continue ;;
      CLAUDE_CODE_* | CLAUDE_AGENT_SDK* | MCP_* | ANTHROPIC_* | MAX_THINKING_TOKENS) ;;
      *) continue ;;
    esac
    if cb_word_in "$name" "$CB_ENV_DENY"; then
      cb_log "env: not passing $name (deny list)"
      continue
    fi
    value="${!name}"
    case "$value" in
      /* | "~"*)
        if ! cb_path_inside "$CB_PROJECT_DIR" "$value"; then
          cb_log "env: not passing $name (value is a host path outside the project)"
          continue
        fi
        ;;
    esac
    printf '%s\n' "$name"
  done
}
