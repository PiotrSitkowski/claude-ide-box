#!/usr/bin/env bash
# Run by windows/install.ps1 as root inside the ClaudeIDEBox WSL distribution,
# right after it was imported from Ubuntu's WSL image:
#
#   provision-root.sh USER
#
# Creates USER (the Windows user name, made safe for Linux), installs Docker
# Engine from Ubuntu's archive and writes /etc/wsl.conf. Safe to run again.
set -euo pipefail

user="${1:?usage: provision-root.sh USER}"
case "$user" in
  [a-z]*) ;;
  *) echo "provision-root.sh: invalid user name '$user'" >&2; exit 1 ;;
esac
case "$user" in
  *[!a-z0-9_-]*) echo "provision-root.sh: invalid user name '$user'" >&2; exit 1 ;;
esac

if ! id "$user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$user"
  passwd --lock "$user" >/dev/null
fi

# systemd starts dockerd; the default user is not root; Windows' PATH stays
# out (a Windows claude.exe or docker.exe must never be found by accident).
# Interop stays on: `claude-ide-box login` opens the sign-in page with
# explorer.exe, called by its full path.
cat >/etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=$user

[interop]
enabled=true
appendWindowsPath=false
EOF

export DEBIAN_FRONTEND=noninteractive
# needrestart (Ubuntu 24.04) must neither ask nor restart services; the
# installer restarts the whole distribution afterwards anyway.
export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get install -y --no-install-recommends \
  docker.io docker-buildx ca-certificates curl tar util-linux git
usermod -aG docker "$user"
systemctl enable docker.service >/dev/null 2>&1 || true

echo "provision-root.sh: done"
