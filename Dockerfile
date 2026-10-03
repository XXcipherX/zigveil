ARG ZIG_VERSION=0.17.0
FROM debian:trixie-slim AS builder
ARG ZIG_VERSION
ARG TARGETARCH
ARG PRODUCTION_MODE=fast
ARG ZIGVEIL_CPU=baseline

RUN set -eu; \
    test "$ZIG_VERSION" = 0.17.0; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) zig_arch=x86_64; sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;; \
      arm64) zig_arch=aarch64; sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused \
      "https://ziglang.org/download/$ZIG_VERSION/zig-$zig_arch-linux-$ZIG_VERSION.tar.xz" -o /tmp/zig.tar.xz; \
    echo "$sha  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    test "$(/opt/zig/zig version)" = "$ZIG_VERSION"; \
    /opt/zig/zig version; \
    rm /tmp/zig.tar.xz

WORKDIR /build
COPY build.zig ./
COPY src ./src
RUN set -eu; \
    case "$PRODUCTION_MODE" in fast|safe) ;; *) exit 1 ;; esac; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) target=x86_64-linux ;; \
      arm64) target=aarch64-linux ;; \
      *) exit 1 ;; \
    esac; \
    /opt/zig/zig build -Dtarget="$target" -Dcpu="$ZIGVEIL_CPU" -Doptimize="$PRODUCTION_MODE"

FROM debian:trixie-slim
LABEL org.opencontainers.image.source="https://github.com/XXcipherX/zigveil" \
      org.opencontainers.image.description="Bounded ClientHello routing and opaque TCP passthrough" \
      org.opencontainers.image.licenses="MIT"
COPY --from=builder /build/zig-out/bin/zigveil /usr/local/bin/zigveil
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY examples/zigveil.json /usr/share/doc/zigveil/config.example.json
WORKDIR /etc/zigveil
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/etc/zigveil/config.json"]
