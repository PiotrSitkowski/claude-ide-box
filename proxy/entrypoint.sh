#!/bin/sh
# Render squid.conf from environment and run squid in the foreground.
#   CLAUDE_BOX_SUBNET    internal network allowed to use the proxy (required)
#   CLAUDE_BOX_UPSTREAM  optional host:port of a parent HTTP proxy
set -eu

conf=/run/squid/squid.conf
subnet="${CLAUDE_BOX_SUBNET:?CLAUDE_BOX_SUBNET is not set}"
upstream="${CLAUDE_BOX_UPSTREAM:-}"

case "$subnet" in
  *[!0-9./]*) echo "claude-box-proxy: invalid subnet '$subnet'" >&2; exit 1 ;;
esac

if [ ! -s /etc/claude-box/allowlist ]; then
  echo "claude-box-proxy: /etc/claude-box/allowlist is missing or empty" >&2
  exit 1
fi

peer=""
if [ -n "$upstream" ]; then
  host="${upstream%:*}"
  port="${upstream##*:}"
  case "$host:$port" in
    *[!A-Za-z0-9.:-]*|:*|*:) echo "claude-box-proxy: invalid upstream '$upstream'" >&2; exit 1 ;;
  esac
  peer="cache_peer $host parent $port 0 no-query no-digest default
never_direct allow all"
fi

mkdir -p /run/squid
# @UPSTREAM@ is the last line of the template; the peer settings replace it.
sed -e "s#@SUBNET@#$subnet#" -e '/^@UPSTREAM@$/d' /usr/local/share/claude-box/squid.conf.in > "$conf"
printf '%s\n' "$peer" >> "$conf"

squid -k parse -f "$conf"
exec squid -N -f "$conf"
