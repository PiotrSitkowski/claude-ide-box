#!/bin/sh
# Create the unprivileged "claude" user with the host user's UID/GID.
# Runs at image build time as root. POSIX sh: the base image's /bin/sh is dash.
set -eu

uid="$1"
gid="$2"
name=claude
home=/home/claude

case "$uid$gid" in
  *[!0-9]*|"") echo "create-user: UID/GID must be numeric (got '$uid' '$gid')" >&2; exit 1 ;;
esac
if [ "$uid" -eq 0 ] || [ "$gid" -eq 0 ]; then
  echo "create-user: refusing to create the container user with UID or GID 0" >&2
  exit 1
fi

# Group: reuse an existing group with that GID (macOS users are GID 20, which is
# "dialout" in Debian - membership is harmless in a container without devices).
if ! getent group "$gid" >/dev/null; then
  groupadd --gid "$gid" "$name"
fi

# User: an existing account with that UID is removed only when it is the
# image's default "node" user or a regular (>= 1000) account; a collision with
# a system account is an error rather than a silent takeover.
existing="$(getent passwd "$uid" | cut -d: -f1 || true)"
if [ -n "$existing" ] && [ "$existing" != "$name" ]; then
  if [ "$existing" = node ] || [ "$uid" -ge 1000 ]; then
    userdel --remove "$existing" 2>/dev/null || userdel "$existing"
  else
    echo "create-user: UID $uid belongs to system account '$existing'; set a different UID" >&2
    exit 1
  fi
fi
if getent passwd "$name" >/dev/null; then
  userdel --remove "$name" 2>/dev/null || userdel "$name"
fi

useradd --uid "$uid" --gid "$gid" --home-dir "$home" --create-home --shell /bin/bash "$name"
mkdir -p "$home/.claude"
chown -R "$uid:$gid" "$home"
chmod 700 "$home"
