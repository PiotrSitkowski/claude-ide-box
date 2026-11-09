# shellcheck shell=bash
# Minimum container engine versions. The thresholds are data
# (engine-versions.txt next to this file); this file only reads the engine's
# versions and compares them. An engine whose version cannot be read is
# treated as vulnerable: fail closed.
#
# Sourced by common.sh. Same portability rules: bash 3.2, BSD/GNU/busybox.

# The data file sits next to this file.
CB_ENGINE_DIR="${CB_LIB:-${BASH_SOURCE[0]%/*}}"

cb_engine_versions_file() {
  printf '%s/engine-versions.txt\n' "$CB_ENGINE_DIR"
}

# cb_version_clean STRING - the first dotted number in STRING
# ("29.9.2-rd" -> 29.9.2, "Docker Desktop 4.98.0 (12345)" -> 4.98.0,
# "v1.3.4" -> 1.3.4). Fails when there is none.
cb_version_clean() {
  local v
  v="$(printf '%s\n' "$1" | awk 'match($0, /[0-9]+(\.[0-9]+)*/) { print substr($0, RSTART, RLENGTH); exit }')"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# cb_version_lt A B - true when dotted version A is lower than B, numerically
# per component (4.9.0 < 4.10.0 < 4.100.0).
cb_version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = n > m ? n : m
    for (i = 1; i <= k; i++) {
      p = (i <= n) ? x[i] + 0 : 0; q = (i <= m) ? y[i] + 0 : 0
      if (p < q) exit 0
      if (p > q) exit 1
    }
    exit 1
  }'
}

cb_component_title() {
  case "$1" in
    docker-desktop) echo "Docker Desktop" ;;
    docker-engine) echo "Docker Engine" ;;
    *) echo "$1" ;;
  esac
}

# Read the engine's versions with one `docker version` call. Sets
# CB_ENGINE_KIND (docker | podman | ""), CB_ENGINE_VERSION, CB_DESKTOP_VERSION
# (set only on Docker Desktop), CB_RUNC_VERSION and their raw strings.
cb_engine_version_facts() {
  local raw rest comps c
  raw="$(cb_docker version --format '{{.Server.Version}}|{{.Server.Platform.Name}}|{{range .Server.Components}}{{.Name}}={{.Version}};{{end}}|{{.Server.KernelVersion}}' 2>/dev/null | head -n 1)" || raw=""
  CB_ENGINE_KIND=""
  CB_ENGINE_RAW=""
  CB_ENGINE_PLATFORM=""
  CB_ENGINE_KERNEL=""
  CB_RUNC_RAW=""
  case "$raw" in
    *"|"*"|"*) ;;
    *) return 0 ;;
  esac
  CB_ENGINE_RAW="${raw%%|*}"
  rest="${raw#*|}"
  CB_ENGINE_PLATFORM="${rest%%|*}"
  comps="${rest#*|}"
  case "$comps" in
    *"|"*)
      CB_ENGINE_KERNEL="${comps##*|}"
      comps="${comps%|*}"
      ;;
  esac
  case "$CB_ENGINE_PLATFORM;$comps" in
    *Podman*) CB_ENGINE_KIND=podman ;;
    *) CB_ENGINE_KIND=docker ;;
  esac
  local IFS=';'
  for c in $comps; do
    case "$c" in
      runc=*) CB_RUNC_RAW="${c#runc=}" ;;
    esac
  done
  unset IFS
  CB_ENGINE_VERSION="$(cb_version_clean "$CB_ENGINE_RAW" 2>/dev/null)" || CB_ENGINE_VERSION=""
  CB_RUNC_VERSION="$(cb_version_clean "$CB_RUNC_RAW" 2>/dev/null)" || CB_RUNC_VERSION=""
  CB_DESKTOP_VERSION=""
  CB_DESKTOP=0
  # Docker Desktop names itself in the platform; its VM runs a linuxkit
  # kernel, which catches a Desktop that does not.
  case "$CB_ENGINE_PLATFORM" in
    "Docker Desktop"*)
      CB_DESKTOP=1
      CB_DESKTOP_VERSION="$(cb_version_clean "${CB_ENGINE_PLATFORM#Docker Desktop}" 2>/dev/null)" || CB_DESKTOP_VERSION=""
      ;;
  esac
  case "$CB_ENGINE_KERNEL" in
    *linuxkit*) CB_DESKTOP=1 ;;
  esac
}

