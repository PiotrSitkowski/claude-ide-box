# shellcheck shell=bash
# Ephemeral mode: Claude works on a throw-away copy of the project.
#
#   up --try      copy the project to $CB_TRY_ROOT/work (and a pristine
#                 snapshot to $CB_TRY_ROOT/base), and run a separate
#                 container that mounts the copy at the project's own path
#   try diff      what Claude changed, compared with the snapshot
#   try apply     write those changes into the project
#   try discard   throw the copy away
#   try end       show the diff, then apply, discard or keep
#
# Security model:
#   - the container gets nothing it would not get without --try: the copy
#     sits at the same path, the same masks and read-only paths are applied
#     to it, and masked files are blanked in the copy, so the secrets are
#     not even duplicated;
#   - diff and apply run on the host only after the container is removed,
#     never follow a symlink, never run anything from the project (no git,
#     patch or make - only cp, mv, ln, rm, mkdir, rmdir, cmp and diff on
#     regular files), never write a masked or read-only path, a .git
#     directory at any depth, or through a parent that leads out of the
#     project, and skip special files;
#   - a path changed in the copy and, differently, in the project since the
#     snapshot is a conflict; apply then writes nothing unless told to skip
#     the conflicts, and keeps the copy for them.

# Paths in the copy are compared and applied with names one per line; a
# name with a newline (or a tab) cannot be handled that way and is reported.

try_require_session() {
  [ "$CB_TRY" = 1 ] || cb_die "no try session for $CB_PROJECT_DIR (start one with 'claude-ide-box up --try')"
}

# try_blank PATH KIND - replace a masked file or directory in a copy by an
# empty one. Never follows a symlink: rm removes the link itself.
try_blank() {
  local p="$1" kind="$2" root="$3"
  cb_path_inside "$root" "$(dirname "$p")" || return 0
  rm -rf "$p"
  if [ "$kind" = dir ]; then
    mkdir -p "$p"
  else
    mkdir -p "$(dirname "$p")"
    : >"$p"
  fi
}

# try_create - snapshot the project into work/ and base/.
try_create() {
  local root="$CB_TRY_ROOT" specs kind path rel old_umask
  case "$root" in
    *,* | *'"'* | *"$CB_NL"* | *"$CB_CR"* | *"$CB_TAB"*)
      cb_die "the try copy path '$root' contains a comma, quote, tab or newline, which docker --mount cannot express safely; set XDG_CACHE_HOME elsewhere"
      ;;
  esac
  # Masked paths of the project itself (resolved targets included): they are
  # blanked in both copies and never applied back.
  specs="$(cb_compute_mounts "$CB_PROJECT_DIR")" || exit 1
  case "$CB_NL$specs" in
    *"${CB_NL}bad$CB_TAB"*) cb_die "a path in the project cannot be mounted safely (comma, quote, tab or newline in its name); rename it first" ;;
  esac
  say "copying $CB_PROJECT_DIR to $root (twice: a working copy and a snapshot to compare with)"
  rm -rf "$root"
  old_umask="$(umask)"
  umask 077
  mkdir -p "$root/work" "$root/base" || cb_die "cannot create $root"
  umask "$old_umask"
  if ! cp -pPR "$CB_PROJECT_DIR/." "$root/work/" || ! cp -pPR "$CB_PROJECT_DIR/." "$root/base/"; then
    rm -rf "$root"
    cb_die "copying the project failed (disk full?); nothing was started"
  fi
  # The snapshot is only compared, and .git is never applied.
  rm -rf "$root/base/.git"
  : >"$root/masked"
  while IFS="$CB_TAB" read -r kind path; do
    case "$kind" in
      file | dir) ;;
      *) continue ;;
    esac
    rel="${path#"$CB_PROJECT_DIR"/}"
    printf '%s\n' "$rel" >>"$root/masked"
    try_blank "$root/work/$rel" "$kind" "$root/work"
    try_blank "$root/base/$rel" "$kind" "$root/base"
  done <<EOF
