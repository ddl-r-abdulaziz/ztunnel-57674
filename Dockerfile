# syntax=docker/dockerfile:1
#
# Builds the patched ztunnel binary (see src/fake_race.rs) and packages it
# into a minimal runtime image, as a drop-in replacement for a real ztunnel
# image.

FROM rust:1.90-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
        clang \
        protobuf-compiler \
        pkg-config \
        perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN cargo build --release --locked

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/out/rust/release/ztunnel /usr/local/bin/ztunnel

ENTRYPOINT ["/usr/local/bin/ztunnel"]
