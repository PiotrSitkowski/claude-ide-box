# Go toolchain from the official golang image (modules via proxy.golang.org)
#
#   claude-ide-box preset go on
# GOTOOLCHAIN=local: the toolchain changes only when the image is rebuilt.
ARG BASE_IMAGE=claude-ide-box/base:latest
ARG GO_IMAGE=docker.io/library/golang:1-bookworm
FROM ${GO_IMAGE} AS go

FROM ${BASE_IMAGE}
COPY --from=go /usr/local/go /usr/local/go
ENV GOPATH=/home/claude/go \
    GOTOOLCHAIN=local \
    PATH=/usr/local/go/bin:/home/claude/go/bin:$PATH
RUN go version
