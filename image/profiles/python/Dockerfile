# Python: uv for environments and packages (Python 3 itself is in the base image)
#
# Packages come from PyPI: enable the proxy preset with
#   claude-ide-box preset python on
# uv only uses the system Python here; downloading other Python versions
# needs the github preset (python-build-standalone releases).
ARG BASE_IMAGE=claude-ide-box/base:latest
FROM ${BASE_IMAGE}
ARG UV_VERSION=0.13.7
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
RUN python3 -m pip install --break-system-packages --no-cache-dir "uv==${UV_VERSION}" \
 && uv --version
ENV UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=system
ENV HOME=/home/claude
USER claude
