---
name: Linux Docker test infra
overview: Add a Docker-based Linux dev/test environment (Nim 2.2.x, gcc, python3) so the Linux-only epoll-based stagehttp can be built and tested from macOS arm64, driven by a shell script and justfile tasks.
todos:
  - id: dockerfile
    content: Create docker/Dockerfile with Nim 2.2, gcc/clang, python3, gdb/valgrind, non-root user
    status: pending
  - id: compose
    content: Add docker-compose.yml with bind mount, cache volumes, raised nofile ulimit
    status: pending
  - id: script
    content: Write scripts/linux-test.sh with build/test/shell/bench/clean subcommands
    status: pending
  - id: just
    content: Add justfile with linux-* tasks delegating to the script
    status: pending
  - id: docs
    content: Add .dockerignore and README section; verify with just linux-test
    status: pending
isProject: false
---

# Linux Docker test infrastructure

Context: the project is Linux-only (epoll), the host is macOS arm64 with Docker 29.8 installed. There's no justfile, Dockerfile, or CI yet. Build and test commands come from `README.md`: `nim c -d:danger --threads:on --mm:arc --path:stagelane/src --path:. examples/demo.nim`, then `python3 tests/test_server.py <port>`.

## Files to add

- `docker/Dockerfile`
  - Base `nimlang/nim:2.2.x` (multi-arch, so it runs natively on arm64; fall back to Debian plus choosenim if no matching tag exists).
  - Install `gcc`, `make`, `python3`, `curl`, `gdb`, `valgrind` and `clang` (ASAN builds).
  - Install `just` for parity with the host. Skip if not needed.
  - Run as a non-root user whose UID matches the host, so mounted files aren't root-owned.
  - `WORKDIR /work`, with the repo bind-mounted there.
- `docker-compose.yml` (optional but convenient)
  - One service, `linux`, that mounts `.:/work`.
  - Named volumes for the nim cache (`/home/dev/.cache/nim`) and nimble packages, to speed up rebuilds.
  - `security_opt` / `ulimits` (`nofile`) raised for the 10k-connection benchmarks.
- `scripts/linux-test.sh`
  - Subcommands: `build` (image), `test` (default), `shell`, `bench`, `clean`.
  - `test` builds the image if needed, then runs in the container:
    1. `nim c -d:danger --threads:on --mm:arc ... -o:/tmp/demo examples/demo.nim`
    2. Start `/tmp/demo 8083 4` in the background and wait until the port is open.
    3. Run `python3 tests/test_server.py 8083`.
    4. Kill the server and exit with the test's exit code.
  - Use `set -euo pipefail` and pass through extra args.
  - Write the binary outside the mount (`/tmp`) so Mach-O/ELF artifacts don't mix.
- `justfile`
  - `linux-build`, `linux-test`, `linux-shell`, `linux-bench` and `linux-clean`, each delegating to `scripts/linux-test.sh`.
- `.dockerignore`
  - `.git`, `.cursor`, nimcache dirs, built binaries.
- `README.md`
  - Short "Running Linux tests on macOS" section.

## Notes and decisions

- Native arm64 Linux containers are used, not amd64 emulation. epoll behavior and the benchmarks stay meaningful, and nothing runs under QEMU. Add an optional `PLATFORM=linux/amd64` env override in the script.
- Benchmarks under Docker Desktop's VM are not representative of bare metal. This is called out in the docs; the benchmarks are for sanity only.
- The server is exercised on loopback inside the container, so there's no port publishing. `shell` optionally publishes the port with `-p`.
- The stagelane tests (if any appear under `stagelane/`) can be added as another `just linux-test-stagelane` target via `nimble test`. `stagelane.nimble` exists, so I'll check it for a test task during implementation.

## Verification

- `just linux-test` passes all of `tests/test_server.py` on macOS.
- `just linux-shell` drops into a container with the repo mounted and the toolchain available.
- A second run reuses the nim cache and is noticeably faster.