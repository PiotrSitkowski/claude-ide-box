# shellcheck shell=bash
# COPY_HISTORY: copy finished conversation transcripts from the project's
# container volume to ~/.claude/projects/<project>/ on the host, so the IDE
# extension's session list shows them. One direction only: container -> host.
#
# What is copied: regular files directly in the project's transcript
# directory whose name is <session UUID>.jsonl, up to COPY_HISTORY_MAX_SIZE
# each and COPY_HISTORY_MAX_TOTAL together. Never memory/, subdirectories,
# symlinks, FIFOs or other special files. A host file that this copy did not
# create (or that changed on the host since) is never overwritten.
#
# Everything read from the container is untrusted: the listing only proposes
# names, which are checked here again; contents are size-limited here again;
# every host write goes to a file this function creates itself.
#
# Requires common.sh (cb_log, cb_sha256, CB_* paths).

# Directory name Claude Code uses for a project in ~/.claude/projects:
# every UTF-16 code unit that is not [A-Za-z0-9] becomes "-"; a name longer
# than 200 characters is cut to 200 and gets "-" plus a base-36 hash of the
# path (Java-style 32-bit string hash, absolute value). Measured in Claude
# Code 2.1.318. Fails for a path that is not valid UTF-8.
cb_claude_project_slug() {
  printf '%s' "$1" | od -An -v -tu1 | awk '
    function emit(cu, keep) {
      # cu: UTF-16 code unit; keep: the ASCII character or "" for "-"
      out = out (keep != "" ? keep : "-")
      h = (h * 31 + cu) % 4294967296
    }
    BEGIN {
      out = ""; h = 0; need = 0; cp = 0
      digits = "0123456789abcdefghijklmnopqrstuvwxyz"
      for (i = 48; i < 58; i++) ascii[i] = sprintf("%c", i)
      for (i = 65; i < 91; i++) ascii[i] = sprintf("%c", i)
      for (i = 97; i < 123; i++) ascii[i] = sprintf("%c", i)
    }
    {
      for (f = 1; f <= NF; f++) {
        b = $f + 0
        if (need > 0) {
          if (b < 128 || b > 191) { bad = 1; exit }
          cp = cp * 64 + (b - 128); need--
          if (need == 0) {
            if (cp >= 65536) {
              cp -= 65536
              emit(55296 + int(cp / 1024), "")
              emit(56320 + (cp % 1024), "")
            } else {
              emit(cp, "")
            }
          }
        } else if (b < 128) {
          emit(b, (b in ascii) ? ascii[b] : "")
        } else if (b >= 194 && b <= 223) { cp = b - 192; need = 1 }
        else if (b >= 224 && b <= 239) { cp = b - 224; need = 2 }
        else if (b >= 240 && b <= 244) { cp = b - 240; need = 3 }
        else { bad = 1; exit }
      }
    }
    END {
      if (bad || need > 0) exit 1
      if (length(out) <= 200) { print out; exit 0 }
      if (h >= 2147483648) h = 4294967296 - h
      s = ""
      if (h == 0) s = "0"
      while (h > 0) { s = substr(digits, (h % 36) + 1, 1) s; h = int(h / 36) }
      print substr(out, 1, 200) "-" s
    }'
}

# Bytes of a size setting such as 50m or 1g (validated by cb_validate_config).
cb_size_bytes() {
  local n="${1%[bkmgBKMG]}" unit="${1#"${1%?}"}"
  case "$unit" in
    k | K) echo $((n * 1024)) ;;
    m | M) echo $((n * 1024 * 1024)) ;;
    g | G) echo $((n * 1024 * 1024 * 1024)) ;;
    *) echo "$n" ;;
  esac
}

# The script run by node in the container. `list DIR` prints "now<TAB>T"
# and one "TYPE<TAB>SIZE<TAB>MTIME<TAB>NAME" line per entry (lstat: f file,
# l symlink, d directory, p FIFO, o other; a name outside [A-Za-z0-9._-] is
# printed as "?"). `read FILE MAX` prints the file, refusing anything that is
# not a regular file when opened (O_NOFOLLOW, and O_NONBLOCK so that a FIFO
# cannot block) or that is larger than MAX bytes.
cb_history_node_script() {
  cat <<'CB_JS'
'use strict';
const fs = require('fs');
const path = require('path');
const [mode, target, maxArg] = process.argv.slice(1);
function bail(code, msg) { process.stderr.write(msg + '\n'); process.exit(code); }
if (mode === 'list') {
  const out = ['now\t' + Math.floor(Date.now() / 1000)];
  let st = null;
  try { st = fs.lstatSync(target); } catch (e) { /* no directory yet */ }
  if (st && st.isDirectory()) {
    const names = fs.readdirSync(target).slice(0, 10000);
    for (const name of names) {
      let s;
      try { s = fs.lstatSync(path.join(target, name)); } catch (e) { continue; }
      const t = s.isSymbolicLink() ? 'l' : s.isFile() ? 'f' : s.isDirectory() ? 'd' : s.isFIFO() ? 'p' : 'o';
      const shown = /^[A-Za-z0-9._-]{1,255}$/.test(name) ? name : '?';
      out.push(t + '\t' + s.size + '\t' + Math.floor(s.mtimeMs / 1000) + '\t' + shown);
    }
  }
  process.stdout.write(out.join('\n') + '\n');
} else if (mode === 'read') {
  const max = Number(maxArg);
  if (!Number.isSafeInteger(max) || max < 0) bail(2, 'bad size limit');
  const c = fs.constants;
  let fd;
  try { fd = fs.openSync(target, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK); } catch (e) { bail(3, 'cannot open: ' + e.code); }
  const s = fs.fstatSync(fd);
  if (!s.isFile()) bail(3, 'not a regular file');
  if (s.size > max) bail(4, 'over the size limit');
  if (s.size === 0) process.exit(0);
  fs.createReadStream(null, { fd: fd, start: 0, end: max }).pipe(process.stdout);
} else {
  bail(2, 'usage: list DIR | read FILE MAX');
}
CB_JS
}

