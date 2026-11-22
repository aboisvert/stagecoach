ARG NIM_VERSION=2.4.2

# Build hey in a throwaway Go stage so the runtime image stays slim.
FROM golang:1.22-alpine AS hey
ARG HEY_VERSION=0.1.4
RUN GOBIN=/out go install "github.com/rakyll/hey@v${HEY_VERSION}"

# nimlang/nim publishes no arm64 image for 2.4.x, so build Nim from the
# official source tarball (works on arm64 and x86_64).
FROM debian:bookworm
ARG NIM_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang python3 curl xz-utils gdb valgrind procps git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}.tar.xz" -o /tmp/nim.tar.xz \
    && mkdir /opt/nim-src && tar -xJf /tmp/nim.tar.xz -C /opt/nim-src --strip-components=1 \
    && cd /opt/nim-src && sh build.sh && bin/nim c koch && ./koch boot -d:release \
    && ./koch tools && mkdir -p /opt/nim && ./koch install /opt/nim \
    && ln -s /opt/nim/nim/bin/nim /usr/local/bin/nim \
    && rm -rf /opt/nim-src /tmp/nim.tar.xz

COPY --from=hey /out/hey /usr/local/bin/hey

# Non-root user matching the host UID/GID so bind-mounted files keep their owner.
ARG UID=1000
ARG GID=1000
RUN (getent group ${GID} >/dev/null || groupadd -g ${GID} dev) \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash dev 2>/dev/null || true \
    && mkdir -p /work /home/dev/.cache/nim /home/dev/.nimble \
    && chown -R ${UID}:${GID} /work /home/dev

USER ${UID}:${GID}
ENV HOME=/home/dev PATH=/home/dev/.nimble/bin:$PATH
RUN git config --global --add safe.directory /work
WORKDIR /work
CMD ["bash"]
