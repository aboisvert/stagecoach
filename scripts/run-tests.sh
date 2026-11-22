#!/usr/bin/env bash
# Run stagecoach test suites discovered under tests/<layer>/t_*.nim.
# usage: scripts/run-tests.sh [all|unit|integration|stress|one <name>|list|check]
# env:   NIM (default: nim), STAGECOACH_TEST_BACKEND (auto|io_uring|epoll)
#
# The directory is the layer: unit (no listening socket or subprocess),
# integration (fixture-server or self-hosted end-to-end), stress (release-built
# soak, opt-in). Add a suite by dropping tests/<layer>/t_<name>.nim; nothing
# else needs editing.
set -euo pipefail
cd "$(dirname "$0")/.."

NIM="${NIM:-nim}"
FLAGS=(--hints:off --threads:on --outdir:bin)
LAYERS=(unit integration stress)

die() { echo "run-tests: $*" >&2; exit 1; }

case "${STAGECOACH_TEST_BACKEND:-auto}" in
  auto) ;;
  io_uring) FLAGS+=(-d:stagecoachIoUring -d:stagecoachRingTest -d:stagecoachBackendTest) ;;
  epoll) FLAGS+=(-d:stagecoachEpoll -d:stagecoachBackendTest) ;;
  *) die "STAGECOACH_TEST_BACKEND must be auto, io_uring, or epoll" ;;
esac

suites_in() { # layer -> sorted suite paths
  local layer=$1
  [ -d "tests/$layer" ] || return 0
  find "tests/$layer" -maxdepth 1 -type f -name 't_*.nim' | sort
}

check_layout() {
  local f layer
  # A suite at the root cannot be classified: make the fix obvious.
  while IFS= read -r f; do
    die "$f: suites live in tests/<layer>/ (one of: ${LAYERS[*]})"
  done < <(find tests -maxdepth 1 -type f -name 't_*.nim' | sort)

  # Reject unknown layer directories (e.g. tests/tmp/t_foo.nim).
  while IFS= read -r f; do
    layer=$(basename "$(dirname "$f")")
    case " ${LAYERS[*]} " in
      *" $layer "*) ;;
      *) die "$f: unknown test layer '$layer' (expected: ${LAYERS[*]})" ;;
    esac
  done < <(find tests -mindepth 2 -maxdepth 2 -type f -name 't_*.nim' | sort)

  [ -n "$(suites_in unit)" ] || die "no unit suites in tests/unit/"
  [ -n "$(suites_in integration)" ] || die "no integration suites in tests/integration/"
}

run_suites() { # layer
  local layer=$1 f found=0
  local -a args
  args=(-r "${FLAGS[@]}")
  if [ "$layer" = stress ]; then args+=(-d:release); fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    echo "==> $f"
    "$NIM" c "${args[@]}" "$f" || exit 1
  done < <(suites_in "$layer")
  [ "$found" -eq 1 ] || die "no suites in tests/$layer/"
}

run_one() { # name
  local name=${1:-}
  [ -n "$name" ] || die "usage: scripts/run-tests.sh one <name>"
  case "$name" in
    *[!A-Za-z0-9_]*) die "invalid suite name: $name" ;;
  esac
  local -a matches
  matches=()
  while IFS= read -r f; do matches+=("$f"); done \
    < <(find tests -mindepth 2 -maxdepth 2 -type f -name "t_${name}.nim" | sort)
  [ "${#matches[@]}" -eq 1 ] \
    || die "expected one tests/*/t_${name}.nim, found ${#matches[@]}"
  echo "==> ${matches[0]}"
  "$NIM" c -r "${FLAGS[@]}" "${matches[0]}"
}

list_suites() {
  local layer f
  for layer in "${LAYERS[@]}"; do
    while IFS= read -r f; do
      if [ -n "$f" ]; then printf '%s\t%s\n' "$layer" "$f"; fi
    done < <(suites_in "$layer")
  done
}

cmd=${1:-all}
if [ $# -gt 0 ]; then shift; fi

check_layout
case "$cmd" in
  all) run_suites unit; run_suites integration ;;
  unit) run_suites unit ;;
  integration) run_suites integration ;;
  stress) run_suites stress ;;
  one) run_one "$@" ;;
  list) list_suites ;;
  check) echo "test layout ok: $(list_suites | wc -l | tr -d ' ') suites" ;;
  *) die "unknown mode: $cmd (all|unit|integration|stress|one <name>|list|check)" ;;
esac
