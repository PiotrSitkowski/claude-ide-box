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

# Group: named "claude", with the host's GID. An existing group with that GID
# is renamed rather than reused under its own name: macOS users are GID 20,
# which is "dialout" in Debian, and `ls -l` showing files owned by
# claude:dialout looks like device access the container does not have. Only
# the name changes; files and processes refer to the number. Checked only
# after the accounts above are removed: removing one also removes its
# personal group (the node image's "node", Ubuntu's "ubuntu", both GID 1000).
current="$(getent group "$gid" | cut -d: -f1 || true)"
if [ "$current" != "$name" ] && getent group "$name" >/dev/null; then
  groupdel "$name"
fi
if [ -z "$current" ]; then
  groupadd --gid "$gid" "$name"
elif [ "$current" != "$name" ]; then
  groupmod --new-name "$name" "$current"
fi

useradd --uid "$uid" --gid "$gid" --home-dir "$home" --create-home --shell /bin/bash "$name"
mkdir -p "$home/.claude"
chown -R "$uid:$gid" "$home"
chmod 700 "$home"
