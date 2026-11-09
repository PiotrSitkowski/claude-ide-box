# shellcheck shell=bash
# Dependency volumes: give the container its own node_modules, .venv, ... on
# a named Docker volume laid over the project directory, and detect native
# dependencies installed for another platform.
#
# Sourced by common.sh. Same portability rules: bash 3.2, BSD/GNU/busybox.

# cb_deps_valid_entry ENTRY - true for a usable DEPS_VOLUMES entry: a path
# relative to the project, no "..", not the project itself, and nothing that
# claude-ide-box keeps read-only for the host's sake.
cb_deps_valid_entry() {
  local e="$1" part
  case "$e" in
    "" | /* | . | ./* | *..* | */ | *//*) return 1 ;;
    *[!A-Za-z0-9._/*@+-]*) return 1 ;;
  esac
  while IFS= read -r part; do
    case "$part" in
      "" | . | .git) return 1 ;;
    esac
    if cb_word_in "$part" "$CFG_READONLY_DEFAULTS $CFG_READONLY"; then
      return 1
    fi
  done <<EOF
$(printf '%s\n' "$e" | tr '/' '\n')
EOF
  return 0
}

cb_deps_check_entries() {
  local e
  set -f
  for e in $CFG_DEPS_VOLUMES; do
    set +f
    cb_deps_valid_entry "$e" ||
      cb_die "DEPS_VOLUMES entry '$e' is not usable: give a path relative to the project such as node_modules or web/.venv (no '..', not .git or another read-only path)"
    set -f
  done
  set +f
}

# cb_deps_volume_name PATH - volume for an absolute PATH inside the project.
cb_deps_volume_name() {
  printf '%s-deps-%s\n' "$CB_NAME" "$(cb_project_hash "${1#"$CB_PROJECT_DIR"/}")"
}

# cb_deps_dir_ok DIR PATH CREATE - check one candidate directory; create it
# on the host when CREATE is 1 and it does not exist. Fails closed on a
# symlink or a file: Docker would follow the symlink, and a file cannot hold
# a volume.
cb_deps_dir_ok() {
  local dir="$1" path="$2" create="$3"
  if [ -L "$path" ]; then
    cb_die "dependency directory $path is a symlink; claude-ide-box will not lay a volume over it (replace it with a directory or drop it from DEPS_VOLUMES)"
  fi
  if ! cb_path_inside "$dir" "$(dirname "$path")"; then
    cb_die "dependency directory $path is not inside the project (a parent directory is a symlink)"
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    cb_die "dependency path $path exists and is not a directory"
  fi
  if [ ! -e "$path" ]; then
    [ "$create" = 1 ] || return 1
    # Create it as the host user: otherwise Docker creates the mount point
    # (as root on Linux).
    mkdir -p "$path" || cb_die "cannot create $path"
    cb_log "created missing dependency directory $path"
  fi
  return 0
}

# cb_deps_paths DIR [nocreate] - absolute paths of the dependency directories,
# one per line, sorted, none inside another. An entry without "/" is a name
# matched at any depth (and created at the root when missing); an entry with
# "/" is a path (glob) anchored at the project root.
cb_deps_paths() {
  local dir="$1" create=1 e f
  [ "${2:-}" != nocreate ] || create=0
  [ -n "$CFG_DEPS_VOLUMES" ] || return 0
  cb_deps_check_entries
  {
    set -f
    for e in $CFG_DEPS_VOLUMES; do
      case "$e" in
        */*)
          set +f
          for f in "$dir"/$e; do
            case "$f" in
              *'*'*) continue ;; # a glob that matched nothing
            esac
            if cb_deps_dir_ok "$dir" "$f" "$create"; then
              printf '%s\n' "$f"
            fi
          done
          set -f
          ;;
        *)
          set +f
          if cb_deps_dir_ok "$dir" "$dir/$e" "$create"; then
            printf '%s\n' "$dir/$e"
          fi
          # Nested ones (workspaces): real directories only, and not inside
          # another directory of the same name.
          find "$dir" -mindepth 2 \( -name .git -prune \) -o \( -type d -name "$e" -print -prune \) 2>/dev/null || true
          set -f
          ;;
      esac
    done
    set +f
  } | sort -u | awk '
    # drop paths inside an earlier (shorter, sorted first) one
    { for (i = 1; i <= n; i++) if (index($0, keep[i] "/") == 1) next; keep[++n] = $0; print }'
}

# cb_deps_mounts DIR - "deps<TAB>PATH" mount lines (or "bad" ones).
cb_deps_mounts() {
  local p paths
  paths="$(cb_deps_paths "$1")" || exit 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    cb_emit_mount deps "$p"
  done <<EOF
$paths
EOF
}