$specs
EOF
  mkdir -p "$(dirname "$CB_TRY_MARK")"
  printf '%s\n' "$root" >"$CB_TRY_MARK"
}

cmd_up_try() {
  if [ "$CB_TRY" = 1 ]; then
    say "resuming the try session: Claude keeps working on the copy in $CB_MOUNT_SRC"
  else
    cb_require_docker
    cb_require_engine
    try_create
    cb_try_select
  fi
  cb_ensure_container
  say "$CB_NAME is running for $CB_PROJECT_DIR on a throw-away copy."
  say "Claude's changes go to the copy, not to your files; the editor keeps showing your files."
  say "When done: 'claude-ide-box try diff' to review, then 'try apply' or 'try discard' ('try end' does all three)."
}

# Kind of a path, never following symlinks: missing, dir, link:<target>,
# file:x or file:- (executable or not), other.
try_kind() {
  if [ -L "$1" ]; then
    printf 'link:%s\n' "$(readlink "$1")"
  elif [ -d "$1" ]; then
    printf 'dir\n'
  elif [ -f "$1" ]; then
    if [ -x "$1" ]; then printf 'file:x\n'; else printf 'file:-\n'; fi
  elif [ -e "$1" ]; then
    printf 'other\n'
  else
    printf 'missing\n'
  fi
}

# try_same A B - same kind and, for regular files, the same content.
try_same() {
  local ka kb
  ka="$(try_kind "$1")"
  kb="$(try_kind "$2")"
  [ "$ka" = "$kb" ] || return 1
  case "$ka" in
    file:*) cmp -s "$1" "$2" ;;
  esac
}

