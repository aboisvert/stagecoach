# Stagecoach

HTTP/1.1 server for POSIX systems (Linux, BSD, macOS), built on the [stagelane](https://github.com/ghazalialshafi/stagelane) M:N runtime — a play on **stagelane** plus **transport** (like a stagecoach carrying requests).

> **Experimental:** This library is experimental; APIs and behavior may change without notice. It is based on [GuildenStern](https://github.com/olliNiinivaara/GuildenStern), the Nim HTTP server framework, ported to run on stagelane (async runtime) instead of the original thread-per-request dispatchers.

**M** worker threads each run a stagelane event loop; each accepted connection is a flow task. You can run several `HttpServer` instances on different ports (for example a modular monolith behind a reverse proxy).

This branch is **HTTP-only**. WebSocket, multipart, and the old thread-per-request dispatchers were removed in favor of stagelane.

## Requirements

- Nim ≥ 2.2.0
- [stagelane](https://github.com/ghazalialshafi/stagelane) vendored via [Atlas](https://github.com/nim-lang/atlas) (`stagecoach.nimble` pins `#head` for now)
- Build with `--threads:on` (Nim default for your config)

Handlers must be `{.flow.}` procs and take `HttpContext`. Import [`stagecoach/flow`](stagecoach/flow.nim) in application code so `{.flow.}` works in your modules.

## Dependencies

```sh
atlas install   # clones stagelane into deps/ and patches nim.cfg
```

Commit `nim.cfg` and `atlas.lock`. After a fresh clone, `atlas install` follows `#head`; use `atlas rep` to match the lockfile.

## Quick start

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

Server knobs (set before `serve`): `backlog` (default 4096) is the listen queue depth; `idleTimeoutms` (default 30000, `<= 0` disables) closes a connection that has not started a request; `sockettimeoutms` (default 5000) bounds any single in-progress read/write once bytes have arrived; `requestTimeoutms` (default 30000) bounds total header/body receive time (slowloris); `sendDate` (default off) adds a `Date` header (cached per thread, refreshed once a second); `replyFile` streams a regular file after flushing any held reply; `headerValue` / `pathSpan` / `querySpan` / `queryParam` slice the request buffer without extra copies. On Linux, accepted sockets use a persistent edge-triggered `PollFd` in the vendored `stagelane` tree (apply `patches/stagelane-pollfd.patch` to `deps/stagelane` after `atlas install`; CI does this). `nodelay` (default `true`) sets `TCP_NODELAY` on accepted sockets.

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

Use a Linux container to run the full test suite (including real PollFd tests on Linux) and query benchmarks from macOS:

```
just linux-test        # build image, set up deps/stagelane, run `just test` suites
just linux-shell       # interactive shell with the repo mounted at /work
just linux-bench       # compile querybench + hey (env: REQUESTS, CONCURRENCY)
just linux-clean       # remove image and cache volumes
```

`scripts/linux-test.sh <build|test|shell|bench|clean>` works without `just`. The container is native arm64 on Apple Silicon; set `PLATFORM=linux/amd64` to force emulated x86_64. Benchmarks inside Docker Desktop's VM are for sanity only, not bare-metal numbers. Tests write binaries into `bin/` on the mounted tree (gitignored); `linux-bench` keeps its binary under `/tmp` in the container. Each `linux-test` / `linux-bench` run resets `deps/stagelane` to the CI commit and reapplies `patches/stagelane-pollfd.patch`.

## Testing

```
just test              # unit + in-process + integration suites
just test-unit         # t_core, t_parser, t_io, t_response (no network)
just test-integration  # t_http, t_modes, t_limits, t_shutdown, t_stop, t_stream
just test-one http     # a single suite (tests/t_http.nim)
just stress            # concurrent/soak suite (release build, ~10 s)
nimble test            # same as `just test`
```

Layers:

- `t_core`, `t_parser`: pure unit tests (defaults, logging, close causes, `recv` classification, request line, headers, framing, pipelining).
- `t_io`, `t_response`: `beginRequest`/`endRequest` and response framing over a `socketpair`, driven by a scripted peer task.
- `t_http`, `t_modes`, `t_limits`, `t_shutdown`: spawn `tests/fixture_server.nim` (configurable by CLI flags, counts close causes at `/stats`) on a free port and talk raw HTTP to it (`tests/helpers/`).
- `t_stress`: seeded concurrent pipelined clients with abrupt disconnects, close accounting and an RSS growth check. The seed is printed so a failure can be replayed.

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
