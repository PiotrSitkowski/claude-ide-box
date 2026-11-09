# shellcheck shell=bash
# Secret scan: a quick, offline look for secret-looking values in project
# files, run when a project container is created, by `claude-ide-box scan` and
# by `doctor`. It reports file, line and kind - never the value.
#
# It also decides the conditional masks (MASK_IF_SECRET, by default
# .mcp.json): such a file is masked only while it holds a secret.
#
# Sourced by common.sh. Same portability rules: bash 3.2, BSD/GNU/busybox
# (grep -E with intervals, POSIX awk).

# Patterns, matched case-insensitively. Values that start with $, {, < or %
# are placeholders (${VAR}, {{ var }}, <your key>), ^ and ~ are version
# ranges. Keep these free of \s, \w and lookarounds: BSD and busybox grep.
CB_SQ="'"
CB_SECRET_PATTERNS="url-credentials	credentials in a URL	[a-z][a-z0-9+.-]*://[^/[:space:]:@\"$CB_SQ\$]+:[^/[:space:]@\"$CB_SQ\$]{3,}@
url-query	secret-looking URL query parameter	[?&](api[_-]?key|apikey|key|token|access[_-]?token|auth[_-]?token|auth|secret|client[_-]?secret|password|passwd|pwd|sig|signature)=[^&#[:space:]\"$CB_SQ\$<{]{8,}
assignment	key, token or password value	(api[_-]?key|apikey|secret|token|password|passwd|credentials?|private[_-]?key|_auth|auth[_-]?token|authorization|access[_-]?key)[a-z0-9_]*[\"$CB_SQ]?[[:space:]]*[:=][[:space:]]*[\"$CB_SQ]?[^\"${CB_SQ}[:space:]\$<{%^~*][^\"${CB_SQ}[:space:]]{7,}
bearer	bearer token	bearer[[:space:]]+[a-z0-9._~+/=-]{16,}
token-format	known token format	(sk-ant-[a-z0-9_-]{20,}|sk-[a-z0-9]{32,}|gh[pousr]_[a-z0-9]{30,}|github_pat_[a-z0-9_]{30,}|glpat-[a-z0-9_-]{20,}|xox[abposr]-[a-z0-9-]{10,}|akia[0-9a-z]{16}|aiza[0-9a-z_-]{35}|npm_[a-z0-9]{36})
private-key	private key	-----BEGIN ([a-z]+ )*PRIVATE KEY-----"

# Config-like files the scan reads (by name). Everything else is only checked
# for private keys.
CB_SCAN_NAMES="*.json *.jsonc *.json5 *.yaml *.yml *.toml *.ini *.cfg *.conf *.config *.properties
*.xml *.tfvars *.env *.vars .npmrc .yarnrc .pypirc .netrc .envrc .dev.vars .dev.vars.* .mcp.json"

# Lockfiles: large, full of hashes, rarely hold secrets.
CB_SCAN_SKIP_NAMES="package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock composer.lock
Cargo.lock poetry.lock uv.lock Gemfile.lock bun.lock go.sum"

# Directories the scan never enters: dependencies and VCS data.
CB_SCAN_PRUNE=".git node_modules vendor .venv venv __pycache__ bower_components .pnpm-store .yarn"

# cb_scan_file FILE [strict] - print "LINE<TAB>KIND" for each finding.
# strict (for conditional masks) also flags long literal values of mixed
# letters and digits, as an MCP server's "env" block would hold.
cb_scan_file() {
  local file="$1" strict="${2:-}" id desc pat n
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS="$CB_TAB" read -r id desc pat; do
    [ -n "$id" ] || continue
    grep -n -i -E -e "$pat" "$file" 2>/dev/null | while IFS=: read -r n _; do
      printf '%s\t%s\n' "$n" "$desc"
    done
  done <<EOF
$CB_SECRET_PATTERNS
EOF
  if [ -n "$strict" ]; then
    awk '{
      line = $0
      while (match(line, /"[^"]*"/)) {
        s = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (length(s) >= 20 && s !~ /[^A-Za-z0-9+\/=_-]/ && s ~ /[0-9]/ && s ~ /[A-Za-z]/) {
          print NR "\tlong literal value"
          break
        }
      }
    }' "$file" 2>/dev/null
  fi
}

# cb_file_has_secret FILE [strict]
cb_file_has_secret() {
  [ -n "$(cb_scan_file "$@" | head -n 1)" ]
}

# cb_find_conditional_masks DIR - NUL-terminated paths matching MASK_IF_SECRET
# that hold a secret right now. A name matches at any depth, a path (with
# "/") is anchored at the project root, as for MASK.
cb_find_conditional_masks() {
  local dir="$1" pat f
  local -a expr
  expr=()
  set -f
  for pat in $CFG_MASK_IF_SECRET; do
    case "$pat" in
      */*)
        set +f
        for f in "$dir"/$pat; do
          if [ -f "$f" ] && cb_file_has_secret "$f" strict; then
            printf '%s\0' "$f"
          fi
        done
        set -f
        ;;
      *)
        [ ${#expr[@]} -eq 0 ] || expr+=(-o)
        expr+=(-name "$pat")
        ;;
    esac
  done
  set +f
  [ ${#expr[@]} -gt 0 ] || return 0
  find "$dir" \( "${expr[@]}" \) -type f -print 2>/dev/null | while IFS= read -r f; do
    if cb_file_has_secret "$f" strict; then
      printf '%s\0' "$f"
    fi
  done
}

# cb_scan_candidates DIR - NUL-terminated files to scan.
cb_scan_candidates() {
  local dir="$1" n
  local -a prune names
  prune=()
  names=()
  set -f
  for n in $CB_SCAN_PRUNE; do
    [ ${#prune[@]} -eq 0 ] || prune+=(-o)
    prune+=(-name "$n")
  done
  set +f
  # Config-like files up to 1 MB, then anything small for private keys.
  set -f
  for n in $CB_SCAN_NAMES; do
    [ ${#names[@]} -eq 0 ] || names+=(-o)
    names+=(-name "$n")
  done
  set +f
  find "$dir" \( -type d \( "${prune[@]}" \) -prune \) -o \
    \( -type f -size -1024k \( "${names[@]}" \) -print0 \) 2>/dev/null || true
}

cb_scan_keyfiles() {
  local dir="$1" n
  local -a prune
  prune=()
  set -f
  for n in $CB_SCAN_PRUNE; do
    [ ${#prune[@]} -eq 0 ] || prune+=(-o)
    prune+=(-name "$n")
  done
  set +f
  find "$dir" \( -type d \( "${prune[@]}" \) -prune \) -o \( -type f -size -64k -print0 \) 2>/dev/null |
    xargs -0 grep -l -E -e '-----BEGIN ([A-Z]+ )*PRIVATE KEY-----' 2>/dev/null || true
}

# cb_masked_list - absolute paths masked or hidden in the container (mask
# mounts in CB_MOUNTS), one per line, for the scan to skip.
cb_masked_list() {
  printf '%s\n' "$CB_MOUNTS" | awk -F '\t' '$1 == "file" || $1 == "dir" || $1 == "deps" { print $2 }'
}

# cb_secret_findings DIR - "RELPATH<TAB>LINE<TAB>KIND" lines. Needs CB_MOUNTS.
cb_secret_findings() {
  local dir="$1" f rel masked base skip line kind
  masked="$(cb_masked_list)"
  {
    cb_scan_candidates "$dir" | tr '\0' '\n'
    cb_scan_keyfiles "$dir"
  } | sort -u | while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    skip=0
    set -f
    for n in $CB_SCAN_SKIP_NAMES; do
      [ "$base" != "$n" ] || skip=1
    done
    set +f
    [ "$skip" = 0 ] || continue
    if [ -n "$masked" ] && printf '%s\n' "$masked" | awk -v f="$f" '
      { if (f == $0 || index(f, $0 "/") == 1) found = 1 } END { exit !found }'; then
      continue
    fi
    rel="${f#"$dir"/}"
    cb_scan_file "$f" | sort -n -u | while IFS="$CB_TAB" read -r line kind; do
      printf '%s\t%s\t%s\n' "$rel" "$line" "$kind"
    done
  done
}

# cb_report_findings FINDINGS PRINTER - one message per file via PRINTER
# (cb_warn or check_warn), with the command that masks it.
cb_report_findings() {
  local findings="$1" printer="$2" files f where q
  files="$(printf '%s\n' "$findings" | awk -F '\t' 'NF && !seen[$1]++ { print $1 }')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    where="$(printf '%s\n' "$findings" | awk -F '\t' -v f="$f" '
      $1 == f { n++; if (n <= 3) s = s (n > 1 ? "; " : "") "line " $2 ": " $3 }
      END { if (n > 3) s = s "; ..."; print s }')"
    q="$(printf '%q' "$f")"
    "$printer" "possible secret in $f ($where) - Claude in the container can read it; mask it: claude-ide-box mask $q"
  done <<EOF
$files
EOF
}

# On container creation: warn, never block.
cb_warn_secrets() {
  [ "$CFG_SECRET_SCAN" = 1 ] || return 0
  local findings
  findings="$(cb_secret_findings "$CB_PROJECT_DIR")"
  [ -n "$findings" ] || return 0
  cb_report_findings "$findings" cb_warn
}

# cb_valid_mask_pattern PATTERN - relative, no "..", nothing docker --mount or
# the config file could misread.
cb_valid_mask_pattern() {
  case "$1" in
    "" | /* | *..* | *[[:space:]]* | *,* | *'"'* | *"$CB_SQ"* | *=*) return 1 ;;
  esac
  return 0
}
