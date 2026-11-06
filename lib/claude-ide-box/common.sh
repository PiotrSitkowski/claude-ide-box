# shellcheck shell=bash
# shellcheck disable=SC2034 # settings and paths defined here are read by the scripts that source this file
# Shared functions for claude-ide-box-exec and claude-ide-box.
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
    echo "claude-ide-box: HOME is not set" >&2
    exit 1
  fi
  CB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-ide-box"
  CB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-ide-box"
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
        pdir="$(cb_phys_dir "$dir")" || return 1
        case "$resolved" in
          "$pdir" | "$pdir"/*) return 0 ;;
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

# Physical (symlink-free) spelling of DIR, cached for the project.
cb_phys_dir() {
  if [ "$1" = "${CB_PROJECT_DIR:-}" ] && [ -n "${CB_PROJECT_PHYS:-}" ]; then
    printf '%s\n' "$CB_PROJECT_PHYS"
  else
    (cd -P "$1" 2>/dev/null && pwd -P)
  fi
}

# cb_to_project_path DIR PATH - express a resolved PATH inside DIR through
# DIR's own spelling. The container mounts the project at the logical path the
# IDE uses (e.g. /tmp/x on macOS, where /tmp -> /private/tmp), so mount
# destinations must use it too.
cb_to_project_path() {
  local dir="$1" path="$2" pdir
  case "$path" in
    "$dir" | "$dir"/*) printf '%s\n' "$path"; return 0 ;;
  esac
  pdir="$(cb_phys_dir "$dir")" || pdir="$dir"
  case "$path" in
    "$pdir") printf '%s\n' "$dir" ;;
    "$pdir"/*) printf '%s%s\n' "$dir" "${path#"$pdir"}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

# --------------------------------------------------------------------------
# Logging. Nothing here ever writes to stdout.
# --------------------------------------------------------------------------

CB_LOG_STDERR="${CLAUDE_IDE_BOX_DEBUG:-0}"

cb_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

cb_log() {
  if [ -n "${CB_LOG_FILE:-}" ]; then
    printf '%s [%s] %s\n' "$(cb_timestamp)" "$$" "$*" >>"$CB_LOG_FILE" 2>/dev/null || true
  fi
  if [ "$CB_LOG_STDERR" = "1" ]; then
    printf 'claude-ide-box: %s\n' "$*" >&2
  fi
}

cb_warn() {
  cb_log "WARNING: $*"
  if [ "$CB_LOG_STDERR" != "1" ]; then
    printf 'claude-ide-box: warning: %s\n' "$*" >&2
  fi
}

cb_die() {
  cb_log "ERROR: $*"
  if [ "$CB_LOG_STDERR" != "1" ]; then
    printf 'claude-ide-box: error: %s\n' "$*" >&2
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
    printf 'claude-ide-box: warning: cannot write %s; logging to stderr only\n' "$CB_LOG_FILE" >&2
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
EXTENSION_DIRS CLAUDE_DIR_WRITABLE COPY_HISTORY COPY_HISTORY_MAX_SIZE COPY_HISTORY_MAX_TOTAL"

# Keys a per-project file may override. Network and build settings are global.
CB_PROJECT_KEYS="PROFILE MEMORY CPUS PIDS_LIMIT TMP_SIZE MASK_DEFAULTS MASK MASK_PRESETS
READONLY_DEFAULTS READONLY GIT_WRITABLE NONESSENTIAL_TRAFFIC CLAUDEAI_CONNECTORS
CLAUDE_DIR_WRITABLE COPY_HISTORY COPY_HISTORY_MAX_SIZE COPY_HISTORY_MAX_TOTAL"

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
  CFG_READONLY_DEFAULTS=".git .vscode .agent .agents .idea .devcontainer .claude"
  CFG_READONLY=""
  CFG_GIT_WRITABLE="0"
  CFG_CLAUDE_DIR_WRITABLE="0"
  CFG_COPY_HISTORY="0"
  CFG_COPY_HISTORY_MAX_SIZE="50m"
  CFG_COPY_HISTORY_MAX_TOTAL="1g"
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
    *[!a-z0-9_,\ -]*) cb_die "invalid PROFILE '$CFG_PROFILE' (profile names, separated by spaces or commas)" ;;
  esac
  case "$CFG_PIDS_LIMIT" in
    *[!0-9]* | "") cb_die "invalid PIDS_LIMIT '$CFG_PIDS_LIMIT'" ;;
  esac
  local v
  for v in "MEMORY=$CFG_MEMORY" "TMP_SIZE=$CFG_TMP_SIZE" "COPY_HISTORY_MAX_SIZE=$CFG_COPY_HISTORY_MAX_SIZE" \
    "COPY_HISTORY_MAX_TOTAL=$CFG_COPY_HISTORY_MAX_TOTAL"; do
    printf '%s\n' "${v#*=}" | grep -Eq '^[0-9]+[bkmgBKMG]?$' || cb_die "invalid ${v%%=*} '${v#*=}' (use e.g. 4g)"
  done
  printf '%s\n' "$CFG_CPUS" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || cb_die "invalid CPUS '$CFG_CPUS'"
  case "$CFG_CONTAINER_UID$CFG_CONTAINER_GID" in
    *[!0-9]*) cb_die "CONTAINER_UID and CONTAINER_GID must be numeric" ;;
  esac
  case "$CFG_GIT_WRITABLE$CFG_NONESSENTIAL_TRAFFIC$CFG_CLAUDEAI_CONNECTORS$CFG_AUTO_GUARD" in
    *[!01]*) cb_die "GIT_WRITABLE, NONESSENTIAL_TRAFFIC, CLAUDEAI_CONNECTORS and AUTO_GUARD must be 0 or 1" ;;
  esac
  case "$CFG_CLAUDE_DIR_WRITABLE$CFG_COPY_HISTORY" in
    *[!01]*) cb_die "CLAUDE_DIR_WRITABLE and COPY_HISTORY must be 0 or 1" ;;
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
  printf '%s-%s-%s\n' "${CB_INSTANCE:-claude-ide-box}" "$(cb_sanitize_name "$(basename "$1")")" "$(cb_project_hash "$1")"
}

# CLAUDE_IDE_BOX_INSTANCE namespaces every Docker object claude-ide-box creates. It
# exists so the integration tests can run next to a real installation; normal
# use never sets it.
CB_INSTANCE="${CLAUDE_IDE_BOX_INSTANCE:-claude-ide-box}"
case "$CB_INSTANCE" in
  *[!a-z0-9-]* | "" | -*)
    echo "claude-ide-box: invalid CLAUDE_IDE_BOX_INSTANCE '$CB_INSTANCE'" >&2
    exit 1
    ;;
esac
CB_NETWORK_INTERNAL="$CB_INSTANCE-internal"
CB_NETWORK_EGRESS="$CB_INSTANCE-egress"
CB_PROXY_NAME="$CB_INSTANCE-proxy"
CB_PROXY_IMAGE="$CB_INSTANCE/proxy:latest"

# Profiles are image layers stacked on the base image, e.g. PROFILE="python
# java". A profile is a directory with a Dockerfile that starts
# `FROM ${BASE_IMAGE}`: in ~/.config/claude-ide-box/profiles/<name> (the
# user's own, kept across updates) or image/profiles/<name> (shipped).

# cb_profile_list LIST - canonical form: sorted, unique, without "base".
cb_profile_list() {
  local p out=""
  for p in $(printf '%s\n' "$1" | tr ',' ' '); do
    [ "$p" = base ] || out="$out$p
"
  done
  printf '%s' "$out" | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# cb_profile_dir NAME - directory holding the profile's Dockerfile.
cb_profile_dir() {
  case "$1" in
    "" | *[!a-z0-9_-]*) return 1 ;;
  esac
  if [ -f "$CB_CONFIG_DIR/profiles/$1/Dockerfile" ]; then
    printf '%s\n' "$CB_CONFIG_DIR/profiles/$1"
  elif [ -f "$CB_ROOT/image/profiles/$1/Dockerfile" ]; then
    printf '%s\n' "$CB_ROOT/image/profiles/$1"
  else
    return 1
  fi
}

# cb_require_profiles LIST - fail closed on a profile that does not exist.
cb_require_profiles() {
  local p
  for p in $(cb_profile_list "$1"); do
    cb_profile_dir "$p" >/dev/null ||
      cb_die "unknown profile '$p' ('claude-ide-box profiles' lists the available ones)"
  done
}

# cb_image_for_profile LIST - image for a profile combination.
cb_image_for_profile() {
  local list
  list="$(cb_profile_list "$1")"
  if [ -z "$list" ]; then
    printf '%s/base:latest\n' "$CB_INSTANCE"
  else
    printf '%s/env:%s\n' "$CB_INSTANCE" "$(printf '%s' "$list" | tr ' ' '.')"
  fi
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
  local d h
  for d in "$dir" "$phys"; do
    if [ "$d" = "/" ]; then
      cb_die "refusing to use / as the project directory (open a project folder in the IDE)"
    fi
    for h in "$HOME" "$home_phys"; do
      case "$h/" in
        "$d"/*) cb_die "refusing to mount '$d': it is the home directory or contains it (open a project folder in the IDE)" ;;
      esac
    done
    for sensitive in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.docker" "$HOME/.kube" \
      "$HOME/.config" "$HOME/.local" "$HOME/Library" "$CB_CONFIG_DIR" "$CB_STATE_DIR"; do
      case "$d/" in
        "$sensitive"/*) cb_die "refusing to mount '$d': it is inside $sensitive" ;;
      esac
    done
  done

  CB_PROJECT_DIR="$dir"
  CB_PROJECT_PHYS="$phys"
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
  if [ -n "${CLAUDE_IDE_BOX_DOCKER:-}" ]; then
    CB_DOCKER="$CLAUDE_IDE_BOX_DOCKER"
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

cb_require_network() {
  cb_docker network inspect "$CB_NETWORK_INTERNAL" >/dev/null 2>&1 ||
    cb_die "network $CB_NETWORK_INTERNAL not found - run 'claude-ide-box setup'"
}

# Print "<internal> <options> <subnet>" of the internal network, or nothing.
cb_internal_network_info() {
  cb_docker network inspect --format '{{.Internal}} {{.Options}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' \
    "$CB_NETWORK_INTERNAL" 2>/dev/null || true
}

cb_proxy_running() {
  [ "$(cb_docker inspect --format '{{.State.Running}}' "$CB_PROXY_NAME" 2>/dev/null || true)" = "true" ]
}

# Export CLAUDE_CODE_OAUTH_TOKEN from the token file, if it holds one.
cb_export_token() {
  local token=""
  [ -f "$CB_TOKEN_FILE" ] || return 0
  IFS= read -r token <"$CB_TOKEN_FILE" || true
  if [ -n "$token" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$token"
    export CLAUDE_CODE_OAUTH_TOKEN
  fi
}

# cb_toggle_word LIST WORD on|off - print LIST with WORD removed, and
# appended again when on.
cb_toggle_word() {
  local out="" w
  for w in $1; do
    [ "$w" = "$2" ] || out="$out $w"
  done
  [ "$3" != on ] || out="$out $2"
  printf '%s\n' "${out# }"
}

# --------------------------------------------------------------------------
# Locking: atomic mkdir with a PID file (no flock on macOS).
# --------------------------------------------------------------------------

CB_HELD_LOCK=""

cb_lock() {
  local lock="$CB_LOCK_DIR/$1.lock" tries=0 pid empty=0 seen="" inode
  mkdir -p "$CB_LOCK_DIR"
  while ! mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      # Only one waiter may reap, and only the lock it judged stale: another
      # waiter may already have reaped it and taken a fresh one.
      if mkdir "$lock.reap" 2>/dev/null; then
        if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$pid" ]; then
          cb_log "removing stale lock $lock (pid $pid is gone)"
          rm -rf "$lock"
        fi
        rmdir "$lock.reap" 2>/dev/null || true
      fi
      continue
    fi
    if [ -z "$pid" ]; then
      # Every new holder has no pid file for an instant after its mkdir. Only
      # the same lock directory (same inode) seen without a pid on more than
      # 25 polls in a row means its holder died before writing one.
      inode="$(cb_inode "$lock")"
      if [ -n "$inode" ] && [ "$inode" = "$seen" ]; then
        empty=$((empty + 1))
      else
        empty=1
        seen="$inode"
      fi
      if [ "$empty" -gt 25 ] && mkdir "$lock.reap" 2>/dev/null; then
        if [ -z "$(cat "$lock/pid" 2>/dev/null || true)" ] && [ "$(cb_inode "$lock")" = "$seen" ]; then
          cb_log "removing lock $lock without a pid file"
          rm -rf "$lock"
        fi
        rmdir "$lock.reap" 2>/dev/null || true
        empty=0
        continue
      fi
    else
      empty=0
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
    if [ "$e" = ".claude" ] && [ "$CFG_CLAUDE_DIR_WRITABLE" = "1" ]; then
      continue
    fi
    res="$res $e"
  done
  printf '%s\n' "${res# }"
}

CB_NL='
'
CB_CR="$(printf '\r')"
CB_TAB="$(printf '\t')"

# Print NUL-terminated absolute paths of existing files/dirs matching the mask
# patterns. A pattern containing "/" is anchored at the project root (shell
# glob); a pattern without "/" matches a name at any depth. Nothing is pruned:
# the container can move files into any directory, so every directory counts.
# With a second argument, every ".git" is printed too (one walk for both).
cb_find_masks() {
  local dir="$1" with_git="${2:-}" pat names="" f
  local -a find_expr
  find_expr=()
  set -f
  for pat in $(cb_mask_patterns); do
    case "$pat" in
      */*)
        set +f
        for f in "$dir"/$pat; do
          if [ -e "$f" ] || [ -L "$f" ]; then
            printf '%s\0' "$f"
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
  if [ -n "$with_git" ]; then
    if [ -n "$names" ]; then
      find_expr+=(-o)
    fi
    find_expr+=(-name .git)
    names=1
  fi
  if [ -n "$names" ]; then
    find "$dir" \( "${find_expr[@]}" \) -print0 2>/dev/null || true
  fi
}