# cb_run_limited SECONDS OUTFILE CMD... - run CMD with stdout to OUTFILE;
# kill it after SECONDS (no `timeout` on macOS). Returns CMD's status.
cb_run_limited() {
  local secs="$1" out="$2" pid wd st
  shift 2
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  (sleep "$secs"; kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
  wd=$!
  st=0
  wait "$pid" || st=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  return "$st"
}

# Log text that came from the container: no control characters.
cb_history_safe() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._ -' '?'
}

cb_history_size() {
  wc -c <"$1" | tr -d ' '
}

# Record of what was copied: "SHA256<TAB>SRC_SIZE<TAB>SRC_MTIME<TAB>HOST_PATH".
cb_history_record() {
  printf '%s/history/%s.list\n' "$CB_STATE_DIR" "$CB_NAME"
}

# cb_history_lookup PATH - print the record line of PATH, if any.
cb_history_lookup() {
  awk -F '\t' -v p="$1" '$4 == p { print; exit }' "$CB_HISTORY_REC" 2>/dev/null || true
}

# cb_history_set SHA SIZE MTIME PATH - add or replace the record of PATH.
cb_history_set() {
  awk -F '\t' -v p="$4" '$4 != p' "$CB_HISTORY_REC" >"$CB_HISTORY_REC.new" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$CB_HISTORY_REC.new"
  mv "$CB_HISTORY_REC.new" "$CB_HISTORY_REC"
}

# Copy finished transcripts of the current project (CB_NAME, CB_PROJECT_DIR,
# CB_DOCKER set, container running), one copy per project at a time. Never
# fails the caller; logs instead.
cb_history_copy() {
  local lock pid
  umask 077
  mkdir -p "$CB_STATE_DIR/history" "$CB_LOCK_DIR" || return 0
  lock="$CB_LOCK_DIR/$CB_NAME.history.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      cb_log "history: another copy for $CB_NAME is running (pid $pid)"
      return 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 0
  fi
  # The pid of this (background) shell: bash 3.2 has no $BASHPID.
  sh -c 'echo "$PPID"' >"$lock/pid" 2>/dev/null || true
  cb_history_sync
  rm -rf "$lock"
}

