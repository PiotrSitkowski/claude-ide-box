# Rust stable toolchain (rustc, cargo, clippy, rustfmt) from the official rust image
#
#   claude-ide-box preset rust on
# The toolchain is read-only under /usr/local/rustup; cargo's registry and
# build caches live in the home volume.
ARG BASE_IMAGE=claude-ide-box/base:latest
ARG RUST_IMAGE=rust:1-slim-bookworm
FROM ${RUST_IMAGE} AS rust
RUN rustup component add clippy rustfmt

FROM ${BASE_IMAGE}
COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo/bin /usr/local/cargo/bin
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/home/claude/.cargo \
    PATH=/usr/local/cargo/bin:/home/claude/.cargo/bin:$PATH
RUN rustc --version && cargo --version