# Emit one mount spec line. Paths that docker's CSV-parsed --mount syntax (or
# this line-based list) cannot carry safely are emitted as "bad" so that the
# caller fails closed; a comma would otherwise let a file name inject mount
# options such as src=/home/user/.ssh.
cb_emit_mount() {
  case "$2" in
    *,* | *'"'* | *"$CB_NL"* | *"$CB_CR"* | *"$CB_TAB"*)
      printf 'bad\t%s\n' "$(printf '%s' "$2" | tr '\n\r\t' '???')"
      ;;
    *) printf '%s\t%s\n' "$1" "$2" ;;
  esac
}

# Print mount specs, one per line: "KIND<TAB>PATH" where KIND is
# file (mask with empty file), dir (mask with tmpfs), ro (read-only bind) or
# bad (a path that cannot be mounted safely).
# Creates missing read-only directories on the host.
cb_compute_mounts() {
  local dir="$1" f target e path with_git=""
  # Nested repositories: git and the IDE on the host run hooks and config such
  # as core.fsmonitor from them too, so every .git below the root is read-only.
  [ "$CFG_GIT_WRITABLE" = "1" ] || with_git=1
  cb_find_masks "$dir" "$with_git" | while IFS= read -r -d '' f; do
    case "$f" in
      "$dir/.git") continue ;;
      */.git)
        [ -L "$f" ] || cb_emit_mount ro "$f"
        continue
        ;;
    esac
    target="$f"
    if [ -L "$f" ]; then
      target="$(cb_resolve_path "$f" 2>/dev/null)" || continue
      if ! cb_path_inside "$dir" "$target"; then
        cb_log "mask: $f is a symlink to $target outside the project; not visible in the container"
        continue
      fi
      [ -e "$target" ] || continue
      target="$(cb_to_project_path "$dir" "$target")"
    fi
    if [ -d "$target" ]; then
      cb_emit_mount dir "$target"
    else
      cb_emit_mount file "$target"
    fi
  done | sort -u
  for e in $(cb_readonly_entries); do
    case "$e" in
      /* | *..*) cb_die "read-only entry '$e' must be a path relative to the project" ;;
    esac
    path="$dir/$e"
    # A symlinked parent directory would make docker bind a host path
    # outside the project.
    if ! cb_path_inside "$dir" "$(dirname "$path")"; then
      cb_log "read-only: parent of $path resolves outside the project; skipped"
      continue
    fi
    if [ -L "$path" ]; then
      target="$(cb_resolve_path "$path" 2>/dev/null)" || target=""
      if [ -n "$target" ] && cb_path_inside "$dir" "$target" && [ -e "$target" ]; then
        cb_emit_mount ro "$(cb_to_project_path "$dir" "$target")"
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
    cb_emit_mount ro "$path"
  done
}

# File listing the paths masked when the container was last created.
cb_mask_record() {
  printf '%s/masks/%s.list\n' "$CB_STATE_DIR" "$CB_NAME"
}

# Inode number of a path, empty if it does not exist (ls -di works on BSD,
# GNU and busybox; stat does not have portable flags).
cb_inode() {
  if [ -e "$1" ]; then
    # shellcheck disable=SC2012 # ls -di is the portable way to read an inode
    ls -di "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# A path masked last time that no longer exists, or now is a different file,
# was moved or replaced. From
# inside the container that is possible by renaming a parent directory, which
# would unmask the file when the container is recreated. Fail closed unless the
# user recreates the container explicitly (`up --recreate` sets
# CB_ACCEPT_MASK_CHANGES=1).
cb_check_mask_record() {
  local record p missing=""
  record="$(cb_mask_record)"
  [ -f "$record" ] || return 0
  [ "${CB_ACCEPT_MASK_CHANGES:-0}" != "1" ] || return 0
  local inode now
  while IFS="$CB_TAB" read -r inode p; do
    [ -n "$p" ] || continue
    now="$(cb_inode "$p")"
    # A different inode means the original was moved away and something else
    # put in its place.
    if [ "$now" != "$inode" ]; then
      missing="$missing $p"
    fi
  done <"$record"
  if [ -n "$missing" ]; then
    cb_die "masked path(s) were moved, replaced or deleted:$missing - this can be an attempt from inside the container to escape a mask. Check the project; if you moved or deleted them yourself, run 'claude-ide-box up --recreate' in $CB_PROJECT_DIR."
  fi
}

cb_write_mask_record() {
  local record
  record="$(cb_mask_record)"
  mkdir -p "$(dirname "$record")"
  local kind path
  while IFS="$CB_TAB" read -r kind path; do
    case "$kind" in
      file | dir) printf '%s\t%s\n' "$(cb_inode "$path")" "$path" ;;
    esac
  done >"$record.tmp" <<CB_END
$CB_MOUNTS
CB_END
  mv "$record.tmp" "$record"
}

# --------------------------------------------------------------------------
# Container lifecycle
# --------------------------------------------------------------------------

# Set CB_UID/CB_GID: the container user's IDs (the host user's, or 1000
# when claude-ide-box runs as root, or CONTAINER_UID/CONTAINER_GID).
cb_container_uid() {
  CB_UID="${CFG_CONTAINER_UID:-$(id -u)}"
  CB_GID="${CFG_CONTAINER_GID:-$(id -g)}"
  [ "$CB_UID" != "0" ] || CB_UID=1000
  [ "$CB_GID" != "0" ] || CB_GID=1000
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

# Fill CB_RUN_ARGS with the `docker run` options for the project (without
# "run -d", the config label and the image, which cb_ensure_container adds).
# Everything in it goes into the config hash; --cpus holds the configured
# value and is clamped only when the container is created.
cb_build_run_args() {
  local kind path
  cb_container_uid
  CB_MOUNTS="$(cb_compute_mounts "$CB_PROJECT_DIR")" || exit 1

  CB_RUN_ARGS=(
    --name "$CB_NAME"
    --hostname claude-ide-box
    --label "io.claude-ide-box.project=$CB_PROJECT_DIR"
    --label "io.claude-ide-box.managed=1"
    --network "$CB_NETWORK_INTERNAL"
    --dns 127.0.0.1
    --add-host "egress-proxy:$CFG_PROXY_IP"
    --cap-drop ALL
    --security-opt no-new-privileges
    --read-only
    --tmpfs "/tmp:rw,exec,nosuid,nodev,size=$CFG_TMP_SIZE"
    --pids-limit "$CFG_PIDS_LIMIT"
    --memory "$CFG_MEMORY"
    --cpus "$CFG_CPUS"
    --init
    --user "$CB_UID:$CB_GID"
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
  while IFS="$CB_TAB" read -r kind path; do
    [ -n "$kind" ] || continue
    case "$path" in
      "$CB_PROJECT_DIR"/*) ;;
      *) cb_die "refusing to mount '$path': not inside the project" ;;
    esac
    case "$kind" in
      bad) cb_die "'$path' cannot be mounted safely (its name contains a comma, quote, tab or newline); rename or remove it" ;;
      file) CB_RUN_ARGS+=(--mount "type=bind,src=$CB_EMPTY_FILE,dst=$path,readonly") ;;
      dir) CB_RUN_ARGS+=(--mount "type=tmpfs,dst=$path,tmpfs-size=1048576") ;;
      ro) CB_RUN_ARGS+=(--mount "type=bind,src=$path,dst=$path,readonly") ;;
    esac
  done <<EOF
$CB_MOUNTS
EOF
}

# cb_run_args_hash IMAGE_ID - short hash of CB_RUN_ARGS and the image, stored
# as a label so a changed configuration is detected.
cb_run_args_hash() {
  { printf '%s\n' "${CB_RUN_ARGS[@]}"; printf '%s\n' "$1"; } | cb_sha256 | cut -c1-16
}

# Busy = a claude process is running inside the container.
cb_container_busy() {
  local n
  n="$(cb_docker exec "$CB_NAME" ps -eo args= 2>/dev/null |
    awk '{ n = split($1, p, "/"); if (p[n] == "claude" || p[n] == "claude.exe") c++ } END { print c + 0 }')"
  [ "${n:-0}" -gt 0 ]
}

# Make sure the project container exists, runs and matches the current
# configuration. Must be called with stdout pointing away from the IDE.
cb_ensure_container() {
  local image image_id hash state running label
  cb_require_profiles "$CFG_PROFILE"
  image="$(cb_image_for_profile "$CFG_PROFILE")"

  cb_lock "$CB_NAME"
  if ! image_id="$(cb_docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)"; then
    cb_require_docker
    cb_die "image $image not found - run 'claude-ide-box setup' in $CB_PROJECT_DIR"
  fi

  cb_build_run_args
  hash="$(cb_run_args_hash "$image_id")"

  state="$(cb_docker inspect --format '{{.State.Running}} {{index .Config.Labels "io.claude-ide-box.config"}}' "$CB_NAME" 2>/dev/null || true)"
  if [ -n "$state" ]; then
    running="${state%% *}"
    label="${state#* }"
    if [ "$label" != "$hash" ]; then
      if [ "$running" = "true" ] && cb_container_busy; then
        cb_die "container $CB_NAME runs with an outdated configuration (masks, image or settings changed) and a Claude session is active in it. Close the sessions and run 'claude-ide-box up --recreate' in $CB_PROJECT_DIR."
      fi
      cb_log "configuration of $CB_NAME changed; recreating it"
      cb_docker rm -f "$CB_NAME" >/dev/null 2>&1 || cb_die "cannot remove outdated container $CB_NAME"
      # Recompute the mounts now that no process of the old container can
      # still be changing the project tree (e.g. planting symlinks between
      # our checks and `docker run`).
      cb_build_run_args
      hash="$(cb_run_args_hash "$image_id")"
      state=""
    elif [ "$running" != "true" ]; then
      cb_require_network
      cb_log "starting stopped container $CB_NAME"
      cb_docker start "$CB_NAME" >/dev/null 2>&1 || cb_die "cannot start container $CB_NAME (see 'docker start $CB_NAME')"
    fi
  fi
  if [ -z "$state" ]; then
    cb_require_network
    cb_check_mask_record
    local -a args
    local a prev=""
    args=(run -d --label "io.claude-ide-box.config=$hash")
    for a in "${CB_RUN_ARGS[@]}"; do
      if [ "$prev" = "--cpus" ]; then
        a="$(cb_cpus)"
      fi
      args+=("$a")
      prev="$a"
    done
    args+=("$image" sleep infinity)
    cb_log "creating container: docker $(cb_quote_args "${args[@]}")"
    local err
    if ! err="$(cb_docker "${args[@]}" 2>&1 >/dev/null)"; then
      cb_log "docker run failed: $err"
      cb_die "cannot create container $CB_NAME: $err"
    fi
    cb_write_mask_record
  fi
  cb_unlock
}

# --------------------------------------------------------------------------
# Environment passed from the host into `docker exec`
# --------------------------------------------------------------------------

# Names that match the allowed prefixes but must not cross: they carry host
# paths, IDE connection details, or settings claude-ide-box controls itself.
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
      "~"*)
        cb_log "env: not passing $name (value is a home-relative host path)"
        continue
        ;;
      /*)
        if ! cb_path_inside "$CB_PROJECT_DIR" "$value"; then
          cb_log "env: not passing $name (value is a host path outside the project)"
          continue
        fi
        ;;
    esac
    printf '%s\n' "$name"
  done
}
