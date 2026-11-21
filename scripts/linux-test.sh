#!/usr/bin/env bash
# Run stagecoach builds/tests inside a Linux container (for macOS hosts).
# usage: scripts/linux-test.sh [build|test|shell|bench|clean] [args...]
# env:   PLATFORM=linux/amd64 to force emulated x86_64 (default: native)
#        STAGECOACH_TEST_BACKEND=auto|io_uring|epoll
#        STAGECOACH_DOCKER_ALLOW_IO_URING=1 disables seccomp for the test container
set -euo pipefail
cd "$(dirname "$0")/.."

export HOST_UID="$(id -u)" HOST_GID="$(id -g)"
[ "$HOST_UID" -lt 1000 ] 2>/dev/null && HOST_UID=1000   # avoid colliding with system ids
[ "$HOST_GID" -lt 1000 ] 2>/dev/null && HOST_GID=1000
# macOS gids (e.g. 20 "staff") may clash with Debian system groups; harmless because
# the Dockerfile reuses an existing group.
[ -n "${PLATFORM:-}" ] || unset PLATFORM

STAGELANE_COMMIT=f5b7cad5babd884baf9b21f8ea11ee9558d02cff
COMPOSE=(docker compose)
case "${STAGECOACH_DOCKER_ALLOW_IO_URING:-0}" in
  0) ;;
  1) COMPOSE+=(-f docker-compose.yml -f docker/compose-uring-test.yml) ;;
  *) echo "STAGECOACH_DOCKER_ALLOW_IO_URING must be 0 or 1" >&2; exit 2 ;;
esac
RUN=("${COMPOSE[@]}" run --rm --no-TTY -e "STAGECOACH_TEST_BACKEND=${STAGECOACH_TEST_BACKEND:-auto}")
[ -t 0 ] && RUN=("${COMPOSE[@]}" run --rm -e "STAGECOACH_TEST_BACKEND=${STAGECOACH_TEST_BACKEND:-auto}")

in_container() { "${RUN[@]}" linux bash -c "$1" bash "${@:2}"; }

setup_stagelane='
  set -euo pipefail
  git config --global --add safe.directory /work 2>/dev/null || true
  git config --global --add safe.directory /work/deps/stagelane 2>/dev/null || true
  mkdir -p deps
  if [ ! -d deps/stagelane/.git ]; then
    git clone https://github.com/ghazalialshafi/stagelane deps/stagelane
  fi
  git -C deps/stagelane checkout -f '"$STAGELANE_COMMIT"'
  git -C deps/stagelane reset --hard '"$STAGELANE_COMMIT"'
  git -C deps/stagelane apply ../../patches/stagelane-scheduler-cleanup.patch
'

cmd="${1:-test}"; [ $# -gt 0 ] && shift

case "$cmd" in
  build)
    "${COMPOSE[@]}" build "$@" ;;
  test)
    # Run the same discovered suites as `just test`. Optional layer:
    # `just linux-test unit`.
    suite="${1:-all}"
    case "$suite" in
      all|unit|integration|stress) ;;
      *) echo "unknown suite: $suite (all|unit|integration|stress)" >&2; exit 2 ;;
    esac
    "${COMPOSE[@]}" build -q
    in_container "$setup_stagelane
      bash scripts/run-tests.sh $suite
    " ;;
  shell)
    "${COMPOSE[@]}" build -q
    "${RUN[@]}" linux bash ;;
  bench)
    "${COMPOSE[@]}" build -q
    export REQUESTS="${REQUESTS:-20000}" CONCURRENCY="${CONCURRENCY:-200}"
    RUN_BENCH=("${COMPOSE[@]}" run --rm -e "REQUESTS=$REQUESTS" -e "CONCURRENCY=$CONCURRENCY")
    [ -t 0 ] || RUN_BENCH+=(--no-TTY)
    "${RUN_BENCH[@]}" linux bash -c "$setup_stagelane
      set -euo pipefail
      mkdir -p /tmp/bin
      nim c -d:release --hints:off --threads:on -o:/tmp/bin/querybench examples/querybench.nim
      /tmp/bin/querybench >/tmp/querybench.log 2>&1 &
      srv=\$!
      trap \"kill \$srv 2>/dev/null || true\" EXIT
      url=\"http://127.0.0.1:8088/quote?sku=acme-widget&qty=4&unit_cents=1999&tax_bps=875\"
      for _ in \$(seq 1 100); do
        curl -sf -o /dev/null \"\$url\" 2>/dev/null && break
        sleep 0.05
      done
      requests=\"\${REQUESTS:-20000}\"
      concurrency=\"\${CONCURRENCY:-200}\"
      hey -n \"\$requests\" -c \"\$concurrency\" \"\$url\"
    " ;;
  clean)
    "${COMPOSE[@]}" down -v --rmi local ;;
  *)
    echo "unknown command: $cmd (build|test|shell|bench|clean)" >&2; exit 2 ;;
esac