# cb_engine_rules_check COMPONENT VERSION - "LEVEL<TAB>MESSAGE" for every
# rule of the data file that VERSION falls below.
cb_engine_rules_check() {
  local comp="$1" version="$2" major title
  major="${version%%.*}"
  title="$(cb_component_title "$comp")"
  awk -v comp="$comp" -v ver="$version" -v major="$major" -v title="$title" '
    function lt(a, b,   x, y, n, m, k, i, p, q) {
      n = split(a, x, "."); m = split(b, y, "."); k = n > m ? n : m
      for (i = 1; i <= k; i++) {
        p = (i <= n) ? x[i] + 0 : 0; q = (i <= m) ? y[i] + 0 : 0
        if (p < q) return 1
        if (p > q) return 0
      }
      return 0
    }
    /^[[:space:]]*(#|$)/ { next }
    $1 == comp {
      r++; line[r] = $2; fixed[r] = $3; level[r] = $4; adv[r] = $5; src[r] = $6
      d = $0
      for (i = 1; i <= 6; i++) { sub(/^[[:space:]]*[^[:space:]]+/, "", d) }
      sub(/^[[:space:]]+/, "", d); desc[r] = d
      if ($2 == major) own[$5] = 1
    }
    END {
      for (i = 1; i <= r; i++) {
        if (line[i] != "*" && line[i] != major) continue
        if (line[i] == "*" && (adv[i] in own)) continue
        if (!lt(ver, fixed[i])) continue
        if (level[i] == "fail")
          printf "fail\t%s %s is older than %s, which fixes %s: %s - update it (source: %s)\n", title, ver, fixed[i], adv[i], desc[i], src[i]
        else
          printf "%s\t%s %s is older than %s, %s - update when you can (source: %s)\n", level[i], title, ver, fixed[i], desc[i], src[i]
      }
    }' "$(cb_engine_versions_file)"
}

# cb_engine_findings - "LEVEL<TAB>MESSAGE" lines (fail, warn); nothing when
# the engine is fine. Needs a reachable daemon.
cb_engine_findings() {
  local f
  f="$(cb_engine_versions_file)"
  if [ ! -r "$f" ]; then
    printf 'fail\tthe list of minimum engine versions (%s) is missing; reinstall claude-ide-box\n' "$f"
    return 0
  fi
  cb_engine_version_facts
  if [ "$CB_ENGINE_KIND" = podman ]; then
    printf 'warn\tPodman %s: its version is not checked against known container escapes (only Docker Desktop, Docker Engine and runc are)\n' "${CB_ENGINE_RAW:-unknown}"
    return 0
  fi
  if [ -z "$CB_ENGINE_VERSION" ]; then
    printf "fail\tcannot read the Docker Engine version ('%s'); an engine whose version is unknown is not trusted\n" "$CB_ENGINE_RAW"
    return 0
  fi
  if [ "$CB_DESKTOP" = 1 ]; then
    if [ -z "$CB_DESKTOP_VERSION" ]; then
      printf "fail\tcannot read the Docker Desktop version (platform '%s', kernel '%s'); an engine whose version is unknown is not trusted\n" "$CB_ENGINE_PLATFORM" "$CB_ENGINE_KERNEL"
    else
      cb_engine_rules_check docker-desktop "$CB_DESKTOP_VERSION"
    fi
  fi
  cb_engine_rules_check docker-engine "$CB_ENGINE_VERSION"
  if [ -z "$CB_RUNC_VERSION" ]; then
    printf "fail\tcannot read the runc version ('%s'); an engine whose runtime version is unknown is not trusted\n" "$CB_RUNC_RAW"
  else
    cb_engine_rules_check runc "$CB_RUNC_VERSION"
  fi
}

# cb_engine_summary - "Docker Desktop 4.98.0, Docker Engine 29.9.2, runc 1.3.4"
# from the facts read last.
cb_engine_summary() {
  local s=""
  [ -z "$CB_DESKTOP_VERSION" ] || s="Docker Desktop $CB_DESKTOP_VERSION, "
  printf '%sDocker Engine %s, runc %s\n' "$s" "${CB_ENGINE_VERSION:-?}" "${CB_RUNC_VERSION:-?}"
}

CB_ENGINE_HATCH_HINT="if you accept a known container escape, set ALLOW_VULNERABLE_DOCKER=1 in the global config"

# cb_engine_enforce [setup] - refuse a vulnerable engine (unless the global
# ALLOW_VULNERABLE_DOCKER=1). Warnings go to stderr for setup, to the log
# otherwise (the wrapper runs on every session start).
cb_engine_enforce() {
  local mode="${1:-}" findings fails warns line
  cb_require_docker
  findings="$(cb_engine_findings)"
  fails="$(printf '%s\n' "$findings" | awk -F '\t' '$1 == "fail" { print $2 }')"
  warns="$(printf '%s\n' "$findings" | awk -F '\t' '$1 == "warn" { print $2 }')"
  if [ -n "$fails" ]; then
    if [ "$CFG_ALLOW_VULNERABLE_DOCKER" = 1 ]; then
      while IFS= read -r line; do
        [ -z "$line" ] || cb_warn "ALLOW_VULNERABLE_DOCKER=1 - running despite a known container escape: $line"
      done <<EOF
$fails
EOF
    else
      cb_die "refusing to run on this container engine: $(printf '%s\n' "$fails" | awk 'NF { s = s (n++ ? "; " : "") $0 } END { print s }'). Update it; $CB_ENGINE_HATCH_HINT ($CB_CONFIG_FILE)"
    fi
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$mode" = setup ]; then
      cb_warn "$line"
    else
      cb_log "WARNING: $line"
    fi
  done <<EOF
$warns
EOF
}
