# shellcheck shell=bash
# Pseudonymised copies made with pii-airgap (https://github.com/PiotrSitkowski/pii-airgap).
#
# `pii-airgap anonymise COPY` replaces personal data in COPY with [TYPE_N]
# tokens and records the copy in its state directory. A copy that holds real
# values again - restored in place, or a value the agent wrote itself - must
# not be opened with Claude: everything in it can reach the AI provider.
# Before any container starts, every recorded copy that is the project, lies
# inside it or contains it is checked by pii-airgap's own image in a
# throw-away container without network, which gets the copy and the token map
# read-only. The project container never sees the map. Any doubt - the map is
# gone or was replaced, the check fails - means no start.
#
# Record format (written by pii-airgap; KEY=VALUE lines, parsed, never
# sourced): kind (copy, or restored for a folder written by
# `restore --out`, which holds real values), path, physical, map,
# map_sha256, image.
#
# Requires common.sh (cb_die, cb_log, cb_sha256, CB_DOCKER, CB_PROJECT_*).

cb_pii_copies_dir() {
  printf '%s/pii-airgap/copies\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# cb_pii_value FILE KEY - the first value of KEY in a record.
cb_pii_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# cb_pii_related A B - A and B are the same directory or one contains the other.
cb_pii_related() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  case "$1/" in "$2"/*) return 0 ;; esac
  case "$2/" in "$1"/*) return 0 ;; esac
  return 1
}

# Text from inside a copy (file names) shown on a terminal: printable only.
cb_pii_printable() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

cb_pii_check() {
  local dir f path phys
  dir="$(cb_pii_copies_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.copy; do
    [ -f "$f" ] || continue
    path="$(cb_pii_value "$f" path)"
    phys="$(cb_pii_value "$f" physical)"
    case "$path" in
      /*) ;;
      *) cb_log "pii: ignoring $f without an absolute path"; continue ;;
    esac
    if cb_pii_related "$CB_PROJECT_DIR" "$path" || cb_pii_related "$CB_PROJECT_PHYS" "$path" ||
      cb_pii_related "$CB_PROJECT_DIR" "$phys" || cb_pii_related "$CB_PROJECT_PHYS" "$phys"; then
      if [ ! -d "$path" ]; then
        cb_log "pii: recorded copy $path no longer exists"
        continue
      fi
      cb_pii_verify "$f" "$path"
    fi
  done
}

# cb_pii_verify RECORD COPY - die unless COPY holds no value of its map.
cb_pii_verify() {
  local rec="$1" copy="$2" map sum image out st=0 n list what
  local forget="If you no longer use the copy, delete it and run 'pii-airgap forget-copy $copy'."
  what="a pseudonymised copy (pii-airgap anonymise)"
  [ "$(cb_pii_value "$rec" kind)" != restored ] || what="a folder restored from a pseudonymised copy (pii-airgap restore --out)"
  map="$(cb_pii_value "$rec" map)"
  sum="$(cb_pii_value "$rec" map_sha256)"
  image="$(cb_pii_value "$rec" image)"
  [ -f "$map" ] ||
    cb_die "$copy is a pseudonymised copy (pii-airgap anonymise), but its token map $map is missing, so it cannot be checked for real personal data; nothing was started. $forget"
  [ "$(cb_sha256 <"$map")" = "$sum" ] ||
    cb_die "the token map $map of the pseudonymised copy $copy changed since 'pii-airgap anonymise' recorded it, so the copy cannot be checked for real personal data; nothing was started. Run 'pii-airgap anonymise' on the copy again, or: $forget"
  case "$image" in
    "" | -* | *[!A-Za-z0-9._:/@-]*) cb_die "the record $rec names no valid pii-airgap image; nothing was started" ;;
  esac
  case "$copy$map" in
    *,* | *'"'* | *"$CB_NL"*) cb_die "the path of the pseudonymised copy $copy or of its map cannot be mounted safely; nothing was started" ;;
  esac
  cb_log "pii: checking the pseudonymised copy $copy with $image"
  out="$(cb_docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 2g --tmpfs /tmp:rw,nosuid,nodev,size=256m \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    --mount "type=bind,src=$copy,dst=/copy,readonly" \
    --mount "type=bind,src=$map,dst=/map.json,readonly" \
    "$image" verify /copy --map /map.json 2>>"${CB_LOG_FILE:-/dev/null}" | head -c 65536)" || st=$?
  # With pipefail (set by both scripts) st is the check's status; output cut
  # by head makes it non-zero too, which refuses.
  case "$st" in
    0)
      cb_log "pii: $copy holds no value of its token map"
      ;;
    5)
      n="$(printf '%s\n' "$out" | grep -c . || true)"
      list="$(printf '%s\n' "$out" | cut -f1 | head -n 10 | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')"
      [ "$n" -le 10 ] || list="$list, ..."
      cb_die "refusing to start: $copy is $what, and $n file(s) in it hold real personal data from its token map in clear text: $(cb_pii_printable "$list"). Claude would send them to the API. Keep working in a copy that still has its tokens, and restore with 'pii-airgap restore COPY --out NEW_DIR' - never open the restored folder with Claude. $forget"
      ;;
    *)
      cb_die "could not check the pseudonymised copy $copy for real personal data (pii-airgap check exited with $st; is the image $image built?); nothing was started"
      ;;
  esac
}

# --------------------------------------------------------------------------
# Scan before a project container is created
# --------------------------------------------------------------------------
#
# pii-airgap protects the copies it made, not the projects it never saw: a
# project full of client documents opened in the IDE goes to the API as it
# is. When pii-airgap is installed, every new project container is preceded
# by `pii-airgap scan` (its own throw-away container without network; results
# are cached by file content, so a second scan of the same files is fast).
# Personal data in files that are not masked stops the start until the files
# are masked, the project is replaced by a pseudonymised copy, or the user
# accepts it for this project (PII_ACCEPTED=1 in the per-project config,
# outside the project, written by `claude-ide-box pii-scan accept`).
# Without pii-airgap nothing changes.

# The pii-airgap command: CLAUDE_IDE_BOX_PII, then PATH, then ~/.local/bin
# (an IDE started from the desktop may not have it on PATH).
cb_pii_airgap() {
  local c
  for c in "${CLAUDE_IDE_BOX_PII:-}" "$(command -v pii-airgap 2>/dev/null || true)" "$HOME/.local/bin/pii-airgap"; do
    if [ -n "$c" ] && [ -x "$c" ] && [ ! -d "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# cb_pii_scan_run BIN OUT ERR LIMIT - run the scan of the project in the
# background and wait at most LIMIT seconds (0: no limit). Returns the scan's
# status, or 124 when it took too long. The scan container itself is not
# stopped then: it finishes in the background and fills the cache.
cb_pii_scan_run() {
  local bin="$1" out="$2" err="$3" limit="$4" pid waited=0 st=0
  # fd 3 is the IDE's stdout in the wrapper: a scan left running after the
  # time limit must not hold it, or the panel waits for the scan anyway.
  "$bin" scan "$CB_PROJECT_DIR" --min-confidence "$CFG_PII_SCAN_MIN_CONFIDENCE" >"$out" 2>"$err" </dev/null 3>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$limit" -gt 0 ] && [ "$waited" -ge $((limit * 5)) ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid" || st=$?
  return "$st"
}

# cb_pii_scan_findings OUT - "RELPATH: TYPES" for each file of the report
# that is not masked, printable only. The report's detail lines (with masked
# previews of the values) are never read. Fails on a report it cannot read.
cb_pii_scan_findings() {
  local masked
  masked="$(printf '%s\n' "${CB_MOUNTS:-}" | awk -F '\t' '$1 == "file" || $1 == "dir" { print $2 }')"
  awk -v dir="$CB_PROJECT_DIR" -v phys="${CB_PROJECT_PHYS:-$CB_PROJECT_DIR}" -v masked="$masked" '
    function rel(p) {
      if (index(p, dir "/") == 1) return substr(p, length(dir) + 2)
      if (index(p, phys "/") == 1) return substr(p, length(phys) + 2)
      return p
    }
    BEGIN { n = split(masked, m, "\n"); for (x = 1; x <= n; x++) m[x] = rel(m[x]) }
    # Known lines: details (never read), files not scanned, the summary.
    # Anything else that is not a file line - a file name with a line break
    # splits one - makes the report unreadable, which counts as a finding.
    /^    line / || /^NOT SCANNED / || /^[0-9]+ (binary )?file\(s\) / { next }
    {
      i = 0; s = $0
      while ((j = index(s, "  [")) > 0) { i += j; s = substr(s, j + 1) }
      if (i <= 1) exit 2
      path = substr($0, 1, i - 1)
      rest = substr($0, i + 2)
      k = index(rest, "]  ")
      if (k == 0 || substr(path, 1, 1) == " ") exit 2
      types = substr(rest, k + 3)
      path = rel(path)
      for (x = 1; x <= n; x++)
        if (m[x] != "" && (path == m[x] || index(path, m[x] "/") == 1)) next
      print path ": " types
    }' "$1" | LC_ALL=C tr -d '\000-\011\013-\037\177'
}

# cb_pii_scan_text FINDINGS - the files, at most 10, one per line.
cb_pii_scan_list() {
  printf '%s\n' "$1" | awk 'NF { n++; if (n <= 10) print "  " $0 } END { if (n > 10) print "  ... and " n - 10 " more file(s)" }'
}

cb_pii_scan_ways() {
  cat <<'EOT'
Before Claude can work here, choose one:
  - hide the files from Claude: pii-airgap mask-add FILE... in the project
  - work on a pseudonymised copy instead (see "Personal data in the project" in the README)
  - accept that this project's personal data is sent to the AI provider:
    claude-ide-box pii-scan accept (in the project)
Then start the session again.
EOT
}

# Called while the project container is about to be created, with CB_MOUNTS
# computed. Never prints on stdout (the wrapper's stdout is the IDE's).
cb_pii_scan_check() {
  local bin tmp st=0 findings why
  [ "$CFG_PII_SCAN" = 1 ] || return 0
  if [ "$CFG_PII_ACCEPTED" = 1 ]; then
    cb_log "pii scan: skipped, personal data accepted for this project"
    return 0
  fi
  bin="$(cb_pii_airgap)" || {
    cb_log "pii scan: pii-airgap is not installed; no scan"
    return 0
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-ide-box-pii.XXXXXX")" || cb_die "cannot create a temporary directory for the personal-data scan"
  cb_log "pii scan: $bin scan $CB_PROJECT_DIR (limit ${CFG_PII_SCAN_TIMEOUT} s)"
  cb_pii_scan_run "$bin" "$tmp/out" "$tmp/err" "$CFG_PII_SCAN_TIMEOUT" || st=$?
  if [ "$st" = 124 ]; then
    rm -rf "$tmp"
    cb_die "the personal-data scan of this project (pii-airgap) did not finish within ${CFG_PII_SCAN_TIMEOUT} s, so the session was not started.
Run 'claude-ide-box pii-scan' in the project once (no time limit; its results are cached), then start the session again. PII_SCAN_TIMEOUT changes the limit."
  fi
  if [ "$st" != 0 ] && [ "$st" != 3 ]; then
    why="$(LC_ALL=C tr -d '\000-\011\013-\037\177' <"$tmp/err" | awk 'NF { l = $0 } END { print l }')"
    rm -rf "$tmp"
    cb_die "the personal-data scan of this project failed (pii-airgap, status $st${why:+: $why}), so the session was not started. Run 'claude-ide-box pii-scan' in the project to see why."
  fi
  if ! findings="$(cb_pii_scan_findings "$tmp/out")"; then
    rm -rf "$tmp"
    cb_die "cannot read pii-airgap's scan report (a file name with a line break?), so the session was not started. Run 'claude-ide-box pii-scan' in the project to see the report."
  fi
  rm -rf "$tmp"
  if [ -z "$findings" ]; then
    cb_log "pii scan: no personal data found outside masked files"
    return 0
  fi
  cb_die "personal data found in this project (pii-airgap scan); everything Claude reads is sent to the AI provider, so the session was not started:
$(cb_pii_scan_list "$findings")
$(cb_pii_scan_ways)"
}
