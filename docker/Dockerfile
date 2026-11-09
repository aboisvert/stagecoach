ARG NIM_VERSION=2.2.4
FROM nimlang/nim:${NIM_VERSION}

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang python3 curl gdb valgrind procps git ca-certificates golang-go \
    && rm -rf /var/lib/apt/lists/*

ARG HEY_VERSION=0.1.4
ENV GOBIN=/usr/local/bin
RUN go install "github.com/rakyll/hey@v${HEY_VERSION}"

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