# cb_under_deps PATH - true when PATH is a dependency directory or inside one
# (CB_DEPS_LIST holds them, one per line).
cb_under_deps() {
  local d
  [ -n "${CB_DEPS_LIST:-}" ] || return 1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$1" in
      "$d" | "$d"/*) return 0 ;;
    esac
  done <<EOF
$CB_DEPS_LIST
EOF
  return 1
}

# A fresh named volume is owned by root, and the container user cannot write
# to it. Hand it over once, in a throw-away container that sees nothing but
# the empty volume: no network, no project, only CAP_CHOWN.
cb_deps_prepare_volumes() {
  local image="$1" kind path vol rel
  CB_DEPS_NEW=""
  while IFS="$CB_TAB" read -r kind path; do
    [ "$kind" = deps ] || continue
    vol="$(cb_deps_volume_name "$path")"
    rel="${path#"$CB_PROJECT_DIR"/}"
    if cb_docker volume inspect "$vol" >/dev/null 2>&1; then
      continue
    fi
    cb_log "creating dependency volume $vol for $path"
    cb_docker volume create --label io.claude-ide-box.managed=1 \
      --label "io.claude-ide-box.deps-of=$CB_NAME" "$vol" >/dev/null 2>&1 ||
      cb_die "cannot create volume $vol"
    if ! cb_docker run --rm --network none --cap-drop ALL --cap-add CHOWN \
      --security-opt no-new-privileges --read-only --user 0:0 --entrypoint chown \
      --mount "type=volume,src=$vol,dst=/deps" "$image" "$CB_UID:$CB_GID" /deps >/dev/null 2>&1; then
      cb_docker volume rm "$vol" >/dev/null 2>&1 || true
      cb_die "cannot give volume $vol to the container user"
    fi
    CB_DEPS_NEW="$CB_DEPS_NEW $rel"
  done <<EOF
$CB_MOUNTS
EOF
}

cb_deps_announce_new() {
  [ -n "${CB_DEPS_NEW:-}" ] || return 0
  # `deps install` fills them right away.
  [ "${CB_DEPS_INSTALLING:-0}" != 1 ] || return 0
  cb_warn "new dependency volume(s) for${CB_DEPS_NEW} are empty; fill them with 'claude-ide-box deps install' in $CB_PROJECT_DIR (the host's own copies stay untouched)"
}

# cb_deps_project_volumes - names of every dependency volume of the project.
cb_deps_project_volumes() {
  cb_docker volume ls -q --filter "label=io.claude-ide-box.deps-of=$CB_NAME" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Native dependencies built for another platform
# --------------------------------------------------------------------------

# Platform-specific packages carry the platform in their name:
# @esbuild/darwin-arm64, @rollup/rollup-win32-x64-msvc, @img/sharp-darwin-x64,
# @cloudflare/workerd-windows-64, and in pnpm's store @esbuild+darwin-x64@0.24.0.
cb_foreign_package_name() {
  case "$1" in
    darwin-* | *-darwin-* | *-darwin | *+darwin-* | \
      win32-* | *-win32-* | *-win32 | *+win32-* | *-windows-* | *+windows-*)
      return 0
      ;;
  esac
  return 1
}

# A virtual environment created on macOS or Windows points at a Python that
# does not exist in the container.
cb_foreign_venv() {
  local cfg="$1" home
  [ ! -e "$(dirname "$cfg")/Scripts" ] || return 0
  home="$(sed -n 's/^home[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | head -n 1)"
  case "$home" in
    /opt/homebrew* | /usr/local/Cellar* | /usr/local/opt* | /Library/* | /Applications/* | \
      /Users/* | /System/* | /Volumes/* | [A-Za-z]:* | *\\*)
      return 0
      ;;
  esac
  return 1
}

# cb_foreign_native_deps DIR - project-relative paths of dependencies built for
# another platform that the container would see (not hidden by a dependency
# volume), one per line.
cb_foreign_native_deps() {
  local dir="$1" nm cand cfg
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    cb_under_deps "$nm" && continue
    for cand in "$nm"/* "$nm"/@*/* "$nm"/.pnpm/*; do
      [ -d "$cand" ] || continue
      if cb_foreign_package_name "$(basename "$cand")"; then
        printf '%s\n' "${cand#"$dir"/}"
      fi
    done
  done <<EOF
$(find "$dir" \( -name .git -prune \) -o \( -type d -name node_modules -print -prune \) 2>/dev/null || true)
EOF
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    cb_under_deps "$(dirname "$cfg")" && continue
    if cb_foreign_venv "$cfg"; then
      printf '%s\n' "$(dirname "${cfg#"$dir"/}")"
    fi
  done <<EOF
$(find "$dir" -maxdepth 3 \( -name .git -o -name node_modules \) -prune -o -name pyvenv.cfg -type f -print 2>/dev/null || true)
EOF
}

# cb_foreign_summary LIST - "a, b, c (and N more)".
cb_foreign_summary() {
  printf '%s\n' "$1" | awk 'NF { n++; if (n <= 5) s = s (n > 1 ? ", " : "") $0 }
    END { if (n > 5) s = s " (and " n - 5 " more)"; print s }'
}

CB_FOREIGN_HINT="give the container its own copy with 'claude-ide-box deps on' and 'claude-ide-box deps install' (the host keeps its own)"

cb_warn_foreign_deps() {
  local found
  found="$(cb_foreign_native_deps "$CB_PROJECT_DIR")"
  [ -n "$found" ] || return 0
  cb_warn "native dependencies built for another platform will not work in the Linux container (hooks, tests and builds that load them fail): $(cb_foreign_summary "$found") - $CB_FOREIGN_HINT"
}

# --------------------------------------------------------------------------
# Filling the volumes
# --------------------------------------------------------------------------

# cb_node_install_cmd DIR - install command for the lockfile in DIR, or fail.
cb_node_install_cmd() {
  local d="$1"
  if [ -f "$d/pnpm-lock.yaml" ]; then
    echo "corepack pnpm install --frozen-lockfile"
  elif [ -f "$d/yarn.lock" ]; then
    if [ -f "$d/.yarnrc.yml" ]; then
      echo "corepack yarn install --immutable"
    else
      echo "yarn install --frozen-lockfile"
    fi
  elif [ -f "$d/package-lock.json" ] || [ -f "$d/npm-shrinkwrap.json" ]; then
    echo "npm ci"
  elif [ -f "$d/bun.lock" ] || [ -f "$d/bun.lockb" ]; then
    echo "bun install --frozen-lockfile"
  else
    return 1
  fi
}

# cb_deps_install_plan - "DIR<TAB>COMMAND" lines for every dependency
# directory, each install directory once. Fails without running anything when
# one cannot be filled automatically.
cb_deps_install_plan() {
  local p parent base d cmd plan="" line paths
  paths="$(cb_deps_paths "$CB_PROJECT_DIR" nocreate)" || exit 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    parent="$(dirname "$p")"
    base="$(basename "$p")"
    case "$base" in
      node_modules)
        # Workspaces: the lockfile may be in a parent directory.
        d="$parent"
        cmd=""
        while :; do
          if cmd="$(cb_node_install_cmd "$d")"; then
            break
          fi
          cmd=""
          [ "$d" != "$CB_PROJECT_DIR" ] || break
          d="$(dirname "$d")"
        done
        [ -n "$cmd" ] || cb_die "no lockfile (package-lock.json, pnpm-lock.yaml, yarn.lock) for ${p#"$CB_PROJECT_DIR"/}; install once on purpose with 'claude-ide-box shell' (npm install writes a new lockfile)"
        ;;
      .venv | venv | .virtualenv)
        d="$parent"
        if [ -f "$d/uv.lock" ]; then
          cmd="env UV_PROJECT_ENVIRONMENT=$base uv sync --frozen"
        elif [ -f "$d/poetry.lock" ]; then
          cmd="env POETRY_VIRTUALENVS_IN_PROJECT=true poetry install --no-root"
        elif [ -f "$d/requirements.txt" ]; then
          cmd="sh -c python3 -m venv $base && $base/bin/pip install -r requirements.txt"
        else
          cb_die "no uv.lock, poetry.lock or requirements.txt next to ${p#"$CB_PROJECT_DIR"/}; fill it yourself in 'claude-ide-box shell'"
        fi
        ;;
      *)
        cb_die "claude-ide-box does not know how to fill ${p#"$CB_PROJECT_DIR"/}; fill it yourself in 'claude-ide-box shell'"
        ;;
    esac
    line="$d$CB_TAB$cmd"
    case "$CB_NL$plan" in
      *"$CB_NL$line$CB_NL"*) ;;
      *) plan="$plan$line$CB_NL" ;;
    esac
  done <<EOF
$paths
EOF
  printf '%s' "$plan"
}

# cb_deps_install - run the plan in the project container, as the container
# user, through the proxy. Package install scripts run there, not on the host.
cb_deps_install() {
  local plan d cmd
  [ -n "$CFG_DEPS_VOLUMES" ] ||
    cb_die "this project has no dependency volumes; turn them on first with 'claude-ide-box deps on'"
  # Creating the container creates missing dependency directories too.
  CB_DEPS_INSTALLING=1
  cb_ensure_container
  plan="$(cb_deps_install_plan)" || exit 1
  [ -n "$plan" ] || cb_die "no dependency directories found for DEPS_VOLUMES='$CFG_DEPS_VOLUMES'"
  local -a tty
  tty=(-i)
  if [ -t 0 ] && [ -t 1 ]; then
    tty=(-i -t)
  fi
  # The plan is read on fd 4: docker exec -i must not consume it.
  while IFS="$CB_TAB" read -r d cmd <&4; do
    [ -n "$d" ] || continue
    printf 'claude-ide-box: in %s: %s\n' "$d" "$cmd" >&2
    case "$cmd" in
      "sh -c "*)
        cb_docker exec "${tty[@]}" -w "$d" -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "$CB_NAME" sh -c "${cmd#sh -c }" ||
          cb_die "'${cmd#sh -c }' failed in $d"
        ;;
      *)
        # shellcheck disable=SC2086 # the command is a fixed list of words
        cb_docker exec "${tty[@]}" -w "$d" -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "$CB_NAME" $cmd ||
          cb_die "'$cmd' failed in $d"
        ;;
    esac
  done 4<<EOF
$plan
EOF
}
