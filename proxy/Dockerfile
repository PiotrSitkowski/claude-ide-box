# claude-ide-box egress proxy: squid that only allows CONNECT to port 443 of
# allowlisted domains. No cache, logs to stdout (read with `docker logs`).
ARG BASE_IMAGE=docker.io/library/debian:bookworm-slim
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends squid \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/squid/squid.conf
COPY squid.conf.in /usr/local/share/claude-ide-box/squid.conf.in
COPY entrypoint.sh /usr/local/bin/claude-ide-box-proxy
# The packaged squid runs as the unprivileged "proxy" user.
USER proxy
EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/claude-ide-box-proxy"]
