<div align="center">
  <img src="logo/web/rustic-western-stagecoach-sign.webp" alt="Stagecoach — HTTP server for POSIX" width="800">
  <br>
  <img src="logo/web/stagecoach_sticker_logo.webp" alt="Stagecoach logo" width="560">
</div>

# Stagecoach

<p align="center">
  <a href="https://github.com/aboisvert/stagecoach/actions/workflows/ci-ubuntu-ring.yml"><img src="https://github.com/aboisvert/stagecoach/actions/workflows/ci-ubuntu-ring.yml/badge.svg?branch=main" alt="Ubuntu io_uring tests"></a>
  <a href="https://github.com/aboisvert/stagecoach/actions/workflows/ci-ubuntu-readiness.yml"><img src="https://github.com/aboisvert/stagecoach/actions/workflows/ci-ubuntu-readiness.yml/badge.svg?branch=main" alt="Ubuntu readiness tests"></a>
  <a href="https://github.com/aboisvert/stagecoach/actions/workflows/ci-macos.yml"><img src="https://github.com/aboisvert/stagecoach/actions/workflows/ci-macos.yml/badge.svg?branch=main" alt="macOS tests"></a>
</p>

HTTP/1.1 server for POSIX systems (Linux, BSD, macOS), built on the [stagelane](https://github.com/ghazalialshafi/stagelane) M:N runtime — a play on **stagelane** plus **transport** (like a stagecoach carrying requests).

> **Experimental:** This library is experimental; APIs and behavior may change without notice. It is based on [GuildenStern](https://github.com/olliNiinivaara/GuildenStern), the Nim HTTP server framework, ported to run on stagelane (async runtime) instead of the original thread-per-request dispatchers.

**M** worker threads each run a stagelane event loop; each accepted connection is a flow task. You can run several `HttpServer` instances on different ports (for example a modular monolith behind a reverse proxy).

This branch is **HTTP-only**. WebSocket, multipart, and the old thread-per-request dispatchers were removed in favor of stagelane.

## Requirements

- Nim ≥ 2.2.0
- [stagelane](https://github.com/ghazalialshafi/stagelane) vendored via [Atlas](https://github.com/nim-lang/atlas), pinned to `f5b7cad5babd884baf9b21f8ea11ee9558d02cff`
- Build with `--threads:on` (Nim default for your config)

Handlers must be `{.flow.}` procs and take `HttpContext`. Import [`stagecoach/flow`](stagecoach/flow.nim) in application code so `{.flow.}` works in your modules.

## Dependencies

**Installation limitation:** Use a source checkout with Atlas as shown below.
A direct Nimble installation or transitive Nimble dependency currently installs
unpatched Stagelane and cannot compile Stagecoach.

```sh
atlas install   # clones stagelane into deps/ and patches nim.cfg
git -C deps/stagelane apply ../../patches/stagelane-scheduler-cleanup.patch
```

Commit `nim.cfg` and `atlas.lock`. The dependency is pinned to a commit; use
`atlas rep` to reproduce the lockfile. Apply the scheduler cleanup patch to a
fresh checkout; if it is already applied, do not apply it again. The patch
closes per-worker scheduler resources when threads exit; the upstream revision
does not expose that cleanup in its normal build.

## I/O backend

Linux workers prefer io_uring (Linux 5.11+) and fall back to readiness with a
warning if it is unavailable. Compile with `-d:stagecoachIoUring` to require
io_uring: `serve` fails if any worker cannot enable it. Compile with
`-d:stagecoachReadiness` to require readiness instead. The flags are mutually
exclusive; io_uring is Linux-only. macOS and BSD default to readiness.
Within a flow handler, helper procs that call potentially suspending operations
such as `reply`, `reject`, or `closeHttpSocket` must also be marked `{.flow.}`.

## Quick start

<div align="center">
  <img src="logo/web/galloping-western-stagecoach.webp" alt="Stagecoach galloping across the desert" width="560">
</div>

```nim
import stagecoach/[flow, httpserver]

proc handle(ctx: HttpContext) {.flow.} =
  ctx.reply("hello world")

let server = newHttpServer(loglevel = lvlInfo)
serve(server, 8080, handle)          # aliases: start(server, ...)
wait(server)                         # aliases: join(server, ...)
```

`serve` parameters (after port and handler):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `osThreads` | CPU count, at least 1 | OS threads running stagelane |
| `connLimit` | 1024 | Max connections for this server (divided across workers) |
| `inflightLimit` | 64 | Max requests in handlers at once for this server (divided across workers) |

Use `delay`, `waitReadable`, and other stagelane calls inside handlers for async work—no `asyncdispatch` or `replyPending`.

Server knobs (set before `serve`): `backlog` (default 4096) is the listen queue depth; `idleTimeoutms` (default 30000, `<= 0` disables) closes a connection that has not started a request; `sockettimeoutms` (default 5000) bounds any single in-progress read/write once bytes have arrived; `requestTimeoutms` (default 30000) bounds total header/body receive time (slowloris); `sendDate` (default off) adds a `Date` header (cached per thread, refreshed once a second); `replyFile` streams a regular file after flushing any held reply; `headerValue` / `pathSpan` / `querySpan` / `queryParam` slice the request buffer without extra copies. `nodelay` (default `true`) sets `TCP_NODELAY` on accepted sockets.

Per-server lifecycle: `stop(srv, drainms = 10_000)` stops that one server—
stops accepting, lets connection tasks finish for `drainms` ms, then
force-cancels leftovers (`drainms = 0` cancels immediately). `wait(srv)`
joins the worker threads and frees the runtime; the same `HttpServer` can
then `serve` again. `shutdown()` (SIGINT/SIGTERM path) is process-global and
one-way. A `Streaming` handler must consume the body fully
(`readBodyChunk` until it returns `Complete`) to keep the connection; an
abandoned body closes it.

## Examples

See [`examples/`](examples/):

| File | Nimble task |
|------|-------------|
| [`helloworld.nim`](examples/helloworld.nim) | `nimble helloworld` |
| [`getandpost.nim`](examples/getandpost.nim) | `nimble getandpost` |
| [`httptest.nim`](examples/httptest.nim) | `nimble httptest` |
| [`asynchandler.nim`](examples/asynchandler.nim) | `nimble asynchandler` |
| [`querybench.nim`](examples/querybench.nim) | `nimble querybench` |

Load test (with helloworld on 8080): `./load-test.sh`

Query GET benchmark (compiles `examples/querybench.nim` with `-d:release`, runs it, then `hey`): `./query-bench.sh`. Override load with `REQUESTS` or `CONCURRENCY` (defaults match `load-test.sh`: 20000 requests, 200 concurrent).

## API overview

- [`stagecoach/httpserver`](stagecoach/httpserver.nim) — `HttpContext`, `newHttpServer`, `serve` / `wait`, `stop`, request helpers (`getUri`, `readBodyChunk`, …), `reply` / chunked replies
- [`stagecoach/socketio`](stagecoach/socketio.nim) — shared non-blocking recv/send retry loops, errno classification, socket-timeout wrapper
- [`stagecoach/coachserver`](stagecoach/coachserver.nim) — logging, `shutdown()`, close causes
- [`stagecoach/flow`](stagecoach/flow.nim) — stagelane `{.flow.}` support for your handlers

## Running Linux tests on macOS (Docker)

Use a Linux container to run every discovered test suite and query benchmarks from macOS:

```
just linux-test        # build image, set up deps/stagelane, run every discovered suite
just linux-test unit   # narrow to a layer (unit|integration|stress)
just linux-shell       # interactive shell with the repo mounted at /work
just linux-bench       # compile querybench + hey (env: REQUESTS, CONCURRENCY)
just linux-clean       # remove image and cache volumes
```

`scripts/linux-test.sh <build|test|shell|bench|clean>` works without `just`. The container is native arm64 on Apple Silicon; set `PLATFORM=linux/amd64` to force emulated x86_64. Benchmarks inside Docker Desktop's VM are for sanity only, not bare-metal numbers. Tests write binaries into `bin/` on the mounted tree (gitignored); `linux-bench` keeps its binary under `/tmp` in the container. Each `linux-test` / `linux-bench` run resets `deps/stagelane` to the CI commit and applies the scheduler cleanup patch, discarding local dependency edits.

To require each backend in tests:

```sh
STAGECOACH_TEST_BACKEND=readiness just linux-test
STAGECOACH_TEST_BACKEND=ring STAGECOACH_DOCKER_ALLOW_IO_URING=1 just linux-test
STAGECOACH_TEST_BACKEND=ring STAGECOACH_DOCKER_ALLOW_IO_URING=1 just linux-test stress
```

The Docker opt-in disables seccomp filtering for the **test container**, because
Docker's default profile may block io_uring. Do not use it for production
containers. Omit it if the host already permits the required syscalls.

## Testing

```
just test              # every discovered suite (unit + integration)
just test-unit         # tests/unit/ only (no network)
just test-integration  # tests/integration/ only
just test-one http     # a single suite from any layer
just stress            # tests/stress/ (release build, ~10 s)
nimble test            # same as `just test`
```

Suites are discovered from their directory, so adding one needs no build-file
or doc edit: drop `t_<name>.nim` into `tests/unit/`, `tests/integration/`, or
`tests/stress/`. `scripts/run-tests.sh` is the single runner behind every
command above (`all|unit|integration|stress|one <name>|list|check`).
Set `STAGECOACH_TEST_BACKEND=ring` or `readiness` to compile tests and their
fixture servers with that backend required; the default is `auto`.

Layers:

- `tests/unit/`: no listening socket or subprocess. Defaults, logging, close
  causes, `recv` classification, request line, headers, framing, and
  pipelining, plus `beginRequest`/`endRequest` and response framing over a
  `socketpair`, including readiness and cancellation behavior.
- `tests/integration/`: end-to-end over real sockets. The fixture suites spawn
  `tests/fixture_server.nim` (configurable by CLI flags, counts close causes at
  `/stats`) on a free port and talk raw HTTP to it (`tests/helpers/`); the
  self-hosted suites start servers in-process or as subprocesses.
- `tests/stress/`: seeded concurrent pipelined clients with abrupt disconnects,
  close accounting and an RSS growth check. The seed is printed so a failure
  can be replayed.

Shared support (`tests/helpers/`, `tests/fixture_server.nim`,
`tests/support_stream.nim`) stays at the `tests/` root.

## Release notes, 0.3.0

### Linux I/O

- Linux workers prefer io_uring on supported kernels and fall back to readiness
  when it is unavailable. `-d:stagecoachIoUring` requires io_uring;
  `-d:stagecoachReadiness` requires readiness. A required backend that cannot
  start fails rather than silently falling back.
- Ring-mode file responses use completion-based reads and writes, so a slow
  reader does not block the worker. Timeout, cancellation, and shutdown paths
  continue to be covered by both backend test suites.
- Stagelane is pinned to `f5b7cad5babd884baf9b21f8ea11ee9558d02cff`.
  **Migration:** replace the former PollFd patch with
  `patches/stagelane-scheduler-cleanup.patch` after dependency setup. The new
  patch is required on every platform to release worker scheduler resources.
  Helper procs called from flow handlers must themselves be `{.flow.}` when
  they call potentially suspending operations such as `closeHttpSocket`.
- **Installation limitation:** direct and transitive Nimble installations
  cannot currently compile; use the Atlas source-checkout setup above.

### HTTP hardening

- Duplicate `Host` headers are rejected by default. `Host` is now tracked for
  identity even when it is not requested via `headerfields`, which lowers the
  user-field budget from 60 to 59 (the parser's bitmask holds 64 names total).
- `Expect` accepts only `100-continue`: every token in the list must match, so
  `Expect: 100-continue, foo` receives 417 instead of being treated as a
  continue hint.
- Request targets containing whitespace or control characters (tab, CR, LF,
  DEL) receive 400, and request-line parsing no longer reads past the bytes
  actually received on short input.
- Out-of-range ports are rejected at `serve` time instead of wrapping to a
  different listening port. `replyFile` now honours the send-buffer size bound,
  and the shutdown signal path walks non-allocating snapshots of the runtime
  and callback lists.

### Testing

- Test suites are discovered by layer from `tests/unit/`,
  `tests/integration/`, and `tests/stress/`. Linux CI exercises both required
  backends; Docker can opt in to a ring-capable test profile.
- The README includes new Stagecoach artwork with optimized web assets.

## Release notes, 0.2 (hardening + lifecycle)

- Request framing is stricter: duplicate wanted headers (a smuggling
  primitive) are rejected, header lines must be CRLF-terminated, `close`
  wins among `Connection` tokens, junk after the version is rejected, and
  the HTTP method must be a full RFC 7230 token (extension methods like
  `REPORT` parse; `GHOST`-style only-prefix matches are gone)
- Streaming keep-alive requires a fully consumed body; abandoned bodies
  close the connection instead of misparsing the tail as a request
- New per-server `stop(drainms)` + restartable `serve`/`wait`; SIGINT/SIGTERM
  behavior unchanged (process-global, immediate)
- `stagecoach/socketio.nim` consolidates the non-blocking recv/send retry
  loops and errno→close-cause mapping that used to live in httprequest and
  httpresponse
- `TCP_NODELAY` is set on accepted sockets (`nodelay = true` knob)
- New close cause `Cancelled`; cancelled handlers no longer log as `TimedOut`
- Lowercase header-field enforcement now raises at `newHttpServer` time

## Release notes, 0.1 (stagelane port)

- HTTP server on stagelane: M worker threads, connection and in-flight limits, `{.flow.}` handlers with explicit `HttpContext`
- Removed: `dispatcher`, `epolldispatcher`, websocket and multipart servers, deferred `replyPending` / `asyncdispatch` pattern
- Request framing is strict: `Transfer-Encoding` request bodies and invalid/negative `Content-Length` are rejected; `Connection: close` and HTTP/1.0 are honored
- `requestTimeoutms` bounds total header/body receive time (slowloris protection)
- Dependencies: stagelane via Atlas (`atlas install`)

## Older notes (pre-stagelane)

<details>
<summary>9.0.2 – 9.0.0</summary>

- **9.0.2** — content-length buffer / Boyer–Moore header search fixes
- **9.0.1** — chunked response and NODELAY fixes
- **9.0.0** — `std/logging` `Level`; various dispatcher and websocket API changes (websocket since removed on this branch)

</details>
