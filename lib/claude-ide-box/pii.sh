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
