# claude-ide-box base image: Debian bookworm + Node 22 + a pinned Claude Code.
#
# Build arguments:
#   BASE_IMAGE          Debian bookworm image that already ships Node 22.
#   CLAUDE_CODE_VERSION npm version of @anthropic-ai/claude-code to install.
#   USER_UID/USER_GID   numeric IDs of the host user, so files written to the
#                       bind-mounted project get the host user's ownership.
ARG BASE_IMAGE=docker.io/library/node:22-bookworm-slim
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=2.1.318
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Tools Claude Code relies on, plus what most projects need to build:
# Python 3 with venv/pip, a C/C++ toolchain (node-gyp, Python wheels, cgo,
# Rust linking) and socat for `claude-ide-box forward`. No sudo, no ssh client.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash build-essential ca-certificates curl file git jq less pkg-config procps \
      python3 python3-dev python3-pip python3-venv ripgrep socat unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

COPY create-user.sh /usr/local/sbin/claude-ide-box-create-user
RUN /usr/local/sbin/claude-ide-box-create-user "${USER_UID}" "${USER_GID}" \
 && rm /usr/local/sbin/claude-ide-box-create-user \
 # The project is bind-mounted and its owner may not match on every Docker
 # flavour (Docker Desktop maps ownership); git must not refuse to work there.
 && git config --system safe.directory '*'

ENV HOME=/home/claude \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_IDE_BOX=1 \
    # node-gyp uses the headers shipped with Node instead of downloading them.
    npm_config_nodedir=/usr/local

LABEL org.opencontainers.image.title="claude-ide-box" \
      io.claude-ide-box.claude-code-version="${CLAUDE_CODE_VERSION}"

USER claude
WORKDIR /home/claude
CMD ["sleep", "infinity"]
