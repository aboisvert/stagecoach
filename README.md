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
| `numWorkers` | `2 × CPU count`, at least 2 | OS threads running stagelane |
| `connLimit` | 1024 | Max connections per worker (split across workers) |
| `inflightLimit` | 64 | Max requests in handler at once per worker |

Use `delay`, `waitReadable`, and other stagelane calls inside handlers for async work—no `asyncdispatch` or `replyPending`.

## Examples

See [`examples/`](examples/):

| File | Nimble task |
|------|-------------|
| [`helloworld.nim`](examples/helloworld.nim) | `nimble helloworld` |
| [`getandpost.nim`](examples/getandpost.nim) | `nimble getandpost` |
| [`httptest.nim`](examples/httptest.nim) | `nimble httptest` |
| [`asynchandler.nim`](examples/asynchandler.nim) | `nimble asynchandler` |

Load test (with helloworld on 8080): `./load-test.sh`

## API overview

- [`stagecoach/httpserver`](stagecoach/httpserver.nim) — `HttpContext`, `newHttpServer`, `serve` / `wait`, request helpers (`getUri`, `readBodyChunk`, …), `reply` / chunked replies
- [`stagecoach/coachserver`](stagecoach/coachserver.nim) — logging, `shutdown()`, close causes
- [`stagecoach/flow`](stagecoach/flow.nim) — stagelane `{.flow.}` support for your handlers

## Release notes, 9.0.3 (stagelane port)

- HTTP server on stagelane: M worker threads, connection and in-flight limits, `{.flow.}` handlers with explicit `HttpContext`
- Removed: `dispatcher`, `epolldispatcher`, websocket and multipart servers, deferred `replyPending` / `asyncdispatch` pattern
- Dependencies: stagelane via Atlas (`atlas install`)

## Older notes (pre-stagelane)

<details>
<summary>9.0.2 – 9.0.0</summary>

- **9.0.2** — content-length buffer / Boyer–Moore header search fixes
- **9.0.1** — chunked response and NODELAY fixes
- **9.0.0** — `std/logging` `Level`; various dispatcher and websocket API changes (websocket since removed on this branch)

</details>