cb_history_sync() {
  local slug host_root dst src max total list now t size mtime name rest in
  local dest rec rsha rsize rmtime used tmp got sha copied=0
  if ! slug="$(cb_claude_project_slug "$CB_PROJECT_DIR")" || [ -z "$slug" ]; then
    cb_log "history: cannot compute the transcript directory name of $CB_PROJECT_DIR; nothing copied"
    return 0
  fi
  host_root="$HOME/.claude"
  case "${CLAUDE_CONFIG_DIR:-}" in
    /*) host_root="$CLAUDE_CONFIG_DIR" ;;
  esac
  case "$host_root" in
    *"$CB_TAB"* | *"$CB_NL"* | *"$CB_CR"*)
      cb_log "history: the host Claude directory has a tab or newline in its name; nothing copied"
      return 0
      ;;
  esac
  dst="$host_root/projects/$slug"
  src="/home/claude/.claude/projects/$slug"
  max="$(cb_size_bytes "$CFG_COPY_HISTORY_MAX_SIZE")"
  total="$(cb_size_bytes "$CFG_COPY_HISTORY_MAX_TOTAL")"

  CB_HISTORY_REC="$(cb_history_record)"
  [ -f "$CB_HISTORY_REC" ] || : >"$CB_HISTORY_REC"
  list="$CB_STATE_DIR/history/$CB_NAME.listing"
  if ! cb_run_limited 30 "$list.raw" "$CB_DOCKER" exec "$CB_NAME" node -e "$(cb_history_node_script)" list "$src"; then
    cb_log "history: listing $src in $CB_NAME failed; nothing copied"
    rm -f "$list.raw"
    return 0
  fi
  head -c 2000000 "$list.raw" >"$list"
  rm -f "$list.raw"
  now=""
  IFS="$CB_TAB" read -r t now <"$list" || true
  case "$t:$now" in
    now:[0-9]*) ;;
    *)
      cb_log "history: unexpected listing from $CB_NAME; nothing copied"
      rm -f "$list"
      return 0
      ;;
  esac
  case "$now" in *[!0-9]*) rm -f "$list"; return 0 ;; esac

  # Our own temporary files left by an interrupted run.
  rm -f "$dst"/.claude-ide-box.*.tmp 2>/dev/null || true

  while IFS="$CB_TAB" read -r t size mtime name; do
    [ "$t" != now ] || continue
    case "$size$mtime" in
      "" | *[!0-9]*) continue ;;
    esac
    if ! printf '%s\n' "$name" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'; then
      [ "$t" = f ] && cb_log "history: skipped '$(cb_history_safe "$name")': not a session transcript name"
      continue
    fi
    if [ "$t" != f ]; then
      cb_log "history: skipped $name: not a regular file (type $t)"
      continue
    fi
    if [ "$size" -gt "$max" ]; then
      cb_log "history: skipped $name: $size bytes, over COPY_HISTORY_MAX_SIZE"
      continue
    fi
    if [ $((now - mtime)) -lt 5 ]; then
      cb_log "history: skipped $name: still being written"
      continue
    fi
    dest="$dst/$name"
    rec="$(cb_history_lookup "$dest")"
    rsha="" rsize="" rmtime=""
    if [ -n "$rec" ]; then
      IFS="$CB_TAB" read -r rsha rsize rmtime rest <<CB_END
$rec
CB_END
      if [ "$rsize" = "$size" ] && [ "$rmtime" = "$mtime" ]; then
        continue
      fi
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ -z "$rec" ]; then
        cb_log "history: skipped $name: $dest exists and was not created by claude-ide-box"
        continue
      fi
      if [ -L "$dest" ] || [ ! -f "$dest" ] || [ "$(cb_sha256 <"$dest")" != "$rsha" ]; then
        cb_log "history: skipped $name: $dest changed on the host since it was copied"
        continue
      fi
    fi
    used="$(awk -F '\t' -v p="$dest" '$4 != p { s += $2 } END { print s + 0 }' "$CB_HISTORY_REC")"
    if [ $((used + size)) -gt "$total" ]; then
      cb_log "history: skipped $name: the copies would exceed COPY_HISTORY_MAX_TOTAL"
      continue
    fi
    if ! mkdir -p "$dst" 2>/dev/null; then
      cb_log "history: cannot create $dst; nothing copied"
      break
    fi
    tmp="$(mktemp "$dst/.claude-ide-box.XXXXXX")" || { cb_log "history: cannot write in $dst"; break; }
    mv "$tmp" "$tmp.tmp" && tmp="$tmp.tmp"
    in="$CB_STATE_DIR/history/$CB_NAME.in"
    if ! cb_run_limited 120 "$in" "$CB_DOCKER" exec "$CB_NAME" node -e "$(cb_history_node_script)" read "$src/$name" "$max"; then
      cb_log "history: skipped $name: the container refused or failed to read it"
      rm -f "$tmp" "$in"
      continue
    fi
    head -c $((max + 1)) "$in" >"$tmp"
    rm -f "$in"
    got="$(cb_history_size "$tmp")"
    if [ "$got" -gt "$max" ]; then
      cb_log "history: skipped $name: more than COPY_HISTORY_MAX_SIZE arrived"
      rm -f "$tmp"
      continue
    fi
    sha="$(cb_sha256 <"$tmp")"
    if [ -z "$rec" ] || { [ ! -e "$dest" ] && [ ! -L "$dest" ]; }; then
      # ln refuses to replace an existing name: a file the host created in
      # the meantime is never overwritten.
      if ! ln "$tmp" "$dest" 2>/dev/null; then
        cb_log "history: skipped $name: $dest appeared on the host"
        rm -f "$tmp"
        continue
      fi
      rm -f "$tmp"
    else
      if [ -L "$dest" ] || [ "$(cb_sha256 <"$dest")" != "$rsha" ]; then
        cb_log "history: skipped $name: $dest changed on the host since it was copied"
        rm -f "$tmp"
        continue
      fi
      mv -f "$tmp" "$dest"
    fi
    cb_history_set "$sha" "$size" "$mtime" "$dest"
    copied=$((copied + 1))
  done <"$list"
  rm -f "$list"
  cb_log "history: copied $copied transcript(s) of $CB_NAME to $dst"
}

# Start the copy in the background so it never delays or blocks a session:
# the wrapper ends in `exec docker exec`, so previous sessions are copied at
# the next start. Nothing of it reaches the IDE's stdout or stderr.
cb_history_copy_bg() {
  (
    set +e
    cb_history_copy
    cb_log "history: done"
  ) </dev/null >/dev/null 2>&1 3>&- &
  cb_log "history: copying finished transcripts in the background (pid $!)"
}
