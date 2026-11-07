#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v hey >/dev/null 2>&1; then
  echo "hey is required (https://github.com/rakyll/hey)" >&2
  exit 1
fi

mkdir -p bin

nim c -d:release --hints:off --threads:on -o:bin/querybench examples/querybench.nim

bin/querybench &
srv_pid=$!
trap 'kill "$srv_pid" 2>/dev/null || true' EXIT

url='http://127.0.0.1:8088/quote?sku=acme-widget&qty=4&unit_cents=1999&tax_bps=875'
for _ in $(seq 1 100); do
  if curl -sf -o /dev/null "$url" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
requests="${REQUESTS:-20000}"
concurrency="${CONCURRENCY:-200}"

hey -n "$requests" -c "$concurrency" "$url"