# try_excluded REL - masked, read-only, or inside any .git: never applied.
try_excluded() {
  local rel="$1" e pat
  case "/$rel/" in
    */.git/*) return 0 ;;
  esac
  for e in $(cb_readonly_entries) .git; do
    case "$rel" in
      "$e" | "$e"/*) return 0 ;;
    esac
  done
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$rel" in
      "$e" | "$e"/*) return 0 ;;
    esac
  done <"$CB_TRY_ROOT/masked"
  # Mask patterns: a name matches any component, a path the start of REL.
  set -f
  for pat in $CFG_MASK_DEFAULTS; do
    try_rel_matches "$rel" "$pat" && ! try_rel_excepted "$rel" "$pat" && { set +f; return 0; }
  done
  for pat in $(cb_mask_patterns_explicit); do
    try_rel_matches "$rel" "$pat" && { set +f; return 0; }
  done
  set +f
  return 1
}

# try_rel_matches REL PATTERN - mask pattern semantics on a relative path.
try_rel_matches() {
  local rel="$1" pat="$2" part
  case "$pat" in
    */*)
      # shellcheck disable=SC2254 # mask entries are glob patterns
      case "$rel" in
        $pat | $pat/*) return 0 ;;
      esac
      return 1
      ;;
  esac
  local IFS=/
  for part in $rel; do
    # shellcheck disable=SC2254 # mask entries are glob patterns
    case "$part" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# A default pattern matched only through a component listed in MASK_EXCEPT.
try_rel_excepted() {
  local rel="$1" pat="$2" part
  local IFS=/
  for part in $rel; do
    # shellcheck disable=SC2254 # mask entries are glob patterns
    case "$part" in
      $pat) cb_mask_excepted "$part" || return 1 ;;
    esac
  done
  return 0
}

# Print every relative path below DIR, one per line, sorted, without .git
# directories. Names with a newline or tab are printed as "!unsafe".
try_list() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  (cd "$dir" && find . -name .git -prune -o -print0) | while IFS= read -r -d '' f; do
    f="${f#./}"
    [ "$f" != "." ] || continue
    case "$f" in
      *"$CB_NL"* | *"$CB_TAB"*) printf '!unsafe\t%s\n' "$(printf '%s' "$f" | tr '\n\t' '??')" ;;
      *) printf '%s\n' "$f" ;;
    esac
  done
}

# try_inside ROOT PATH - PATH's parent directory, with every symlink
# resolved, is ROOT or below it.
try_inside() {
  local parent
  parent="$(cd -P "$(dirname "$2")" 2>/dev/null && pwd -P)" || return 0
  case "$parent" in
    "$1" | "$1"/*) return 0 ;;
  esac
  return 1
}

# try_plan - write the plan to $CB_TRY_ROOT/plan, one "ACTION<TAB>REL" per
# line, and set the counters. Actions: add, modify, delete, conflict,
# excluded, special, unsafe.
try_plan() {
  local root="$CB_TRY_ROOT" rel b w o kw kb plan
  plan="$root/plan"
  TRY_CHANGES=0 TRY_CONFLICTS=0 TRY_SKIPPED=0
  : >"$plan"
  local pwork pbase
  pwork="$(cd -P "$root/work" && pwd -P)" || cb_die "cannot read $root/work"
  pbase="$(cd -P "$root/base" && pwd -P)" || cb_die "cannot read $root/base"
  { try_list "$root/base"; try_list "$root/work"; } | LC_ALL=C sort -u >"$root/paths"
  while IFS= read -r rel; do
    case "$rel" in
      '!unsafe'*) printf 'unsafe\t%s\n' "${rel#*"$CB_TAB"}" >>"$plan"; TRY_SKIPPED=$((TRY_SKIPPED + 1)); continue ;;
    esac
    b="$root/base/$rel"
    w="$root/work/$rel"
    o="$CB_PROJECT_DIR/$rel"
    # A directory of the copy replaced by a link (the container can do that)
    # would make every comparison and copy below read host files.
    if ! try_inside "$pwork" "$w" || ! try_inside "$pbase" "$b"; then
      printf 'linked\t%s\n' "$rel" >>"$plan"
      TRY_SKIPPED=$((TRY_SKIPPED + 1))
      continue
    fi
    try_same "$b" "$w" && continue
    if try_excluded "$rel"; then
      printf 'excluded\t%s\n' "$rel" >>"$plan"
      TRY_SKIPPED=$((TRY_SKIPPED + 1))
      continue
    fi
    kw="$(try_kind "$w")"
    if [ "$kw" = other ]; then
      printf 'special\t%s\n' "$rel" >>"$plan"
      TRY_SKIPPED=$((TRY_SKIPPED + 1))
      continue
    fi
    if ! try_same "$b" "$o"; then
      # The user changed it too; nothing to do if both ended up the same.
      try_same "$w" "$o" && continue
      printf 'conflict\t%s\n' "$rel" >>"$plan"
      TRY_CONFLICTS=$((TRY_CONFLICTS + 1))
      continue
    fi
    kb="$(try_kind "$b")"
    if [ "$kw" = missing ]; then
      printf 'delete\t%s\n' "$rel" >>"$plan"
    elif [ "$kb" = missing ]; then
      printf 'add\t%s\n' "$rel" >>"$plan"
    else
      printf 'modify\t%s\n' "$rel" >>"$plan"
    fi
    TRY_CHANGES=$((TRY_CHANGES + 1))
  done <"$root/paths"
}

# Print the plan as a list, then unified diffs of regular files.
try_show() {
  local action rel b w label
  cb_colors
  if [ "$TRY_CHANGES$TRY_CONFLICTS$TRY_SKIPPED" = 000 ]; then
    say "no changes in the copy"
    return 0
  fi
  say "${C_BOLD}== changes in the copy of $CB_PROJECT_DIR${C_OFF}"
  while IFS="$CB_TAB" read -r action rel; do
    case "$action" in
      add) label="added    " ;;
      modify) label="modified " ;;
      delete) label="deleted  " ;;
      conflict) label="${C_WARN}CONFLICT ${C_OFF}" ;;
      excluded) label="not applied (masked or read-only):" ;;
      special) label="not applied (not a file, directory or link):" ;;
      unsafe) label="not applied (newline or tab in the name):" ;;
      linked) label="not applied (inside a directory replaced by a symlink):" ;;
    esac
    printf '%s %s\n' "$label" "$rel"
  done <"$CB_TRY_ROOT/plan"
  while IFS="$CB_TAB" read -r action rel; do
    case "$action" in
      add | modify | delete | conflict) ;;
      *) continue ;;
    esac
    b="$CB_TRY_ROOT/base/$rel"
    w="$CB_TRY_ROOT/work/$rel"
    say ""
    try_diff_one "$b" "$w" "$rel"
  done <"$CB_TRY_ROOT/plan"
}

# Diff one path without following symlinks: text diff for regular files,
# a description for everything else.
try_diff_one() {
  local b="$1" w="$2" rel="$3" kb kw left right
  kb="$(try_kind "$b")"
  kw="$(try_kind "$w")"
  case "$kb:$kw" in
    file:*:file:* | missing:file:* | file:*:missing)
      left="$b"
      right="$w"
      [ "$kb" != missing ] || left=/dev/null
      [ "$kw" != missing ] || right=/dev/null
      [ "$kb" = "$kw" ] || [ "$kb" = missing ] || [ "$kw" = missing ] || say "mode: $kb -> $kw  $rel"
      diff -u -L "a/$rel" -L "b/$rel" "$left" "$right" || true
      ;;
    *) say "$rel: $kb -> $kw" ;;
  esac
}

# try_parent_safe REL - the project-side parent of REL stays inside the
# project (no symlinked directory leading out of it).
try_parent_safe() {
  cb_path_inside "$CB_PROJECT_DIR" "$(dirname "$CB_PROJECT_DIR/$1")"
}

# try_put REL - make the project's REL what the copy's REL is.
try_put() {
  local rel="$1" w o tmp
  w="$CB_TRY_ROOT/work/$rel"
  o="$CB_PROJECT_DIR/$rel"
  # Never write into or through a symlink: a link in the project is
  # replaced, not followed; a directory is only ever removed when empty.
  if [ -L "$w" ]; then
    if [ -d "$o" ] && [ ! -L "$o" ]; then rmdir "$o" 2>/dev/null || return 1; fi
    rm -f "$o"
    [ ! -e "$o" ] && [ ! -L "$o" ] || return 1
    ln -s "$(readlink "$w")" "$o"
  elif [ -d "$w" ]; then
    if [ -L "$o" ] || { [ -e "$o" ] && [ ! -d "$o" ]; }; then rm -f "$o"; fi
    [ -d "$o" ] || mkdir "$o"
  else
    if [ -d "$o" ] && [ ! -L "$o" ]; then rmdir "$o" 2>/dev/null || return 1; fi
    tmp="$(dirname "$o")/.claude-ide-box-try.$$"
    rm -f "$tmp"
    cp -p "$w" "$tmp" || { rm -f "$tmp"; return 1; }
    [ ! -L "$o" ] || rm -f "$o"
    mv -f "$tmp" "$o" || { rm -f "$tmp"; return 1; }
  fi
}

try_remove() {
  local o="$CB_PROJECT_DIR/$1"
  if [ -d "$o" ] && [ ! -L "$o" ]; then
    rmdir "$o" 2>/dev/null
  else
    rm -f "$o"
  fi
}

# Stop the session's container so nothing changes the copy while it is
# compared and applied. Fail closed when the engine cannot be asked.
try_stop_container() {
  cb_require_docker
  cb_docker rm -f "$CB_NAME" >/dev/null 2>&1 || true
}

try_cleanup() {
  cb_docker volume rm "$CB_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$CB_TRY_ROOT"
  rm -f "$CB_TRY_MARK"
  rm -f "$(cb_mask_record)"
}

try_apply() {
  local skip="$1" action rel failed="" kept="" conflicts=""
  try_stop_container
  try_plan
  while IFS="$CB_TAB" read -r action rel; do
    [ "$action" != conflict ] || conflicts="$conflicts
  $rel"
  done <"$CB_TRY_ROOT/plan"
  if [ -n "$conflicts" ] && [ "$skip" != 1 ]; then
    say "changed in the copy and, differently, in your project since the copy was made (conflicts):$conflicts"
    cb_die "nothing was applied. Resolve the conflicts by hand (Claude's versions are in $CB_TRY_ROOT/work), or run 'claude-ide-box try apply --skip-conflicts' to apply everything else."
  fi
  # Deletions deepest first, so directories are empty when they are removed.
  while IFS="$CB_TAB" read -r action rel; do
    [ "$action" = delete ] || continue
    if ! try_parent_safe "$rel"; then
      failed="$failed
  $rel (a parent directory leads out of the project)"
    elif ! try_remove "$rel"; then
      kept="$kept
  $rel"
    fi
  done <<EOF
$(LC_ALL=C sort -r "$CB_TRY_ROOT/plan")
EOF
  while IFS="$CB_TAB" read -r action rel; do
    case "$action" in add | modify) ;; *) continue ;; esac
    if ! try_parent_safe "$rel"; then
      failed="$failed
  $rel (a parent directory leads out of the project)"
    elif ! try_put "$rel"; then
      failed="$failed
  $rel"
    fi
  done <"$CB_TRY_ROOT/plan"
  say "applied $TRY_CHANGES change(s) to $CB_PROJECT_DIR"
  while IFS="$CB_TAB" read -r action rel; do
    case "$action" in
      excluded) say "not applied (masked or read-only): $rel" ;;
      special) say "not applied (not a file, directory or link): $rel" ;;
      unsafe) say "not applied (newline or tab in the name): $rel" ;;
      linked) say "not applied (inside a directory replaced by a symlink): $rel" ;;
    esac
  done <"$CB_TRY_ROOT/plan"
  [ -z "$kept" ] || say "directories kept because they hold files the copy does not have:$kept"
  if [ -n "$failed" ] || [ -n "$conflicts" ]; then
    [ -z "$failed" ] || say "could not be applied:$failed"
    [ -z "$conflicts" ] || say "conflicts left for you:$conflicts"
    say "the copy stays in $CB_TRY_ROOT/work; 'claude-ide-box try discard' removes it"
    return 0
  fi
  try_cleanup
  say "try session ended"
}

cmd_try() {
  local sub="${1:-status}"
  [ $# -eq 0 ] || shift
  project_from_pwd
  cb_load_config
  case "$sub" in
    status)
      if [ "$CB_TRY" != 1 ]; then
        say "no try session for $CB_PROJECT_DIR (start one with 'claude-ide-box up --try')"
        return 0
      fi
      try_plan
      say "try session for $CB_PROJECT_DIR"
      say "copy:      $CB_MOUNT_SRC"
      say "container: $CB_NAME"
      say "changes:   $TRY_CHANGES, conflicts: $TRY_CONFLICTS, not applicable: $TRY_SKIPPED"
      ;;
    diff)
      try_require_session
      try_plan
      try_show
      ;;
    apply)
      try_require_session
      local skip=0
      case "${1:-}" in
        --skip-conflicts) skip=1 ;;
        "") ;;
        *) cb_die "usage: claude-ide-box try apply [--skip-conflicts]" ;;
      esac
      cb_find_docker
      try_apply "$skip"
      ;;
    discard)
      try_require_session
      cb_find_docker
      try_stop_container
      try_cleanup
      say "try session discarded; $CB_PROJECT_DIR is unchanged"
      ;;
    end)
      try_require_session
      cb_find_docker
      try_stop_container
      try_plan
      try_show
      say ""
      while :; do
        printf 'Apply these changes to %s? [a]pply, [d]iscard, [k]eep the session: ' "$CB_PROJECT_DIR"
        IFS= read -r answer || cb_die "no answer (input ended); the session is kept"
        case "$answer" in
          a | apply) try_apply 0; return $? ;;
          d | discard) try_cleanup; say "try session discarded; $CB_PROJECT_DIR is unchanged"; return 0 ;;
          k | keep) say "kept; 'claude-ide-box up --try' or the IDE continues it"; return 0 ;;
        esac
      done
      ;;
    *) cb_die "usage: claude-ide-box try [status|diff|apply [--skip-conflicts]|discard|end]" ;;
  esac
}
